import Foundation
@preconcurrency import Virtualization
import Logging
@_weakLinked import AccessoryAccess  // weak-linked; only used in @available(macOS 27.0, *) code
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

    /// When true, attach a virtio serial console device for interactive
    /// guest access via stdin/stdout (``--console``).
    public let consoleMode: Bool

    /// Set to true before calling `vm.stop()` so `didStopWithError` can
    /// distinguish an intentional force-stop from an unexpected VM crash.
    private var isForceStopping = false

    public init(config: HavmConfig, consoleMode: Bool = false, logger: Logger = Logger(label: "havm.vm")) {
        self.config = config
        self.consoleMode = consoleMode
        self.logger = logger
        super.init()
        // Seed the initial state so the gauge is present in /metrics
        // before the first transition.
        Gauge(label: "havm_vm_state", dimensions: [("state", "stopped")]).record(1)
        // Same for the passthrough count: zero is the honest value before
        // anything is attached, and seeding it here keeps the panel populated
        // when USB is disabled or the host is too old to attach anything.
        Gauge(label: "havm_usb_accessories").record(0)
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

        // USB: the XHCI controller carries the CONFIG disk at boot and is the
        // route passthrough devices are hot-attached through later.
        if let xhci = try Self.makeUSBController(
            configDiskPath: HavmConfig.configDiskPath,
            usbEnabled: config.effectiveUSBEnabled
        ) {
            vmConfig.usbControllers = [xhci]
            let attached = xhci.usbDevices.count
            if attached == 0 {
                logger.info("USB: enabled, no devices to attach")
            } else {
                logger.info("USB: \(attached) device(s) — SSH CONFIG disk attached")
            }
        } else {
            logger.debug("USB: disabled and no CONFIG disk — no USB controller")
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
                    // VZBridgedNetworkInterface.networkInterfaces is empty
                    // when the process lacks the com.apple.vm.networking
                    // entitlement (self-compiled / Tier 1–2). If the user
                    // didn't explicitly request bridge, fall back to NAT
                    // with a clear explanation.
                    if config.network?.type == nil {
                        logger.warning("Bridge not available — com.apple.vm.networking entitlement missing (self-compiled binary). Falling back to NAT.")
                        net.attachment = VZNATNetworkDeviceAttachment()
                        logger.info("Network: NAT (MAC \(self.guestMAC ?? "?"))")
                        break
                    }
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

        // Serial console — only when --console is active. Connects stdin/stdout
        // to the guest's virtio console (hvc0) for interactive shell access.
        if consoleMode {
            let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
            serialPort.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: FileHandle.standardInput,
                fileHandleForWriting: FileHandle.standardOutput
            )
            vmConfig.serialPorts = [serialPort]
        }

        try vmConfig.validate()
        logger.info("VM configuration validated successfully")
        return vmConfig
    }

    // MARK: - USB controller

    /// Build the XHCI controller for the VM, or `nil` when there is nothing to
    /// attach and passthrough is off.
    ///
    /// `usb.enabled` governs USB *accessory passthrough* — not the SSH CONFIG
    /// disk. Because a `VZUSBMassStorageDeviceConfiguration` only exists as a
    /// child of a controller, gating the controller on that flag alone created
    /// the disk image and then dropped it on the floor: the guest never saw a
    /// `CONFIG` filesystem, HA OS skipped its `authorized_keys` import, and
    /// dropbear never started on port 22222 (`ConditionFileNotEmpty=`), leaving
    /// SSH dead for anyone who had disabled passthrough (issue #12).
    static func makeUSBController(
        configDiskPath: String,
        usbEnabled: Bool
    ) throws -> VZXHCIControllerConfiguration? {
        var usbDevices: [VZUSBDeviceConfiguration] = []
        if FileManager.default.fileExists(atPath: configDiskPath) {
            let configAttachment = try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: configDiskPath),
                readOnly: true
            )
            usbDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: configAttachment))
        }

        // Passthrough needs the controller even with no devices attached yet,
        // so accessories can be hot-attached once the VM is running.
        guard usbEnabled || !usbDevices.isEmpty else { return nil }

        let xhci = VZXHCIControllerConfiguration()
        xhci.usbDevices = usbDevices
        return xhci
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
        // Disk full, permissions, or filesystem error — should be
        // extremely rare, but give a readable message.
        fatalError(
            "Cannot create EFI variable store at \(url.path). "
            + "Check disk space and permissions."
        )
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
            // The framework detaches a passthrough device on its own when the
            // device's IOService terminates (unplug). Without a delegate we
            // never hear about it, and the metrics gauge keeps counting a
            // device that is gone.
            if #available(macOS 27.0, *) {
                for controller in virtualMachine.usbControllers {
                    controller.delegate = self
                }
            }
            self.vm = virtualMachine

            logger.info("Starting VM...")
            virtualMachine.start { result in
                switch result {
                case .success:
                    self.logger.info("VM started successfully")
                    MainActor.assumeIsolated { self.transition(to: .running) }
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
        logger.warning("Cannot read MAC address from \(path) — generating a new random one (guest IP may change)")
        let mac = VZMACAddress.randomLocallyAdministered()
        do {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
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
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try id.dataRepresentation.write(to: URL(fileURLWithPath: path))
        } catch {
            logger.warning("Failed to persist machine identifier: \(error)")
        }
        return id
    }

    // MARK: - USB hot-plug

    /// Attach an accessory to the running VM via the XHCI controller.
    /// Uses the `VZUSBPassthroughDevice` / `attach(device:)` API (macOS 27).
    /// Only called by `USBAccessoryCoordinator`, which is macOS 27+ only.
    @available(macOS 27.0, *)
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
        nonisolated(unsafe) let machine = vm
        let logger = self.logger
        queue.async(execute: DispatchWorkItem {
            let config = VZUSBPassthroughDeviceConfiguration(device: accessory)
            let device: VZUSBPassthroughDevice
            do {
                device = try VZUSBPassthroughDevice(configuration: config)
            } catch {
                // The framework's message is one of several near-identical USB
                // passthrough errors, so log the domain and code too, and the
                // endpoint census that tells an unsupported device (isochronous
                // endpoints cannot be passed through) apart from a denied or
                // malformed one (issue #13).
                let reason = error as NSError
                logger.warning("USB: Failed to create VZUSBPassthroughDevice for \(accessory.registryIDHex) — \(reason.domain) \(reason.code): \(reason.localizedDescription)")
                logger.info("USB: Descriptor — \(USBConfigurationSummary.describe(accessory.configurationDescriptorData))")
                return
            }
            ctl.attach(device: device) { error in
                if let error {
                    let reason = error as NSError
                    logger.info("USB: Attach failed — \(reason.domain) \(reason.code): \(reason.localizedDescription)")
                } else {
                    logger.info("USB: Attached \(accessory.vendorProductIDHex) (registryID=\(accessory.registryIDHex))")
                    Self.recordAttachedAccessoryCount(in: machine)
                }
            }
        })
    }

    /// Record how many passthrough devices are attached right now, and return
    /// that count.
    ///
    /// `VZUSBController.usbDevices` is the framework's own list, which makes it
    /// the only reliable source for the gauge. A counter kept by the accessory
    /// listener would count *connections*: it cannot tell a successful attach
    /// from one the framework refused, and it would keep counting a device the
    /// framework detached by itself after an unplug. The list also includes the
    /// CONFIG mass-storage disk, which is part of the controller's
    /// configuration rather than a passthrough device — hence the downcast.
    @available(macOS 27.0, *)
    @discardableResult
    private static func recordAttachedAccessoryCount(in virtualMachine: VZVirtualMachine?) -> Int {
        let attached = virtualMachine?.usbControllers.reduce(0) { total, controller in
            total + controller.usbDevices.compactMap { $0 as? VZUSBPassthroughDevice }.count
        } ?? 0
        Gauge(label: "havm_usb_accessories").record(Double(attached))
        return attached
    }

    // MARK: - State transitions

    /// Update VM state, metrics, and notify observers. All callers (VZ delegate
    /// callbacks, `forceStop`, `startVMBlocking` completion) are already on the
    /// main dispatch queue — `@MainActor` makes this requirement explicit so a
    /// future VZ update that delivers delegate callbacks on another queue won't
    /// silently introduce a data race on ``state``.
    @MainActor
    private func transition(to newState: VZVirtualMachine.State) {
        let oldLabel = state.description
        let newLabel = newState.description
        Gauge(label: "havm_vm_state", dimensions: [("state", oldLabel)]).record(0)
        Gauge(label: "havm_vm_state", dimensions: [("state", newLabel)]).record(1)
        state = newState
        onStateChange?(newState)
    }

    // MARK: - Lifecycle

    @MainActor
    public func forceStop() async throws {
        guard let vm = vm else { return }
        isForceStopping = true
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
        if isForceStopping {
            logger.info("VM stopped (force stop)")
        } else {
            logger.error("VM stopped: \(error.localizedDescription)")
        }
        // VZ delivers delegate callbacks on the main queue — assumeMainActor
        // avoids the compiler error without a full @MainActor conformance
        // that would break the NSObject protocol conformance.
        MainActor.assumeIsolated { transition(to: .stopped) }
    }

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        logger.info("Guest OS stopped")
        MainActor.assumeIsolated { transition(to: .stopped) }
    }
}

// MARK: - VZUSBController.Delegate

@available(macOS 27.0, *)
extension VMController: VZUSBController.Delegate {
    /// The framework detaches a passthrough device on its own once the device's
    /// IOService is terminated — an unplug, in practice — and this is the only
    /// notification of it. By the time it fires, `usbDevices` no longer contains
    /// the device, so a fresh count is already the post-unplug number.
    public func usbController(
        _ usbController: VZUSBController,
        usbPassthroughDeviceDidDisconnect device: VZUSBPassthroughDevice
    ) {
        let attached = Self.recordAttachedAccessoryCount(in: vm)
        logger.info("USB: Passthrough device removed by the framework — \(attached) attached")
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

extension VZVirtualMachine.State {
    /// Human-readable state label for logging and metrics.
    var description: String {
        switch self {
        case .stopped:   "stopped"
        case .running:   "running"
        case .paused:    "paused"
        case .starting:  "starting"
        case .saving:    "saving"
        case .restoring: "restoring"
        default:         "unknown (\(rawValue))"
        }
    }
}
