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

    @Option(name: [.customShort("l"), .long],
            help: "Log format: 'text' (default) or 'json' (NDJSON, one object per line). Overrides config file setting.")
    var logFormat: HavmConfig.LoggingOverrides.LogFormat?

    @Flag(name: [.long, .customShort("j")],
          help: "Shorthand for --log-format json.")
    var json: Bool = false

    @Flag(name: [.long, .customShort("v")],
          help: "Shorthand for --log-level debug.")
    var verbose: Bool = false

    @Option(name: [.customShort("d"), .long],
            help: "Data directory for persistent VM data (default: ~/Library/Application Support/havm/).")
    var dataDir: String?

    func run() async throws {
        // 0. Set data directory override before anything touches the file system.
        if let dir = dataDir {
            HavmConfig.dataDirectoryOverride = dir
        }

        // 1. Load config (or use defaults) — must happen before LoggingSystem bootstrap
        //    so we know the configured log format. Errors at this stage go to stderr.
        let havmConfig: HavmConfig
        do {
            havmConfig = try loadConfig(path: config)
        } catch {
            fputs("Error: \(error)\n", stderr)
            throw ExitCode.failure
        }

        // 2. Bootstrap the logging system based on the effective format.
        //    CLI flag overrides config file, which defaults to .text.
        //    --json (-j) is a shorthand; explicit --log-format wins.
        let format = logFormat ?? (json ? .json : havmConfig.effectiveLogFormat)
        let effectiveLogLevel: Logger.Level = verbose ? .debug : havmConfig.effectiveLogLevel

        if format == .json {
            LoggingSystem.bootstrap { label in
                var handler = JSONLogHandler(label: label, stream: FileHandle.standardOutput)
                handler.logLevel = effectiveLogLevel
                return handler
            }
        }

        var logger = Logger(label: "havm.run")
        logger.logLevel = effectiveLogLevel

        logger.info(
            "Config loaded: CPU=\(havmConfig.effectiveCPUCount) Memory=\(MemorySize(bytes: havmConfig.effectiveMemorySize)) Network=\(havmConfig.effectiveNetworkType) Log=\(format.rawValue)"
        )

        // 3. Bootstrap metrics (always — registry is needed for hot-reload)
        let registry = bootstrapMetrics(logger: logger)
        var metricsServer: MetricsServer?
        if havmConfig.effectiveMetricsEnabled {
            let server = MetricsServer(
                registry: registry,
                host: havmConfig.effectivePrometheusHost,
                port: havmConfig.effectivePrometheusPort,
                logger: logger
            )
            do {
                try server.start()
                metricsServer = server
                logger.info("Metrics: Prometheus exporter on \(havmConfig.effectivePrometheusHost):\(havmConfig.effectivePrometheusPort)")
            } catch {
                logger.warning("Metrics: Failed to start server on \(havmConfig.effectivePrometheusHost):\(havmConfig.effectivePrometheusPort) — \(error). Continuing without metrics.")
            }
        }

        // 4. Set up HA OS if needed (download, decompress, prepare disk)
        let setupManager = HAOSSetupManager(config: havmConfig, logger: logger)
        do {
            try await setupManager.setupIfNeeded()
        } catch {
            fputs("Error: HA OS setup failed: \(error)\n", stderr)
            throw ExitCode.failure
        }

        // 5. Create and start the VM
        let vmController = VMController(config: havmConfig, logger: logger)
        let runtime = ServiceRuntime(config: havmConfig, vmController: vmController, metricsServer: metricsServer, registry: registry, logger: logger)

        // Wire on-demand disk-metrics collection to the Prometheus scrape path
        // so gauges are computed fresh instead of on a timer.
        metricsServer?.preScrape = { [weak runtime] in
            runtime?.collectDiskMetrics()
        }

        // runBlocking dispatches to the main thread and blocks via CFRunLoopRun().
        // All exit paths use _exit() — the return value is never actually reached.
        _ = runtime.runBlocking()
    }
}

// MARK: - ArgumentParser conformance for LogFormat

extension HavmConfig.LoggingOverrides.LogFormat: ExpressibleByArgument {}
