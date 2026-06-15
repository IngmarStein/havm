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
        // Dispatch setup to main queue, then enter dispatchMain() to keep
        // the process alive. Signal handlers call exit() directly.
        DispatchQueue.main.async {
            self.setupSignalHandlers()

            self.vmController.startVMBlocking(usbManager: usbManager) { startError in
                if let error = startError {
                    self.logger.error("Failed to start VM: \(error)")
                    exit(1)
                }

                self.logger.info("VM is running. Press Ctrl+C to stop, or send SIGTERM for graceful shutdown.")
                self.printBootingInstructions()

                // Poll every 250ms — fast signal response + VM state check.
                func poll() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
                        let sig = Self.signalFlag
                        if sig != 0 {
                            Self.signalFlag = 0
                            self.signalShutdown(name: sig == SIGTERM ? "SIGTERM" : "SIGINT")
                        }
                        if self.vmController.state == .stopped {
                            self.logger.info("VM exited (state: \(self.vmController.state)).")
                            fflush(stdout)
                            _exit(0)
                        }
                        poll()
                    }
                }
                poll()
            }
        }

        // Block calling thread. The process exits via exit() in signal handlers
        // or poll loop, not via normal return.
        DispatchSemaphore(value: 0).wait()
        return 0
    }

    // Rest removed...

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
                "║  Guest IP is typically 192.168.64.2 (or .3, .4 …).       ║",
                "║  Watch console output for the boot log:                  ║",
                "║    tail -f \(HavmConfig.consoleLogPath)                   ║",
                "║                                                          ║",
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

    /// Signal state shared between C signal handler and Swift.
    private static nonisolated(unsafe) var signalFlag: Int32 = 0

    private func setupSignalHandlers() {
        signal(SIGTERM) { _ in
            if ServiceRuntime.signalFlag == 0 { ServiceRuntime.signalFlag = SIGTERM }
        }
        signal(SIGINT) { _ in
            if ServiceRuntime.signalFlag == 0 { ServiceRuntime.signalFlag = SIGINT }
        }
    }

    private func signalShutdown(name: String) {
        guard !shutdownRequested else {
            logger.warning("\(name) received again — forcing stop")
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
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        logger.warning("Timed out after \(timeout)s — force-stopping...")
        do {
            try await vmController.forceStop()
            logger.info("Force stop completed.")
        }
        catch { logger.error("Force stop failed: \(error)") }
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

private final class LockBox<T: Sendable>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
