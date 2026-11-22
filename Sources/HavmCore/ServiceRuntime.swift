import Foundation
@preconcurrency import Virtualization
import Logging
import Metrics
import Synchronization

/// What the running guest is doing, as far as havm can tell from outside it.
/// The application layer turns this into a Dock badge and a menu item; it is
/// the only status havm exposes without a window.
public enum GuestStatus: Sendable, Equatable {
    /// No answer from the web UI yet — booting, or booted but not serving.
    case booting
    /// Home Assistant answered here.
    case ready(URL)
    /// havm stopped waiting. The guest may still be running; it is not
    /// answering, and the boot phase is over either way.
    case unreachable

    /// The address Home Assistant answered on, when it has answered.
    public var readyURL: URL? {
        if case .ready(let url) = self { return url }
        return nil
    }

    /// Whether Home Assistant is answering, i.e. whether there is an address
    /// worth opening.
    public var isReady: Bool { readyURL != nil }
}

/// Manages the blocking service runtime: signal handling, VM lifecycle,
/// graceful shutdown, guest IP discovery, and web UI readiness detection.
///
/// On SIGTERM or SIGINT:
///   1. REST API → SSH port 22222 → SSH port 22 → force-stop
///   2. Second signal during shutdown: force exit immediately
///
/// ACPI power button (vm.requestStop()) is not used — HA OS on aarch64 uses
/// PSCI for power management and ignores ACPI events entirely.
///
/// ## Guest connectivity
///
/// After the VM boots, the runtime discovers the guest IP via mDNS resolution,
/// DHCP lease parsing, or a config-provided hostname. Once the IP is known, it
/// polls the Home Assistant web UI health-check endpoint until the frontend
/// responds (or 5 minutes elapse), then prints the ready URL.
///
/// ## USB Accessory Discovery
/// On macOS 27+, registers a `USBAccessoryCoordinator` after VM start. macOS
/// shows a menu bar item where the user selects which USB accessories to
/// attach. On connect, the accessory is hot-attached to the running VM.
/// On macOS 15–26, USB accessory passthrough is unavailable and the VM runs
/// without it.
public final class ServiceRuntime: NSObject, @unchecked Sendable {
    private var config: HavmConfig
    private var vmController: VMController
    private var logger: Logger
    private let consoleMode: Bool
    /// The `--log-level` / `-v` level, which outranks the config file. Held
    /// separately because `config.effectiveLogLevel` cannot see the CLI, so
    /// re-reading it after a reload would silently discard the flag.
    private let logLevelOverride: Logger.Level?

    private var runContinuation: CheckedContinuation<Void, Never>?
    private var shutdownRequested = false
    private var restartRequested = false
    /// Set when the application itself is terminating (logout, restart, Cmd+Q).
    /// `cleanupAndExit` then answers the quit Apple Event instead of calling
    /// `exit()` outright, so the system sees the guest stop rather than a
    /// process that vanished.
    private var terminationRequested = false

    /// When the quit arrived. Logged on the way out, so a guest that takes
    /// longer than launchd's window is visible as a quit that was never
    /// answered rather than as a shutdown that silently stopped.
    private var terminationRequestedAt: Date?

    /// Guards `cleanupAndExit` so concurrent signals / stop callbacks cannot
    /// double-resume `runContinuation` or race teardown.
    private let exitGuard = Mutex(false)
    private var haClient: HAClient

    /// Called from `cleanupAndExit` when the process is ending because of a
    /// quit Apple Event. The application layer sets this to reply to the
    /// pending quit; replying terminates the process. Left `nil` when havm runs
    /// without an event loop, where `cleanupAndExit` simply exits.
    public var terminationHandler: ((Int32) -> Void)?
    private var guestReachableNotified = false
    private var supervisorReachableNotified = false
    private var webUIReadyNotified = false
    private var firstProbeDone = false
    private var guestIP: String?
    /// Base URL of the guest's Home Assistant HTTP server, once a probe has
    /// answered on it. Stays `nil` until then — which is why this is the
    /// resolved *URL* rather than the resolved port: `nil` already means
    /// "not known yet" here, and an omitted port needs a `nil` of its own.
    /// Reset on restart, since the new guest may serve elsewhere.
    private var resolvedHAURL: String?

    /// What the Dock tile can say about the guest without opening a browser.
    /// Main-thread confined: written through `setGuestStatus` and read by the
    /// application delegate.
    public private(set) var guestStatus: GuestStatus = .booting

