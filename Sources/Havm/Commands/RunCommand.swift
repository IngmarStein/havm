import AppKit
import ArgumentParser
import Darwin
import Foundation
import HavmCore
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

    @Option(name: .long,
            help: "Log level: 'debug', 'info' (default), 'warning', or 'error'. Overrides config file setting.")
    var logLevel: HavmConfig.LoggingOverrides.LogLevel?

    @Option(name: [.customShort("d"), .long],
            help: "Data directory for persistent VM data (default: ~/Library/Application Support/havm/).")
    var dataDir: String?

    @Flag(name: [.long],
          help: "Interactive serial console — connect stdin/stdout to guest VM.")
    var console: Bool = false

    /// Run the service inside an AppKit event loop. Never returns.
    ///
    /// Without the loop the process is a plain executable with no Apple Event
    /// port: a logout or restart never asks it to quit, and loginwindow kills
    /// it — taking the guest down mid-halt — as soon as the session goes away.
    /// Running a real event loop makes it a regular application the system
    /// waits for, and lets `applicationShouldTerminate` hold the quit until
    /// `ServiceRuntime` reports the guest stopped.
    ///
    /// The main thread belongs to the loop from here on, which is why the
    /// process entry point is synchronous (see `HavmEntry`): entering a run
    /// loop from inside a main-queue drain would stop the main queue from being
    /// serviced, and the runtime's signal sources and poll timers live there.
    @MainActor
    func runInApplicationLoop() -> Never {
        let app = NSApplication.shared
        let delegate = HavmApplicationDelegate()
        app.delegate = delegate
        // Regular, explicitly: an unbundled binary (and any LSUIElement
        // setting) would otherwise be classified as a UI element, which is the
        // case loginwindow does not wait for.
        app.setActivationPolicy(.regular)
        // No menu bar on purpose. The only item worth having would be Quit, and
        // under `brew services` (`keep_alive true`) quitting the process just
        // has launchd start it again — an affordance that visibly does nothing.
        // Foreground runs stop with Ctrl+C, which is what the docs say.
        // Sudden termination would let the system kill the process without
        // asking, which is exactly the case this loop exists to handle.
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("havm is running a virtual machine")

        Task { [self] in
            do {
                try await runService(delegate: delegate)
                Darwin.exit(0)
            } catch let exitCode as ExitCode {
                // Setup failures have already been logged; ArgumentParser's
                // own error printing would repeat them.
                Darwin.exit(exitCode.rawValue)
            } catch {
                FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
                Darwin.exit(1)
            }
        }

        app.run()
        // Reached only if the loop stops without terminating the process.
        Darwin.exit(0)
    }

    /// ArgumentParser's requirement. Reached only if the command is run without
    /// the app loop — the entry point always uses `runInApplicationLoop()`.
    func run() async throws {
        try await runService(delegate: nil)
    }

    private func runService(delegate: HavmApplicationDelegate?) async throws {
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
        //    Console mode forces text (stderr) to keep stdout clean for
        //    guest serial output.
        let format = logFormat ?? (json ? .json : havmConfig.effectiveLogFormat)
        // Kept apart from the effective level so a config reload after start
        // can tell a CLI-pinned level from one it is free to change.
        let logLevelOverride: Logger.Level? = {
            if let cliLevel = logLevel {
                switch cliLevel {
                case .debug:  return .debug
                case .info:   return .info
                case .warning: return .warning
                case .error:  return .error
                }
            }
            return verbose ? .debug : nil
        }()
        let effectiveLogLevel = logLevelOverride ?? havmConfig.effectiveLogLevel

        if console && format == .json {
            fputs("Warning: --console forces text log format (JSON logs to stdout would mix with guest output).\n", stderr)
        }
        let useJSON = console ? false : (format == .json)

        // `logging.file` replaces stdout entirely. It is the only way to keep
        // a log from a launch that has no terminal — Finder, `open`, a login
        // item — and it works the same for the launches that do.
        let logFile = havmConfig.effectiveLogFile.flatMap { LogDestination.openFile(at: $0) }

        if useJSON {
            LoggingSystem.bootstrap { label in
                var handler = JSONLogHandler(
                    label: label, stream: logFile ?? FileHandle.standardOutput
                )
                handler.logLevel = effectiveLogLevel
                return handler
            }
        } else if let logFile {
            LoggingSystem.bootstrap { label in
                var handler = StreamLogHandler(label: label, stream: FileLogStream(handle: logFile))
                handler.logLevel = effectiveLogLevel
                return handler
            }
        }

        var logger = Logger(label: "havm.run")
        logger.logLevel = effectiveLogLevel

        // Print where havm looked for config so users can see which file is
        // in effect (or would be). Uses the configured format/level above.
        let configPath = havmConfig.configPath ?? HavmConfig.defaultConfigPath
        let configHint = FileManager.default.fileExists(atPath: configPath)
            ? "" : " (not found — using defaults)"
        logger.info("Config: \(configPath)\(configHint)")

        let logMode = useJSON ? "json" : "text"
        let extras = console ? " console" : ""
        let mem = MemorySize(bytes: havmConfig.effectiveMemorySize)
        logger.info(
            "Config loaded: CPU=\(havmConfig.effectiveCPUCount) Memory=\(mem) Network=\(havmConfig.effectiveNetworkType) Log=\(logMode)\(extras)"
        )

        // 3. Bootstrap metrics (always — registry is needed for hot-reload)
        let registry = bootstrapMetrics(logger: logger)
        var metricsServer: MetricsServer?
        if havmConfig.effectiveMetricsEnabled {
            let hosts = havmConfig.effectivePrometheusHosts
            let sockets = havmConfig.effectivePrometheusSocketPaths
            let server = MetricsServer(
                registry: registry,
                hosts: hosts,
                sockets: sockets,
                port: havmConfig.effectivePrometheusPort,
                logger: logger
            )
            do {
                try server.start()
                metricsServer = server
                let addr = MetricsServer.formatEndpoints(
                    hosts: hosts, port: havmConfig.effectivePrometheusPort, sockets: sockets
                )
                logger.info("Metrics: Prometheus exporter on \(addr)")
            } catch {
                // A configured socket that cannot be bound is fatal: it was
                // asked for explicitly, and continuing would leave the user
                // with no metrics and no obvious reason why. A TCP port in
                // use stays a warning, as it always has.
                guard sockets.isEmpty else {
                    logger.error("Metrics: \(error)")
                    throw ExitCode.failure
                }
                logger.warning("Metrics: Failed to start server on port \(havmConfig.effectivePrometheusPort) — \(error). Continuing without metrics.")
            }
        }

        // 4. Set up HA OS if needed (download, decompress, prepare disk)
        let setupManager = HAOSSetupManager(config: havmConfig, logger: logger)
        do {
            try await setupManager.setupIfNeeded()
            if console {
                HAOSSetupManager.ensureConsoleCmdline()
            }
        } catch {
            logger.error("HA OS setup failed: \(error)")
            throw ExitCode.failure
        }

        // 5. Create and start the VM
        let vmController = VMController(config: havmConfig, consoleMode: console, logger: logger)
        let runtime = ServiceRuntime(
            config: havmConfig,
            vmController: vmController,
            consoleMode: console,
            metricsServer: metricsServer,
            registry: registry,
            logLevelOverride: logLevelOverride,
            logger: logger
        )

        // Wire on-demand disk-metrics collection to the Prometheus scrape path
        // so gauges are computed fresh instead of on a timer.
        metricsServer?.preScrape = { [weak runtime] in
            runtime?.collectDiskMetrics()
        }

        // Hand the runtime to the app loop so a quit request (logout, restart,
        // Cmd+Q) reaches the same graceful-shutdown chain a signal does.
        if let delegate {
            await MainActor.run { delegate.attach(runtime: runtime) }
        }

        // runBlocking dispatches VM setup to the main queue then suspends the
        // calling task. All exit paths call cleanupAndExit() — it never returns.
        await runtime.runBlocking()
    }
}

// MARK: - ArgumentParser conformance for LogFormat

extension HavmConfig.LoggingOverrides.LogFormat: ExpressibleByArgument {}

// MARK: - ArgumentParser conformance for LogLevel

extension HavmConfig.LoggingOverrides.LogLevel: ExpressibleByArgument {}
