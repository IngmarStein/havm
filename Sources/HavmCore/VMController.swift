import Foundation
import Virtualization
import Logging

// MARK: - VM Controller

/// Wraps VZVirtualMachine with VZEFIBootLoader to boot Home Assistant OS
/// directly from its GPT disk image via UEFI. No kernel extraction needed.
public final class VMController: NSObject, @unchecked Sendable {
    public let config: HavmConfig
    private let logger: Logger

    private var vm: VZVirtualMachine?

    public var onStateChange: ((VZVirtualMachine.State) -> Void)?
    public private(set) var state: VZVirtualMachine.State = .stopped

    public init(config: HavmConfig, logger: Logger = Logger(label: "havm.vm")) {
        self.config = config
        self.logger = logger
        super.init()
    }

    // MARK: - Configuration

    /// Build the VZVirtualMachineConfiguration using EFI boot from disk.
    func createConfiguration() throws -> VZVirtualMachineConfiguration {
        let vmConfig = VZVirtualMachineConfiguration()

        // EFI Boot Loader — boots directly from the GPT disk image via UEFI.
        // The EFI System Partition contains GRUB which chain-loads HA OS.
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = loadOrCreateEFIVariableStore()
        vmConfig.bootLoader = bootLoader

        vmConfig.cpuCount = config.effectiveCPUCount
        vmConfig.memorySize = config.effectiveMemorySize
        logger.info("CPU: \(vmConfig.cpuCount), Memory: \(MemorySize(bytes: vmConfig.memorySize))")

        // Storage: main HA OS disk
        let mainDisk = try VZDiskImageStorageDeviceAttachment(
            url: URL(fileURLWithPath: HavmConfig.persistentDiskPath),
            readOnly: false
        )
        var storageDevices: [VZStorageDeviceConfiguration] = [
            VZVirtioBlockDeviceConfiguration(attachment: mainDisk)
        ]

        // Optional: SSH CONFIG disk for key auto-import
        let configDiskPath = HavmConfig.configDiskPath
        if FileManager.default.fileExists(atPath: configDiskPath) {
            let configDisk = try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: configDiskPath),
                readOnly: true
            )
            storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: configDisk))
            logger.info("SSH CONFIG disk attached")
        }

        vmConfig.storageDevices = storageDevices

        // Network
        switch config.effectiveNetworkType {
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
                logger.info("Bridge: \(bridgeInterface.identifier)")
            }
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZBridgedNetworkDeviceAttachment(interface: bridgeInterface)
            vmConfig.networkDevices = [net]
            logger.info("Network: bridged (\(bridgeInterface.identifier))")
        case .nat:
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZNATNetworkDeviceAttachment()
            vmConfig.networkDevices = [net]
            logger.info("Network: NAT")
        }

        // Serial console — captures guest boot output to a file
        let consoleConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
        let consoleLogPath = HavmConfig.consoleLogPath
        let dir = (consoleLogPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Truncate previous log
        try Data().write(to: URL(fileURLWithPath: consoleLogPath))
        let consoleHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: consoleLogPath))
        consoleConfig.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil,
            fileHandleForWriting: consoleHandle
        )

        vmConfig.serialPorts = [consoleConfig]
        vmConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Memory balloon — allows macOS to reclaim idle guest memory
        vmConfig.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // USB passthrough
        if !usbPassthroughConfigs.isEmpty {
            let xhci = VZXHCIControllerConfiguration()
            xhci.usbDevices = usbPassthroughConfigs
            vmConfig.usbControllers = [xhci]
            logger.info("USB: \(usbPassthroughConfigs.count) passthrough device(s)")
        }

        // Stable machine identifier for consistent MAC addresses
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

    // MARK: - Lifecycle

    /// Start the VM. Must be called from the main actor (VZ requires main queue).
    @MainActor
    public func start(usbManager: USBManager? = nil) async throws {
        guard state == .stopped else {
            logger.warning("VM already in state \(state)")
            return
        }

        if let usb = usbManager { prepareUSB(usbManager: usb) }

        let vmConfig = try createConfiguration()
        let virtualMachine = VZVirtualMachine(configuration: vmConfig)
        virtualMachine.delegate = self
        self.vm = virtualMachine

        logger.info("Starting VM...")
        try await withCheckedThrowingContinuation { continuation in
            virtualMachine.start { result in
                switch result {
                case .success:
                    self.logger.info("VM started successfully")
                    continuation.resume()
                case .failure(let error):
                    self.logger.error("VM start failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

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

/// Thread-safe box for cross-dispatch-closure state.
private final class LockBox<T: Sendable>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

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