    /// Called when `guestStatus` changes, always on the main thread.
    public var guestStatusChanged: ((GuestStatus) -> Void)?
    private var signalSourceTerm: DispatchSourceSignal?
    private var signalSourceInt: DispatchSourceSignal?
    private var signalSourceHup: DispatchSourceSignal?
    private var configWatcher: ConfigWatcher?
    private var bootTimer: DispatchSourceTimer?
    private var bootDeadline: Date?
    private var observerProbe: (task: Task<Void, Never>, deadline: Date)?
    private var nextObserverProbeAt: Date = .distantPast
    /// In-flight web UI probes keyed by candidate base URL, each with a hard
    /// wall-clock deadline so a stalled or blackholed port can never block
    /// retries or another candidate port.
    private var activeWebUIProbes: [String: (task: Task<Void, Never>, deadline: Date)] = [:]
    private var nextWebUIProbeAt: [String: Date] = [:]
    private static let bootWaitTimeoutSeconds: TimeInterval = 5 * 60
    private static let observerProbeTimeoutSeconds: TimeInterval = 3
    private static let webUIProbeTimeoutSeconds: TimeInterval = 5
    private static let probeRetryIntervalSeconds: TimeInterval = 1
    private var metricsServer: MetricsServer?
    private let registry: SimpleRegistry
    /// What `/metrics` says about the guest. Written on the main thread with
    /// `guestStatus`, so the two cannot disagree.
    private let guestMetrics: GuestStatusMetrics
    /// Strong reference to the macOS 27+ `USBAccessoryCoordinator`, if USB
    /// discovery is active. Typed `Any?` because the coordinator's type is
    /// only available on macOS 27.
    private var usbCoordinator: Any?
    private lazy var terminal = TerminalMode(logger: logger)
    private var lastDHCPLeaseModDate: Date?
    private var cachedDHCPLeaseIP: String?
    private var cachedMACString: String?
    private var cachedMACBytes: [UInt8]?

    public init(
        config: HavmConfig,
        vmController: VMController,
        consoleMode: Bool = false,
        metricsServer: MetricsServer? = nil,
        registry: SimpleRegistry,
        logLevelOverride: Logger.Level? = nil,
        logger: Logger = Logger(label: "havm.runtime")
    ) {
        self.config = config
        self.vmController = vmController
        self.consoleMode = consoleMode
        self.logLevelOverride = logLevelOverride
        self.metricsServer = metricsServer
        self.registry = registry
        self.guestMetrics = GuestStatusMetrics(registry: registry)
        self.logger = logger
        self.haClient = HAClient(
            caCertPath: config.effectiveHACACertPath,
            insecureSkipVerify: config.effectiveHAInsecureSkipVerify,
            logger: logger
        )
        super.init()
        // Seed the gauge so it is present from the first scrape, before the
        // guest has had a chance to change anything.
        guestMetrics.record(guestStatus)
        observe(vmController)
    }

    /// Install the state callback on a controller the runtime is about to run.
    ///
    /// Every controller needs this — the first one and each restart's. A
    /// restart used to build a fresh controller and never wire it up, so after
    /// a SIGHUP the guest could stop without the runtime hearing about it: the
    /// boot timer is cancelled once Home Assistant answers, and nothing else
    /// looks at `state`.
    private func observe(_ controller: VMController) {
        controller.onStateChange = { [weak self, weak controller] state in
            guard let self else { return }
            self.logger.info("VM state: \(state.description)")
            guard state == .stopped, !self.shutdownRequested else { return }
            // A guest that halted itself is not a failure, and a stop the
            // runtime asked for is handled by the shutdown chain's own exit.
            self.cleanupAndExit(controller?.stoppedWithError == true ? 1 : 0)
        }
    }

