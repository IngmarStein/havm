import ArgumentParser
import Foundation
import HavmCore
import HavmRuntime
import Logging

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start the Home Assistant OS VM (blocking, for launchd / terminal use)."
    )

    @Option(name: [.customShort("c"), .long],
            help: "Path to optional config file (default: ~/.config/havm/config.yml).")
    var config: String?

    func run() async throws {
        var logger = Logger(label: "havm.run")
        logger.logLevel = .info

        // 1. Load config (or use defaults)
        let havmConfig: HavmConfig
        do {
            havmConfig = try loadConfig(path: config)
        } catch {
            fputs("Error: \(error)\n", stderr)
            throw ExitCode.failure
        }

        logger.info(
            "Config loaded: CPU=\(havmConfig.effectiveCPUCount) Memory=\(MemorySize(bytes: havmConfig.effectiveMemorySize)) Network=\(havmConfig.effectiveNetworkType)"
        )

        // 2. Set up HA OS if needed (download, extract kernel/initrd, prepare disk)
        let setupManager = HAOSSetupManager(config: havmConfig, logger: logger)
        do {
            try await setupManager.setupIfNeeded()
        } catch {
            fputs("Error: HA OS setup failed: \(error)\n", stderr)
            throw ExitCode.failure
        }

        // 3. Prepare USB manager and discover devices for passthrough
        let usbManager = USBManager(config: havmConfig, logger: logger)

        // 4. Create and start the VM
        let vmController = VMController(config: havmConfig, logger: logger)
        let runtime = ServiceRuntime(config: havmConfig, vmController: vmController, logger: logger)

        // Prepare USB passthrough before starting (reads persisted accessory files)
        vmController.prepareUSB(usbManager: usbManager)

        // runBlocking dispatches to the main thread and blocks via CFRunLoopRun().
        let exitCode = runtime.runBlocking(usbManager: usbManager)

        if exitCode != 0 {
            throw ExitCode(Int32(exitCode))
        }
    }
}
