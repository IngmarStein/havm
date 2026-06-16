import Foundation
import HavmCore
import Virtualization
import Logging

/// Manages the blocking service runtime: signal handling, VM lifecycle, graceful shutdown.
///
/// On SIGTERM or SIGINT:
///   1. Calls vm.requestStop() to send ACPI shutdown to the guest
///   2. Waits up to the configured timeout for the VM to stop
///   3. If the VM hasn't stopped by then, calls vm.forceStop()
public final class ServiceRuntime: @unchecked Sendable {
    private let config: HavmConfig
    private let vmController: VMController
    private let logger: Logger

    private var shutdownRequested = false
    private var guestReachableNotified = false
    private var firstProbeDone = false
    private var exitCode: Int32 = 0

    public init(config: HavmConfig, vmController: VMController, logger: Logger = Logger(label: "havm.runtime")) {
        self.config = config
        self.vmController = vmController
        self.logger = logger

        vmController.onStateChange = { [weak self] state in
            let name = Self.stateDescription(state)
            self?.logger.info("VM state: \(name)")
        }
    }

    /// Run the VM, blocking the calling thread until the VM exits or a signal is received.
    public func runBlocking(usbManager: USBManager? = nil) -> Int32 {
        DispatchQueue.main.async {
            self.setupSignalHandlers()

            self.vmController.startVMBlocking(usbManager: usbManager) { startError in
                if let error = startError {
                    self.logger.error("Failed to start VM: \(error)")
                    exit(1)
                }

                self.logger.info("VM is running. Press Ctrl+C to stop, or send SIGTERM for graceful shutdown.")
                self.printBootingInstructions()

                // Mutable poll state, accessed only from the main queue.
                nonisolated(unsafe) var tick = 0
                func poll() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
                        let sig = Self.signalFlag
                        if sig != 0 {
                            Self.signalFlag = 0
                            self.signalShutdown(name: sig == SIGTERM ? "SIGTERM" : "SIGINT")
                            return
                        }
                        if self.vmController.state == .stopped {
                            self.logger.info("VM stopped.")
                            fflush(stdout)
                            _exit(0)
                            return
                        }

                        // Drain CFRunLoop — VZVirtualMachine uses XPC which
                        // requires the run loop for Mach port event delivery.
                        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))

                        tick += 1
                        if tick % 20 == 0, !self.guestReachableNotified {
                            self.checkGuestNetwork()
                        }
                        poll()
                    }
                }
                poll()
            }
        }

        // Block calling thread.
        DispatchSemaphore(value: 0).wait()
        return 0
    }

    // MARK: - Boot instructions

    private func printBootingInstructions() {
        let lines: [String]
        switch config.effectiveNetworkType {
        case .nat:
            lines = [
                "",
                "╔══════════════════════════════════════════════════════════╗",
                "║  Home Assistant OS is booting (NAT mode).                ║",
                "║                                                          ║",
                "║  SSH:  ssh root@<guest-ip> -p 22222                      ║",
                "║  Web:  http://<guest-ip>:8123                            ║",
                "║                                                          ║",
                "║  havm will notify you when the guest responds.           ║",
                "║  First boot may take a few minutes.                      ║",
                "╚══════════════════════════════════════════════════════════╝",
                "",
            ]
        case .bridge:
            lines = [
                "",
                "╔══════════════════════════════════════════════════════════╗",
                "║  Home Assistant OS is booting.                           ║",
                "║                                                          ║",
                "║  Once ready, open:                                       ║",
                "║    http://homeassistant.local:8123                       ║",
                "║                                                          ║",
                "║  Or check your router's DHCP lease table for the VM's    ║",
                "║  IP address and open http://<ip>:8123                    ║",
                "╚══════════════════════════════════════════════════════════╝",
                "",
            ]
        }
        for line in lines { print(line) }
    }

    // MARK: - Signal handling

    private static nonisolated(unsafe) var signalFlag: Int32 = 0

    private func setupSignalHandlers() {
        // First signal → set flag for poll loop to pick up
        // Repeated signal → _exit immediately (graceful shutdown already in progress)
        signal(SIGTERM) { _ in
            if ServiceRuntime.signalFlag == 0 {
                ServiceRuntime.signalFlag = SIGTERM
            } else {
                _exit(1)
            }
        }
        signal(SIGINT) { _ in
            if ServiceRuntime.signalFlag == 0 {
                ServiceRuntime.signalFlag = SIGINT
            } else {
                _exit(1)
            }
        }
    }

    private func signalShutdown(name: String) {
        guard !shutdownRequested else {
            // Second signal — force immediate exit
            logger.warning("\(name) received again — exiting immediately")
            _exit(1)
        }
        shutdownRequested = true
        logger.info("\(name) received — initiating graceful shutdown...")
        Task { await performGracefulShutdown() }
    }

    private func performGracefulShutdown() async {
        logger.info("Sending ACPI shutdown request...")
        do { try await vmController.requestStop() }
        catch { logger.error("ACPI shutdown request failed: \(error)") }
        let timeout = config.effectiveShutdownTimeout
        logger.info("Waiting up to \(timeout)s for guest to stop...")
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            if vmController.state == .stopped {
                logger.info("VM stopped gracefully.")
                fflush(stdout)
                _exit(0)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        logger.warning("Timed out after \(timeout)s — force-stopping...")
        do {
            try await vmController.forceStop()
            logger.info("Force stop completed.")
        }
        catch { logger.error("Force stop failed: \(error)") }
        fflush(stdout)
        _exit(0)
    }

    // MARK: - Guest connectivity

    /// Check whether the guest is reachable via NAT networking.
    /// Reads the VZ DHCP lease file to find the guest's assigned IP by its MAC.
    private func checkGuestNetwork() {
        guard config.effectiveNetworkType == .nat,
              let mac = vmController.guestMAC else { return }

        // Read DHCP lease file: each lease is a plist blob with name, ip_address,
        // hw_address (prefixed with "1," for Ethernet). Raw file is concatenated plists.
        guard let leaseData = try? Data(contentsOf: URL(fileURLWithPath: "/var/db/dhcpd_leases")),
              let leaseText = String(data: leaseData, encoding: .utf8) else { return }

        // Normalize MAC: lease file uses no leading zeros (e.g. "2:0:0:0:0:23"
        // instead of "02:00:00:00:00:23"). Compare as bytes.
        let guestMACBytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }

        let blocks = leaseText.components(separatedBy: "}\n")
        for block in blocks {
            var blockMAC: [UInt8] = []
            var blockIP: String?
            for line in block.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("hw_address=1,") {
                    let raw = String(trimmed.dropFirst(13))
                    blockMAC = raw.split(separator: ":").compactMap { UInt8($0, radix: 16) }
                } else if trimmed.hasPrefix("ip_address=") {
                    blockIP = String(trimmed.dropFirst(11))
                }
            }
            if blockMAC == guestMACBytes, let ip = blockIP, !ip.isEmpty {
                if !guestReachableNotified {
                    guestReachableNotified = true
                    logger.info("Guest reachable at \(ip) — Home Assistant should be ready shortly")
                    logger.info("  Web: http://\(ip):8123")
                    logger.info("  SSH: ssh root@\(ip) -p 22222")
                }
                return
            }
        }

        if !firstProbeDone {
            firstProbeDone = true
            logger.info("Waiting for guest DHCP lease (MAC \(mac))...")
        }
    }

    /// Human-readable VM state description.
    private static func stateDescription(_ state: VZVirtualMachine.State) -> String {
        switch state.rawValue {
        case 0: "stopped"
        case 1: "running"
        case 2: "paused"
        case 3: "starting"
        case 4: "saving"
        case 5: "restoring"
        default: "unknown (\(state.rawValue))"
        }
    }
}

// MARK: - Helpers

private struct PollState: Sendable {
    var tick = 0
    var healthProbes = 0
}

private final class LockBox<T: Sendable>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