    /// Run the VM, blocking the calling task until the VM exits or a signal is
    /// received. Never returns: every exit path goes through `cleanupAndExit`.
    public func runBlocking() async {
        // Write PID file for external tooling (Homebrew services, monitoring).
        writePIDFile()

        DispatchQueue.main.async {
            self.setupSignalHandlers()

            self.vmController.startVMBlocking { startError in
                if let error = startError {
                    self.logger.error("Failed to start VM: \(error)")
                    self.cleanupAndExit(1)
                }

                if self.consoleMode {
                    self.terminal.enable()
                    self.logger.info("Console: interactive serial console active (hvc0). Type 'poweroff' or send SIGTERM to stop.")
                } else {
                    self.logger.info("VM is running. Press Ctrl+C to stop, or send SIGTERM for graceful shutdown.")
                }
                self.setupUSBDiscovery()
                if !self.consoleMode {
                    self.printBootingInstructions()
                }

                self.startBootPhase()
            }
        }

        // Suspend the calling task instead of blocking a thread.
        // The continuation is stored and only resumed on actual process
        // exit (cleanupAndExit). On restart, the task remains suspended
        // so the Process stays alive for the next VM instance.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            self.runContinuation = c
        }
    }

    // MARK: - Boot instructions

    private func printBootingInstructions() {
        // Only print the banner for interactive terminal use.
        // When stdout is not a TTY (launchd service, piped output,
        // redirected to log file), nobody is watching and the ASCII
        // art would break JSON consumers that parse stdout.
        guard isatty(STDOUT_FILENO) != 0 else { return }
        var lines: [String]
        let networkType = vmController.actualNetworkType
        let mode = networkType == .nat ? " (NAT mode)" : ""
        // 57-character content area between ║ borders.
        let header = "Home Assistant OS is booting\(mode)."
        let pad = String(repeating: " ", count: 55 - header.count)
        lines = [
            "",
            "╔══════════════════════════════════════════════════════════╗",
            "║  \(header)\(pad) ║",
            "║                                                          ║",
        ]
        switch networkType {
        case .nat:
            lines += [
                "║  SSH:  ssh root@<guest-ip> -p 22222                      ║",
                "║  Web:  printed by havm once the guest responds           ║",
            ]
        case .bridge:
            // No port in the banner: HAOS 2026.8 put new installs on an
            // address that leaves it out and left existing ones on 8123, and
            // which one this guest is can't be known until it answers. The
            // ready message names the address that actually replied.
            lines += [
                "║  Once ready, open the address havm prints below.         ║",
                "║                                                          ║",
                "║  Or check your router's DHCP lease table for the VM's    ║",
                "║  IP address.                                             ║",
            ]
        }
        lines += [
            "║                                                          ║",
            "║  havm will notify you when the guest responds.           ║",
            "║  First boot may take a few minutes.                      ║",
            "╚══════════════════════════════════════════════════════════╝",
            "",
        ]
        for line in lines { fputs(line + "\n", stderr) }
    }

    // MARK: - Boot phase

    /// Runs at 250 ms intervals until the guest IP is discovered and the web
    /// UI responds. After that, the timer is cancelled — no more scheduled
    /// work. Signals, VZ delegate callbacks, and config-watcher events arrive
    /// through GCD dispatch sources and terminate the process via
    /// `cleanupAndExit()`.
    ///
    /// Uses `DispatchSourceTimer` instead of recursive `asyncAfter` to avoid
    /// creating a new scheduled work item every tick.
    private func startBootPhase() {
        bootDeadline = Date().addingTimeInterval(Self.bootWaitTimeoutSeconds)
        nextObserverProbeAt = .distantPast
        nextWebUIProbeAt.removeAll()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.bootTick()
        }
        timer.resume()
        self.bootTimer = timer
    }

    private func bootTick() {
        guard !shutdownRequested else { return }
        guard vmController.state != .stopped else {
            if restartRequested {
                restartVM()
            } else {
                cleanupAndExit(vmController.stoppedWithError ? 1 : 0)
            }
            return
        }

        if !guestReachableNotified {
            checkGuestNetwork()
        } else if !webUIReadyNotified {
            if !supervisorReachableNotified {
                checkObserver()
            }
            checkWebUI()
        }

        guard !guestReachableNotified || !webUIReadyNotified else {
            bootTimer?.cancel()
            bootTimer = nil
            return
        }
    }

    /// Remove PID file, flush stdout, and exit. Called from GCD event
    /// handlers (signal, VZ delegate, poll loop) when the VM stops.
    /// - Returns: `Never` — unconditionally terminates the process.
    ///
    /// Uses `exit()` rather than `_exit()` so the kernel properly closes
    /// file descriptors and runs atexit handlers, giving frameworks
    /// (including Virtualization.framework's NVRAM backing store) a
    /// chance to flush pending writes.
    private func cleanupAndExit(_ code: Int32) -> Never {
        let isFirst = exitGuard.withLock { already -> Bool in
            guard !already else { return false }
            already = true
            return true
        }
        guard isFirst else {
            while true { pause() }
        }

        terminal.restore()
        removePIDFile()
        // Unlink any Unix socket files. `exit()` closes the descriptors for us,
        // but the filesystem entries would survive — leaving a socket file
        // (and a TCP port) that looks like a running havm. A crash or SIGKILL
        // still leaves them behind; the next start replaces them.
        metricsServer?.stop()
        fflush(stdout)
        let cont = runContinuation
        runContinuation = nil
        cont?.resume()

        // A quit Apple Event is still pending: answer it, now that the guest is
        // stopped, so loginwindow sees a clean quit instead of an app that
        // disappeared. The reply terminates the process, and AppKit requires it
        // on the main thread while the shutdown path may finish elsewhere.
        if terminationRequested, let terminationHandler {
            if let requestedAt = terminationRequestedAt {
                let seconds = Int(Date().timeIntervalSince(requestedAt).rounded())
                logger.info("Answering the quit after \(seconds)s.")
            }
            if Thread.isMainThread {
                terminationHandler(code)
            } else {
                DispatchQueue.main.sync { terminationHandler(code) }
            }
        }
        exit(code)
    }

    // MARK: - Signal handling

    /// Register DispatchSource signal monitors. Signals are delivered as GCD
    /// events on the main queue via kqueue, avoiding the async-signal-safety
    /// constraints of raw `signal()` handlers. A second signal during shutdown
    /// triggers immediate exit.
    private func setupSignalHandlers() {
        // Block default signal behavior — DispatchSource monitors via kqueue.
        signal(SIGTERM, SIG_IGN)
        signalSourceTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signalSourceTerm?.setEventHandler { [weak self] in
            self?.signalShutdown(name: "SIGTERM")
        }
        signalSourceTerm?.resume()

        // In console mode, raw terminal clears ISIG — Ctrl+C passes 0x03 to
        // the guest instead of generating SIGINT. Don't intercept it here.
        if !consoleMode {
            signal(SIGINT, SIG_IGN)
            signalSourceInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signalSourceInt?.setEventHandler { [weak self] in
                self?.signalShutdown(name: "SIGINT")
            }
            signalSourceInt?.resume()
        }

        // SIGHUP triggers graceful shutdown, config reload, and an in-process
        // VM restart without exiting.
        signal(SIGHUP, SIG_IGN)
        signalSourceHup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        signalSourceHup?.setEventHandler { [weak self] in
            self?.signalShutdown(name: "SIGHUP")
        }
        signalSourceHup?.resume()

        startConfigWatcher()
    }

    private func setupUSBDiscovery() {
        guard config.effectiveUSBEnabled else {
            logger.debug("USB: Not enabled in config — skipping accessory discovery")
            return
        }
        if #available(macOS 27.0, *) {
            // A fresh coordinator per VM instance — it holds a weak reference
            // to the controller, and restartVM() installs a new controller.
            let coordinator = USBAccessoryCoordinator(vmController: vmController, logger: logger)
            coordinator.start()
            usbCoordinator = coordinator
        } else {
            logger.info("USB accessory passthrough requires macOS 27 or later — continuing without USB")
        }
    }

    // MARK: - Config hot-reload

    private func startConfigWatcher() {
        guard let path = config.configPath else { return }
        let watcher = ConfigWatcher(path: path, logger: logger) { [weak self] in
            self?.reloadConfig()
        }
        watcher.start()
        configWatcher = watcher
    }

    private func reloadConfig() {
        guard !shutdownRequested else { return }
        guard let path = config.configPath else { return }
        guard let newConfig = try? loadConfig(path: path) else {
            logger.error("Config reload: failed to parse — keeping current config")
            return
        }
        let oldConfig = config

        let levelChanged = newConfig.effectiveLogLevel != oldConfig.effectiveLogLevel
        let tokenChanged = newConfig.effectiveHAAPIToken != oldConfig.effectiveHAAPIToken
            || newConfig.hasInlineHAAPIToken != oldConfig.hasInlineHAAPIToken
            || newConfig.effectiveHAAPITokenFilePath != oldConfig.effectiveHAAPITokenFilePath
        let haURLChanged = newConfig.effectiveHAURL != oldConfig.effectiveHAURL
        let tlsChanged = newConfig.effectiveHACACertPath != oldConfig.effectiveHACACertPath
            || newConfig.effectiveHAInsecureSkipVerify != oldConfig.effectiveHAInsecureSkipVerify
        let timeoutChanged = newConfig.effectiveShutdownTimeout != oldConfig.effectiveShutdownTimeout

        let metricsEndpointsChanged =
            newConfig.effectivePrometheusHosts != oldConfig.effectivePrometheusHosts
            || newConfig.effectivePrometheusSocketPaths != oldConfig.effectivePrometheusSocketPaths
            || newConfig.effectivePrometheusPort != oldConfig.effectivePrometheusPort
        let metricsChanged =
            newConfig.effectiveMetricsEnabled != oldConfig.effectiveMetricsEnabled
            || metricsEndpointsChanged

        if metricsChanged { applyMetricsConfig(new: newConfig, endpointsChanged: metricsEndpointsChanged) }

        config = newConfig

        if levelChanged {
            // A CLI level outranks the file, hot reload included.
            logger.logLevel = logLevelOverride ?? newConfig.effectiveLogLevel
        }
        if tlsChanged {
            haClient = HAClient(
                caCertPath: newConfig.effectiveHACACertPath,
                insecureSkipVerify: newConfig.effectiveHAInsecureSkipVerify,
                logger: logger
            )
        }
        if haURLChanged {
            resolvedHAURL = nil
        }
        if haURLChanged || tlsChanged {
            cancelActiveWebUIProbes()
        }
        if tokenChanged {
            for warning in ConfigFilePermissions.warnings(for: newConfig, configPath: path) {
                logger.warning("\(warning)")
            }
        }

        guard levelChanged || tokenChanged || haURLChanged
            || tlsChanged || timeoutChanged || metricsChanged else { return }
        logger.info("Config reloaded")
    }

    private func applyMetricsConfig(new newConfig: HavmConfig, endpointsChanged: Bool) {
        if !newConfig.effectiveMetricsEnabled {
            if metricsServer != nil {
                metricsServer?.stop()
                metricsServer = nil
                logger.info("Metrics: Server stopped (disabled).")
            }
            return
        }

        if endpointsChanged || metricsServer == nil {
            metricsServer?.stop()
            let hosts = newConfig.effectivePrometheusHosts
            let sockets = newConfig.effectivePrometheusSocketPaths
            let server = MetricsServer(
                registry: registry,
                hosts: hosts,
                sockets: sockets,
                port: newConfig.effectivePrometheusPort,
                logger: logger
            )
            server.preScrape = { [weak self] in self?.collectDiskMetrics() }
            do {
                try server.start()
                metricsServer = server
                let addr = MetricsServer.formatEndpoints(
                    hosts: hosts, port: newConfig.effectivePrometheusPort, sockets: sockets
                )
                logger.info("Metrics: Prometheus exporter on \(addr)")
            } catch {
                // Not fatal here, unlike at startup: the guest is already
                // running, and a typo in a socket path should not take it
                // down. Logged at error level so a silent metrics loss is
                // still visible.
                //
                // The old server has already been stopped, so the reference
                // must not outlive it: a non-nil `metricsServer` is what tells
                // a later reload there is one running, and it would skip the
                // restart.
                metricsServer = nil
                let level: Logger.Level = sockets.isEmpty ? .warning : .error
                logger.log(
                    level: level,
                    "Metrics: Failed to start server on port \(newConfig.effectivePrometheusPort) — \(error)."
                )
            }
        }
    }

    private func signalShutdown(name: String) {
        guard !shutdownRequested else {
            // A quit is in flight. loginwindow is waiting for the reply, and
            // launchd sends SIGTERM as it tears the session down — which would
            // otherwise look exactly like the "press Ctrl+C twice to skip the
            // wait" gesture and abort the shutdown the quit started.
            if terminationRequested {
                logger.info("\(name) received during the quit — continuing the shutdown.")
                return
            }
            // Second signal — force immediate exit
            logger.warning("\(name) received again — exiting immediately")
            cleanupAndExit(1)
        }
        if name == "SIGHUP" {
            restartRequested = true
            beginShutdown(logging: "\(name) received — restarting VM...")
        } else {
            beginShutdown(logging: "\(name) received — initiating graceful shutdown...")
        }
    }

    /// Shut the guest down because the application is terminating: a logout, a
    /// restart, or Cmd+Q. Idempotent — AppKit asks on every quit attempt, and a
    /// second request while the guest is already halting must not restart the
    /// chain or force-stop a guest that is shutting down cleanly.
    public func requestTermination() {
        // Set even when a shutdown is already running, so that shutdown's
        // `cleanupAndExit` answers the quit instead of exiting outright.
        if terminationRequestedAt == nil { terminationRequestedAt = Date() }
        terminationRequested = true
        // A quit outranks a restart. A terminal run gets SIGHUP when the
        // terminal itself quits at logout, which starts a *restart*; if the
        // quit then arrives, the shutdown that is already running has to end
        // in an answer, not in a fresh VM the session will kill.
        restartRequested = false
        guard !shutdownRequested else { return }
        beginShutdown(logging: "Quit requested — initiating graceful shutdown...")
    }

    /// Record what the guest is doing and tell the application layer. The
    /// status is read by the Dock menu and written from whichever executor the
    /// boot phase happens to be on, so the write and the callback both happen
    /// on the main thread.
    private func setGuestStatus(_ status: GuestStatus) {
        if Thread.isMainThread {
            applyGuestStatus(status)
        } else {
            DispatchQueue.main.async { [weak self] in self?.applyGuestStatus(status) }
        }
    }

    private func applyGuestStatus(_ status: GuestStatus) {
        guard guestStatus != status else { return }
        guestStatus = status
        guestMetrics.record(status)
        guestStatusChanged?(status)
    }

    /// Whether Home Assistant can be asked to restart itself. It takes an API
    /// token, so this is only offered when one is configured — the Dock menu
    /// leaves the item out entirely rather than showing it permanently greyed.
    public var canRestartHomeAssistant: Bool {
        config.effectiveHAAPIToken != nil
    }

    /// Ask the running Home Assistant to restart itself, through the same REST
    /// API the shutdown chain uses. Fire-and-forget: the guest stays up either
    /// way, so the outcome is only ever a log line. This is not part of the
    /// shutdown chain — it restarts Home Assistant Core inside a guest that
    /// keeps running.
    public func restartHomeAssistant() {
        guard let base = resolvedHAURL, let token = config.effectiveHAAPIToken else {
            logger.warning("Cannot restart Home Assistant yet: no address or API token.")
            return
        }
        let client = haClient
        let logger = self.logger
        logger.info("Restarting Home Assistant at \(base)...")
        Task {
            switch await client.restartHomeAssistant(baseURL: base, token: token) {
            case .accepted:
                logger.info("Home Assistant restart accepted.")
            case .rejected(let code):
                logger.warning("Home Assistant restart rejected (HTTP \(code)).")
            case .failed(let detail):
                logger.warning("Home Assistant restart failed: \(detail)")
            }
        }
    }

    private func beginShutdown(logging message: String) {
        shutdownRequested = true
        logger.info("\(message)")
        let ip = guestIP
        let cfg = config
        let candidates = haBaseURLCandidates(host: ip)
        let client = haClient
        Task { await performGracefulShutdown(guestIP: ip, candidates: candidates, config: cfg, client: client) }
    }

    private func performGracefulShutdown(
        guestIP: String?, candidates: [String], config: HavmConfig, client: HAClient
    ) async {
        // The defer fires on every exit path — graceful stop (early return),
        // force-stop fallthrough, or error. For SIGHUP (restartRequested set),
        // we restart the VM in-process instead of exiting.
        defer {
            if restartRequested {
                restartVM()
            } else {
                cleanupAndExit(0)
            }
        }

        // A single deadline bounds the whole graceful phase. Every request
        // attempt and every wait for the guest to halt is drawn from this same
        // budget, so falling through to the next method can't hand it a fresh
        // full timeout — which used to force-stop a guest that was still
        // shutting down cleanly (see issue #11).
        let deadline = Date().addingTimeInterval(TimeInterval(config.effectiveShutdownTimeout))
        logger.info("Waiting up to \(config.effectiveShutdownTimeout)s for the guest to halt.")

        guard let ip = guestIP else {
            logger.warning("Guest IP unknown (network not ready) — force-stopping...")
            await forceStop()
            return
        }

        let token = config.effectiveHAAPIToken
        let chain = ShutdownChain(
            deadline: deadline,
            methods: ShutdownPolicy.methods(hasAPIToken: token != nil),
            attempt: { [self] method, budget in
                logger.info("\(method.logDescription)")
                switch method {
                case .restAPI:
                    guard let token else { return .failed }
                    switch await client.supervisorShutdown(candidates: candidates, token: token, timeout: budget) {
                    case .success:
                        return .accepted
                    case .timedOut:
                        // Request sent but the host may already be shutting
                        // down — the response didn't come back.
                        logger.debug("REST API timed out — host may already be shutting down.")
                        return .unanswered
                    case .failed:
                        return .failed
                    }
                case .debugSSH:
                    let ok = await sshShutdown(
                        host: ip, port: 22222, command: "shutdown -h now", timeout: budget)
                    return ok ? .accepted : .failed
                case .sshAddon:
                    let ok = await sshShutdown(
                        host: ip, port: 22, command: "ha host shutdown", timeout: budget)
                    return ok ? .accepted : .failed
                }
            },
            waitForStop: { [self] deadline in await waitForStop(until: deadline) }
        )

        switch await chain.run() {
        case .halted:
            return
        case .acceptedButStillRunning:
            logger.warning(
                "Shutdown was accepted, but the guest had not halted after \(config.effectiveShutdownTimeout)s — force-stopping. Raise shutdown.timeout_seconds if the guest needs longer."
            )
        case .nothingAccepted:
            logger.warning("All shutdown methods failed — force-stopping...")
            if let tip = ShutdownPolicy.unconfiguredTip(
                hasAPIToken: config.effectiveHAAPIToken != nil,
                hasSSHKeys: config.effectiveSSHKeyPath != nil
            ) {
                logger.warning("\(tip).")
            }
        }

        await forceStop()
        // defer block above handles restart-vs-exit decision
    }

    private func forceStop() async {
        do {
            try await vmController.forceStop()
            logger.info("Force stop completed.")
        } catch {
            logger.error("Force stop failed: \(error)")
        }
    }

    /// Restart the VM in-process: reload config, create a fresh
    /// `VMController`, and start the new VM with updated config.
    /// Called after graceful shutdown when `restartRequested` is set
    /// (e.g. SIGHUP). No process exit — the calling task continues.
    ///
    /// The work happens on the main queue, wherever this is called from. The
    /// shutdown chain finishes on a background executor, and everything below
    /// — `config`, the poll counters, the flags — is read on the main queue by
    /// the boot timer, the Dock menu and the VM state callback. `@unchecked
    /// Sendable` on this class means the compiler will not catch that for us.
    private func restartVM() {
        guard !Thread.isMainThread else {
            restartVMOnMain()
            return
        }
        DispatchQueue.main.async { [weak self] in self?.restartVMOnMain() }
    }

    private func restartVMOnMain() {
        // A quit that landed while the guest was halting outranks the restart:
        // starting a fresh VM here would leave the quit unanswered, and the
        // session would kill the process with the new guest already booting.
        if terminationRequested { cleanupAndExit(0) }
        // Reload config from disk so VM settings (CPU, memory, disk,
        // network) take effect on restart.
        let oldConfig = config
        do {
            // By the recorded path, not `loadConfig()`: that reads the default
            // location and misses `-c`, which is what brew services passes
            // (issue #23).
            config = try loadConfig(path: config.configPath)
            logger.info("Config reloaded for restart")
        } catch {
            logger.warning("Failed to reload config: \(error) — keeping current config")
        }

        // Re-apply hot-reloadable settings (log level, metrics, HA TLS, token permissions).
        logger.logLevel = logLevelOverride ?? config.effectiveLogLevel
        if let configPath = config.configPath {
            for warning in ConfigFilePermissions.warnings(for: config, configPath: configPath) {
                logger.warning("\(warning)")
            }
        }
        let metricsEndpointsChanged =
            config.effectivePrometheusHosts != oldConfig.effectivePrometheusHosts
            || config.effectivePrometheusSocketPaths != oldConfig.effectivePrometheusSocketPaths
            || config.effectivePrometheusPort != oldConfig.effectivePrometheusPort
        if config.effectiveMetricsEnabled != oldConfig.effectiveMetricsEnabled || metricsEndpointsChanged {
            applyMetricsConfig(new: config, endpointsChanged: metricsEndpointsChanged)
        }
        haClient = HAClient(
            caCertPath: config.effectiveHACACertPath,
            insecureSkipVerify: config.effectiveHAInsecureSkipVerify,
            logger: logger
        )

        // Re-apply pre-boot disk settings (disk_size increase, ssh.authorized_keys).
        let setupManager = HAOSSetupManager(config: config, logger: logger)
        do {
            try setupManager.refreshBeforeBoot()
            if consoleMode {
                HAOSSetupManager.ensureConsoleCmdline()
            }
        } catch {
            logger.warning("Pre-restart setup refresh failed: \(error) — continuing with existing disk state")
        }

        // Use a fresh logger for the new VM controller so its label
        // doesn't carry the old instance's identity.
        var vmLogger = Logger(label: "havm.vm")
        vmLogger.logLevel = logLevelOverride ?? config.effectiveLogLevel

        let newController = VMController(config: config, consoleMode: consoleMode, logger: vmLogger)
        observe(newController)

        // Reset boot-phase state for the new VM.
        guestReachableNotified = false
        supervisorReachableNotified = false
        webUIReadyNotified = false
        firstProbeDone = false
        guestIP = nil
        resolvedHAURL = nil
        setGuestStatus(.booting)
        lastDHCPLeaseModDate = nil
        cachedDHCPLeaseIP = nil
        cachedMACString = nil
        cachedMACBytes = nil
        shutdownRequested = false
        restartRequested = false
        terminationRequested = false
        terminationRequestedAt = nil
        bootTimer?.cancel()
        bootTimer = nil
        observerProbe?.task.cancel()
        observerProbe = nil
        cancelActiveWebUIProbes()

        // Already on the main queue, which `VZVirtualMachine.start()` requires.
        newController.startVMBlocking { [weak self] startError in
            guard let self else { return }
            if let error = startError {
                self.logger.error("Failed to restart VM: \(error)")
                self.cleanupAndExit(1)
            }

            self.vmController = newController

            // USB accessories are hot-attached — the new controller's XHCI
            // configuration will pick up any devices the listener re-discovers
            // after the new VM boots.
            self.setupUSBDiscovery()

            self.logger.info("VM restarted successfully")
            self.startBootPhase()
        }
    }

    /// Wait for the VM to reach `.stopped` state, within the shared
    /// graceful-shutdown budget.
    /// - Returns: `true` if the VM stopped, `false` if the deadline passed.
    private func waitForStop(until deadline: Date) async -> Bool {
        while Date() < deadline {
            if vmController.state == .stopped {
                logger.info("VM stopped gracefully.")
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// Base URLs to try for the Home Assistant HTTP server, in order.
    private func haBaseURLCandidates(host: String? = nil) -> [String] {
        if let configured = config.effectiveHAURL {
            return [configured]
        }
        if let resolved = resolvedHAURL {
            return [resolved]
        }
        guard let ip = host ?? guestIP else { return [] }
        return HAEndpoint.probePorts.map { HAEndpoint.baseURL(host: ip, port: $0) }
    }

    /// Hardened SSH arguments for automated guest shutdown. Disables agent and
    /// port forwarding, local commands, and TTY so `~/.ssh/config` cannot expose
    /// credentials when host-key verification is off over mDNS.
    static func sshShutdownArguments(host: String, port: Int, command: String, timeout: Int) -> [String] {
        [
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=\(ShutdownPolicy.sshConnectTimeout(within: timeout))",
            "-o", "BatchMode=yes",
            "-o", "ForwardAgent=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "PermitLocalCommand=no",
            "-o", "RequestTTY=no",
            "-p", "\(port)",
            "--",
            "root@\(host)",
            command,
        ]
    }

    private func sshShutdown(host: String, port: Int, command: String, timeout: Int) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.sshShutdownArguments(
            host: host, port: port, command: command, timeout: timeout
        )

        // Capture stderr so we can log why SSH failed (key issues, connection
        // refused, etc.). This helps users troubleshoot SSH shutdown problems.
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        let logger = self.logger

        // Terminate the process if it doesn't finish within the timeout.
        let deadlineTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
            if process.isRunning {
                logger.warning("SSH (port \(port)) timed out after \(timeout)s — terminating")
                process.terminate()
            }
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                deadlineTask.cancel()
                let succeeded = proc.terminationStatus == 0
                if !succeeded {
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrText = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !stderrText.isEmpty {
                        logger.debug("SSH (port \(port)) stderr: \(stderrText)")
                    }
                }
                continuation.resume(returning: succeeded)
            }
            do {
                try process.run()
            } catch {
                deadlineTask.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Guest connectivity

    /// Discover the guest host/IP. Hands `network.hostname` (or
    /// `homeassistant.local` in bridge mode) directly to the network stack;
    /// falls back to DHCP lease parsing in NAT mode (including runtime bridge→NAT fallback).
    private func checkGuestNetwork() {
        let ip: String?

        if let hostname = config.effectiveGuestHostname(networkType: vmController.actualNetworkType) {
            ip = hostname
        } else {
            // NAT mode without explicit hostname: parse DHCP lease file by MAC
            ip = discoverViaDHCPLeases()
        }

        if ip == nil, !firstProbeDone {
            firstProbeDone = true
            if let mac = vmController.guestMAC {
                logger.info("Waiting for guest DHCP lease (MAC \(mac))...")
            }
        }

        guard let ip, !ip.isEmpty, ip != guestIP else { return }
        guestIP = ip

        if !guestReachableNotified {
            guestReachableNotified = true
            logger.info("Waiting for Home Assistant at \(ip)...")
            let webCandidates = haBaseURLCandidates(host: ip)
            logger.info("  Web: \(webCandidates.joined(separator: " or "))")
            logger.info("  SSH: ssh root@\(ip) -p 22222")
        }
    }

    private func cancelActiveWebUIProbes() {
        for probe in activeWebUIProbes.values {
            probe.task.cancel()
        }
        activeWebUIProbes.removeAll()
        nextWebUIProbeAt.removeAll()
    }

    /// Poll the Supervisor's Observer `/ping` endpoint on port 4357, enforcing
    /// a hard wall-clock deadline so a stalled request never wedges polling.
    private func checkObserver() {
        let now = Date()
        if let deadline = bootDeadline, now >= deadline { return }
        if let active = observerProbe {
            guard now >= active.deadline else { return }
            active.task.cancel()
            observerProbe = nil
            nextObserverProbeAt = now.addingTimeInterval(Self.probeRetryIntervalSeconds)
        }
        guard now >= nextObserverProbeAt, let ip = guestIP else { return }

        let client = haClient
        let deadline = now.addingTimeInterval(Self.observerProbeTimeoutSeconds)
        let task = Task { @MainActor [weak self] in
            let reachable = await client.pingObserver(host: ip, timeout: 2)
            guard let self, !Task.isCancelled else { return }
            self.observerProbe = nil
            self.nextObserverProbeAt = Date().addingTimeInterval(Self.probeRetryIntervalSeconds)
            guard reachable, !self.supervisorReachableNotified else { return }
            self.supervisorReachableNotified = true
            self.logger.info("Supervisor is running at \(ip):4357 — Home Assistant is starting up...")
        }
        observerProbe = (task, deadline)
    }

    /// Poll each candidate Home Assistant web UI URL independently with a hard
    /// wall-clock deadline per probe so neither a stalled request nor a
    /// blackholed sibling port can block readiness detection.
    private func checkWebUI() {
        let now = Date()
        if let deadline = bootDeadline, now >= deadline {
            if !webUIReadyNotified {
                webUIReadyNotified = true
                observerProbe?.task.cancel()
                observerProbe = nil
                cancelActiveWebUIProbes()
                logger.warning("Timed out waiting for Home Assistant web UI after 5 minutes")
                setGuestStatus(.unreachable)
            }
            return
        }

        let candidates = haBaseURLCandidates()
        guard !candidates.isEmpty else { return }
        let client = haClient

        for baseURL in candidates {
            if let active = activeWebUIProbes[baseURL] {
                guard now >= active.deadline else { continue }
                active.task.cancel()
                activeWebUIProbes.removeValue(forKey: baseURL)
                nextWebUIProbeAt[baseURL] = now.addingTimeInterval(Self.probeRetryIntervalSeconds)
            }
            guard now >= (nextWebUIProbeAt[baseURL] ?? .distantPast) else { continue }

            let deadline = now.addingTimeInterval(Self.webUIProbeTimeoutSeconds)
            let task = Task { @MainActor [weak self] in
                let ok = await client.answersManifest(at: baseURL, timeout: Self.webUIProbeTimeoutSeconds)
                guard let self, !Task.isCancelled else { return }
                self.activeWebUIProbes.removeValue(forKey: baseURL)
                self.nextWebUIProbeAt[baseURL] = Date().addingTimeInterval(Self.probeRetryIntervalSeconds)
                guard ok else { return }

                self.cancelActiveWebUIProbes()
                self.resolvedHAURL = baseURL
                if let url = URL(string: baseURL) {
                    self.setGuestStatus(.ready(url))
                }
                guard !self.webUIReadyNotified else { return }
                self.webUIReadyNotified = true
                self.logger.info("Home Assistant is ready at \(baseURL)")
            }
            activeWebUIProbes[baseURL] = (task, deadline)
        }
    }

    // MARK: - Disk metrics

    /// Collect disk usage metrics for VM disk images. Called on each
    /// Prometheus scrape via a ``MetricsServer/preScrape`` hook so the
    /// gauge is always fresh without a recurring timer.
    ///
    /// `logical` is the size the guest sees and `allocated` is what the image
    /// takes on the host. For a raw image the two differ because APFS punches
    /// holes; for an ASIF container the logical size is recorded inside the
    /// file, so reading its length would understate the disk by an order of
    /// magnitude.
    public func collectDiskMetrics() {
        let disks: [(String, String)] = [
            ("main", HavmConfig.persistentDiskPath),
        ]
        for (label, path) in disks {
            guard let info = DiskImageSupport.info(at: URL(fileURLWithPath: path)) else {
                continue
            }
            Gauge(label: "havm_disk_usage_bytes", dimensions: [
                ("disk", label),
                ("type", "logical"),
            ]).record(Double(info.virtualSize))
            Gauge(label: "havm_disk_usage_bytes", dimensions: [
                ("disk", label),
                ("type", "allocated"),
            ]).record(Double(info.allocatedSize))
        }
    }

    private func currentGuestMACBytes() -> [UInt8]? {
        guard let mac = vmController.guestMAC else { return nil }
        if mac != cachedMACString {
            cachedMACString = mac
            cachedMACBytes = DHCPLeases.bytes(ofMAC: mac)
        }
        return cachedMACBytes
    }

    private func discoverViaDHCPLeases() -> String? {
        guard let guestMACBytes = currentGuestMACBytes() else { return nil }

        let leaseURL = URL(fileURLWithPath: DHCPLeases.path)

        // Skip re-reading if the file hasn't changed since last check.
        if let lastMod = lastDHCPLeaseModDate,
           let attrs = try? FileManager.default.attributesOfItem(atPath: leaseURL.path),
           let currentMod = attrs[.modificationDate] as? Date,
           currentMod <= lastMod {
            return cachedDHCPLeaseIP
        }

        guard let leaseData = try? Data(contentsOf: leaseURL),
              let leaseText = String(data: leaseData, encoding: .utf8) else { return nil }

        // Update the mod-date cache before parsing so we track the latest read.
        lastDHCPLeaseModDate = (try? FileManager.default.attributesOfItem(atPath: leaseURL.path))
            .flatMap { $0[.modificationDate] as? Date }

        cachedDHCPLeaseIP = DHCPLeases.address(forMAC: guestMACBytes, in: leaseText)
        return cachedDHCPLeaseIP
    }

    // MARK: - PID file

    private func writePIDFile() {
        PIDFile.write(at: HavmConfig.pidFilePath, logger: logger)
    }

    private func removePIDFile() {
        PIDFile.remove(at: HavmConfig.pidFilePath, logger: logger)
    }

}
