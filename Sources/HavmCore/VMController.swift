import Foundation
import Virtualization
import Logging
import AccessoryAccess

// MARK: - VM Controller

/// Wraps VZVirtualMachine with VZEFIBootLoader to boot Home Assistant OS
/// directly from its GPT disk image via UEFI. No kernel extraction needed.
public final class VMController: NSObject, @unchecked Sendable {
    public let config: HavmConfig
    private let logger: Logger

    private var vm: VZVirtualMachine?

    public var onStateChange: ((VZVirtualMachine.State) -> Void)?
    public private(set) var state: VZVirtualMachine.State = .stopped
    /// Stable MAC address derived from the machine identifier.
    public private(set) var guestMAC: String?

    public init(config: HavmConfig, logger: Logger = Logger(label: "havm.vm")) {
        self.config = config
        self.logger = logger
        super.init()
    }

    // MARK: - Configuration

    /// Build the VZVirtualMachineConfiguration using EFI boot from disk.
    func createConfiguration() throws -> VZVirtualMachineConfiguration {
        let vmConfig = VZVirtualMachineConfiguration()
        let logger = self.logger

        // EFI Boot Loader — boots directly from the GPT disk image via UEFI.
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = loadOrCreateEFIVariableStore()
        vmConfig.bootLoader = bootLoader

        vmConfig.cpuCount = config.effectiveCPUCount
        vmConfig.memorySize = config.effectiveMemorySize
        logger.info("CPU: \(vmConfig.cpuCount), Memory: \(MemorySize(bytes: vmConfig.memorySize))")

        // Storage: main HA OS disk (minimal — just the boot disk)
        let mainDisk = try VZDiskImageStorageDeviceAttachment(
            url: URL(fileURLWithPath: HavmConfig.persistentDiskPath),
            readOnly: false
        )
        // Storage: main HA OS disk
        let storageDevices: [VZStorageDeviceConfiguration] = [
            VZVirtioBlockDeviceConfiguration(attachment: mainDisk)
        ]

        // USB: always provision the XHCI controller when USB is enabled so
        // devices can be hot-attached later. Static devices (CONFIG disk,
        // persisted passthrough) are added at boot.
        var usbDevices: [VZUSBDeviceConfiguration] = []
        let configDiskPath = HavmConfig.configDiskPath
        if FileManager.default.fileExists(atPath: configDiskPath) {
            let configAttachment = try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: configDiskPath),
                readOnly: true
            )
            usbDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: configAttachment))
            logger.info("SSH CONFIG disk attached (USB)")
        }
        if !usbPassthroughConfigs.isEmpty {
            usbDevices.append(contentsOf: usbPassthroughConfigs)
        }
        if config.effectiveUSBEnabled {
            let xhci = VZXHCIControllerConfiguration()
            xhci.usbDevices = usbDevices
            vmConfig.usbControllers = [xhci]
            logger.info("USB: \(usbDevices.count) device(s)")
        }

        vmConfig.storageDevices = storageDevices

        // Network: stable MAC for consistent DHCP leases across reboots.
        let net = VZVirtioNetworkDeviceConfiguration()
        let mid = loadOrCreateMachineIdentifier()
        let idBytes = mid.dataRepresentation
        var rawBytes = Array(idBytes.suffix(6))
        while rawBytes.count < 6 { rawBytes.append(0) }
        rawBytes[0] = (rawBytes[0] & 0xFC) | 0x02  // locally-administered unicast
        let macString = rawBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        // Force-unwrap safe: we construct the string ourselves from 6 valid hex bytes.
        net.macAddress = VZMACAddress(string: macString)!
        self.guestMAC = net.macAddress.string

        switch config.effectiveNetworkType {
        case .nat:
            net.attachment = VZNATNetworkDeviceAttachment()
            logger.info("Network: NAT (MAC \(self.guestMAC ?? "?"))")
        case .bridge:
            let bridgeInterface: VZBridgedNetworkInterface
            if let ifaceName = config.network?.interface {
                guard let iface = VZBridgedNetworkInterface.networkInterfaces
                    .first(where: { $0.identifier == ifaceName }) else {
                    throw VMConfigError.bridgeInterfaceNotFound(ifaceName)
                }
                bridgeInterface = iface
            } else {
                guard let primary = VZBridgedNetworkInterface.networkInterfaces.first else {
                    throw VMConfigError.noNetworkInterfaces
                }
                bridgeInterface = primary
            }
            net.attachment = VZBridgedNetworkDeviceAttachment(interface: bridgeInterface)
            logger.info("Network: Bridge (\(bridgeInterface.identifier), MAC \(self.guestMAC ?? "?"))")
        }

        vmConfig.networkDevices = [net]

        // Platform
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = loadOrCreateMachineIdentifier()
        vmConfig.platform = platform

        try vmConfig.validate()
        logger.info("VM configuration validated successfully")
        return vmConfig
    }

    /// USB device configurations (populated before start).
    private var usbPassthroughConfigs: [any VZUSBDeviceConfiguration] = []

    public func prepareUSB(usbManager: USBManager) {
        usbPassthroughConfigs = usbManager.buildPassthroughConfigurations()
    }

    // MARK: - EFI variable store

    private func loadOrCreateEFIVariableStore() -> VZEFIVariableStore {
        let url = URL(fileURLWithPath: HavmConfig.nvramPath)
        let fileManager = FileManager.default

        // Ensure directory exists
        try? fileManager.createDirectory(atPath: HavmConfig.vmDirectory,
                                          withIntermediateDirectories: true)

        // Try loading existing store
        if fileManager.fileExists(atPath: url.path) {
            return VZEFIVariableStore(url: url)
        }

        // Create new store
        if let store = try? VZEFIVariableStore(creatingVariableStoreAt: url) {
            return store
        }

        // Last resort: recreate from scratch
        logger.warning("Could not create EFI variable store — recreating")
        try? fileManager.removeItem(atPath: url.path)
        if let store = try? VZEFIVariableStore(creatingVariableStoreAt: url) {
            return store
        }
        // This should never happen
        fatalError("Cannot create EFI variable store at \(url.path)")
    }

    // MARK: - Blocking VM start (for ServiceRuntime, called from main dispatch queue)

    /// Build config, create VZVirtualMachine, and call start().
    /// Must be called from the main dispatch queue (VZ requirement).
    /// The VZ completion handler fires on an arbitrary queue — we wait
    /// on a background thread to avoid blocking the main queue.
    /// Start the VM from the main queue. Does NOT block — calls `onComplete`
    /// when VZ delivers its start callback (on the main queue).
    /// Called from ServiceRuntime via DispatchQueue.main.async.
    public func startVMBlocking(
        usbManager: USBManager?,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        if let usb = usbManager { prepareUSB(usbManager: usb) }

        do {
            let vmConfig = try createConfiguration()
            let virtualMachine = VZVirtualMachine(configuration: vmConfig)
            virtualMachine.delegate = self
            self.vm = virtualMachine

            logger.info("Starting VM...")
            virtualMachine.start { result in
                switch result {
                case .success:
                    self.logger.info("VM started successfully")
                    self.state = .running
                    self.onStateChange?(.running)
                    onComplete(nil)
                case .failure(let error):
                    self.logger.error("VM start failed: \(error.localizedDescription)")
                    onComplete(error)
                }
            }
        } catch {
            onComplete(error)
        }
    }

    // MARK: - Machine identifier

    private func loadOrCreateMachineIdentifier() -> VZGenericMachineIdentifier {
        let path = HavmConfig.machineIdentifierPath
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let id = VZGenericMachineIdentifier(dataRepresentation: data) {
            return id
        }
        let id = VZGenericMachineIdentifier()
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try id.dataRepresentation.write(to: URL(fileURLWithPath: path))
        } catch {
            logger.warning("Failed to persist machine identifier: \(error)")
        }
        return id
    }

    // MARK: - USB hot-plug

    /// Attach an accessory to the running VM via the XHCI controller.
    /// Uses the new `VZUSBPassthroughDevice` / `attach(device:)` API (macOS 27).
    public func attachAccessory(_ accessory: AAUSBAccessory) {
        guard let vm, state == .running else {
            logger.debug("USB: Skipping attach — VM not running")
            return
        }
        guard let controller = vm.usbControllers.first else {
            logger.warning("USB: Cannot attach — no USB controller on running VM")
            return
        }
        vm.queue.async {
            let config = VZUSBPassthroughDeviceConfiguration(device: accessory)
            guard let device = try? VZUSBPassthroughDevice(configuration: config) else {
                Logger(label: "havm.vm").warning("USB: Failed to create VZUSBPassthroughDevice for \(accessory.registryID)")
                return
            }
            controller.attach(device: device) { error in
                if let error {
                    Logger(label: "havm.vm").warning("USB: Attach failed: \(error.localizedDescription)")
                } else {
                    Logger(label: "havm.vm").info("USB: Attached device registryID=\(accessory.registryID)")
                }
            }
        }
    }

    // MARK: - Lifecycle

    /// Request ACPI shutdown. Note: HA OS on aarch64 uses PSCI and ignores ACPI
    /// power button events, so this typically does not work. Use SSH-based
    /// shutdown (ServiceRuntime) instead.
    @MainActor
    public func requestStop() throws {
        guard let vm = vm else { return }
        do {
            try vm.requestStop()
            logger.info("ACPI shutdown requested")
        } catch {
            logger.error("ACPI shutdown failed: \(error)")
            throw error
        }
    }

    @MainActor
    public func forceStop() async throws {
        guard let vm = vm else { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            vm.stop { error in
                if let error = error { c.resume(throwing: error) }
                else { c.resume() }
            }
        }
        state = .stopped
        onStateChange?(.stopped)
    }
}

// MARK: - VZVirtualMachineDelegate

extension VMController: VZVirtualMachineDelegate {
    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        logger.error("VM stopped: \(error.localizedDescription)")
        state = .stopped
        onStateChange?(.stopped)
    }

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        logger.info("Guest OS stopped")
        state = .stopped
        onStateChange?(.stopped)
    }
}

// MARK: - Errors

public enum VMConfigError: Error, CustomStringConvertible {
    case bridgeInterfaceNotFound(String)
    case noNetworkInterfaces

    public var description: String {
        switch self {
        case .bridgeInterfaceNotFound(let name):
            return "Bridge interface '\(name)' not found. Available: " +
                VZBridgedNetworkInterface.networkInterfaces.map(\.identifier).joined(separator: ", ")
        case .noNetworkInterfaces:
            return "No network interfaces available for bridging."
        }
    }
}
