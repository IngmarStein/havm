import Foundation
@preconcurrency import Virtualization
import Logging
import AccessoryAccess
import Metrics

// MARK: - VM Controller

/// Wraps VZVirtualMachine with VZEFIBootLoader to boot Home Assistant OS
/// directly from its GPT disk image via UEFI. No kernel extraction needed.
public final class VMController: NSObject, @unchecked Sendable {
    public let config: HavmConfig
    private let logger: Logger

    private var vm: VZVirtualMachine?

    public var onStateChange: ((VZVirtualMachine.State) -> Void)?
    public private(set) var state: VZVirtualMachine.State = .stopped
    /// Stable MAC address persisted across reboots.
    public private(set) var guestMAC: String?

    public init(config: HavmConfig, logger: Logger = Logger(label: "havm.vm")) {
        self.config = config
        self.logger = logger
        super.init()
        // Seed the initial state so the gauge is present in /metrics
        // before the first transition.
        Gauge(label: "havm_vm_state", dimensions: [("state", "stopped")]).record(1)
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
        let storageDevices: [VZStorageDeviceConfiguration] = [
            VZVirtioBlockDeviceConfiguration(attachment: mainDisk)
        ]

        // USB: always provision the XHCI controller when USB is enabled so
        // passthrough devices can be hot-attached later. Only the CONFIG disk
        // is added at boot.
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
        if config.effectiveUSBEnabled {
            let xhci = VZXHCIControllerConfiguration()
            xhci.usbDevices = usbDevices
            vmConfig.usbControllers = [xhci]
            logger.info("USB: \(usbDevices.count) device(s)")
        }

        vmConfig.storageDevices = storageDevices

        // Network: stable MAC for consistent DHCP leases across reboots.
        let net = VZVirtioNetworkDeviceConfiguration()
        let macAddress = loadOrCreateMACAddress()
        net.macAddress = macAddress
        self.guestMAC = macAddress.string

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

        // Entropy device — provides random numbers to the guest kernel for
        // cryptographic operations and ASLR.
        vmConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Memory balloon — allows macOS to reclaim idle guest memory when the
        // host is under memory pressure.
        vmConfig.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        try vmConfig.validate()
        logger.info("VM configuration validated successfully")
        return vmConfig
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
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        // USB passthrough devices are hot-attached by the listener after
        // boot, not pre-configured from stale persisted accessory files.
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
                    self.transition(to: .running)
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

    // MARK: - MAC address

    private func loadOrCreateMACAddress() -> VZMACAddress {
        // Config override takes priority.
        if let macString = config.network?.mac,
           let mac = VZMACAddress(string: macString) {
            return mac
        }
        // Otherwise use persisted random address.
        let path = HavmConfig.macAddressPath
        if let string = try? String(contentsOfFile: path, encoding: .utf8),
           let mac = VZMACAddress(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return mac
        }
        let mac = VZMACAddress.randomLocallyAdministered()
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try mac.string.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            logger.warning("Failed to persist MAC address: \(error)")
        }
        return mac
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
        let queue = vm.queue
        nonisolated(unsafe) let ctl = controller
        let logger = self.logger
        queue.async(execute: DispatchWorkItem {
            let config = VZUSBPassthroughDeviceConfiguration(device: accessory)
            guard let device = try? VZUSBPassthroughDevice(configuration: config) else {
                logger.warning("USB: Failed to create VZUSBPassthroughDevice for \(accessory.registryID)")
                return
            }
            ctl.attach(device: device) { error in
                if let error {
                    logger.info("USB: Attach failed: \(error.localizedDescription)")
                } else {
                    let (vid, pid) = accessory.vendorProductID
                    logger.info("USB: Attached 0x\(String(vid, radix: 16, uppercase: true)):0x\(String(pid, radix: 16, uppercase: true)) (registryID=\(accessory.registryID))")
                }
            }
        })
    }

    // MARK: - State transitions

    private func transition(to newState: VZVirtualMachine.State) {
        let oldLabel = stateDescription(state)
        let newLabel = stateDescription(newState)
        Gauge(label: "havm_vm_state", dimensions: [("state", oldLabel)]).record(0)
        Gauge(label: "havm_vm_state", dimensions: [("state", newLabel)]).record(1)
        state = newState
        onStateChange?(newState)
    }

    private func stateDescription(_ state: VZVirtualMachine.State) -> String {
        switch state {
        case .stopped:   "stopped"
        case .running:   "running"
        case .paused:    "paused"
        case .starting:  "starting"
        case .saving:    "saving"
        case .restoring: "restoring"
        default:         "unknown"
        }
    }

    // MARK: - Lifecycle

    @MainActor
    public func forceStop() async throws {
        guard let vm = vm else { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            vm.stop { error in
                if let error = error { c.resume(throwing: error) }
                else { c.resume() }
            }
        }
        transition(to: .stopped)
    }
}

// MARK: - VZVirtualMachineDelegate

extension VMController: VZVirtualMachineDelegate {
    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        logger.error("VM stopped: \(error.localizedDescription)")
        transition(to: .stopped)
    }

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        logger.info("Guest OS stopped")
        transition(to: .stopped)
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

// MARK: - AAUSBAccessory convenience

extension AAUSBAccessory {
    /// Extract vendor and product ID from the USB device descriptor.
    public var vendorProductID: (UInt16, UInt16) {
        let data = deviceDescriptorData
        return data.count >= 18
            ? (UInt16(littleEndian: data[10..<12].reduce(0) { $0 << 8 | UInt16($1) }),
               UInt16(littleEndian: data[12..<14].reduce(0) { $0 << 8 | UInt16($1) }))
            : (0, 0)
    }
}
