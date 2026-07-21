import Foundation
@preconcurrency import Virtualization
import Logging
import AppKit
import AccessoryAccess
import Metrics

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
/// Registers an `AAUSBAccessoryListener` after VM start. macOS shows a menu
/// bar item where the user selects which USB accessories to attach. On connect,
/// the accessory is hot-attached to the running VM.
public final class ServiceRuntime: NSObject, AAUSBAccessoryListener, @unchecked Sendable {
    private var config: HavmConfig
    private var vmController: VMController
    private var logger: Logger
    private let consoleMode: Bool

    private var runContinuation: CheckedContinuation<Void, Never>?
    private var shutdownRequested = false
    private var restartRequested = false
    private var guestReachableNotified = false
    private var supervisorReachableNotified = false
    private var webUIReadyNotified = false
    private var firstProbeDone = false
    private var guestIP: String?
    private var signalSourceTerm: DispatchSourceSignal?
    private var signalSourceInt: DispatchSourceSignal?
    private var signalSourceHup: DispatchSourceSignal?
    private var configDirWatcher: DispatchSourceFileSystemObject?
    private var configDirDescriptor: Int32 = -1
    private var configFileWatcher: DispatchSourceFileSystemObject?
    private var observerPollCount = 0
    private let observerPollMax = 120  // 120 × 250 ms = 30 s
    private var healthPollCount = 0
    private let healthPollMax = 1200  // 1200 × 250 ms = 5 minutes
    private var bootTimer: DispatchSourceTimer?
    private var observerTask: Task<Void, Never>?
    private var webUITask: Task<Void, Never>?
    private var metricsServer: MetricsServer?
    private let registry: SimpleRegistry
    private var usbAccessoryCount: Int = 0
    private var originalTermios: termios?
    private var rawModeEnabled = false

    public init(
        config: HavmConfig,
        vmController: VMController,
        consoleMode: Bool = false,
        metricsServer: MetricsServer? = nil,
        registry: SimpleRegistry,
        logger: Logger = Logger(label: "havm.runtime")
    ) {
        self.config = config
        self.vmController = vmController
        self.consoleMode = consoleMode
        self.metricsServer = metricsServer
        self.registry = registry
        self.logger = logger
        super.init()

        vmController.onStateChange = { [weak self] state in
            let name = state.description
            self?.logger.info("VM state: \(name)")
            if state == .stopped, self?.shutdownRequested != true {
                self?.cleanupAndExit(0)
            }
        }
    }

    /// Run the VM, blocking the calling thread until the VM exits or a signal is received.
    public func runBlocking() async -> Int32 {
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
                    self.enableRawMode()
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
        return 0
    }

    // MARK: - Boot instructions

    private func printBootingInstructions() {
        // Only print the banner for interactive terminal use.
        // When stdout is not a TTY (launchd service, piped output,
        // redirected to log file), nobody is watching and the ASCII
        // art would break JSON consumers that parse stdout.
        guard isatty(STDOUT_FILENO) != 0 else { return }
        var lines: [String]
        let mode = config.effectiveNetworkType == .nat ? " (NAT mode)" : ""
        // 57-character content area between ║ borders.
        let header = "Home Assistant OS is booting\(mode)."
        let pad = String(repeating: " ", count: 55 - header.count)
        lines = [
            "",
            "╔══════════════════════════════════════════════════════════╗",
            "║  \(header)\(pad) ║",
            "║                                                          ║",
        ]
        switch config.effectiveNetworkType {
        case .nat:
            lines += [
                "║  SSH:  ssh root@<guest-ip> -p 22222                      ║",
                "║  Web:  http://<guest-ip>:8123                            ║",
            ]
        case .bridge:
            lines += [
                "║  Once ready, open:                                       ║",
                "║    http://homeassistant.local:8123                       ║",
                "║                                                          ║",
                "║  Or check your router's DHCP lease table for the VM's    ║",
                "║  IP address and open http://<ip>:8123                    ║",
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

    /// Runs at 250 ms intervals until the guest IP is discovered and the web
    /// UI responds. After that, the timer is cancelled — no more scheduled
    /// work. Signals, VZ delegate callbacks, and config-watcher events arrive
    /// through GCD dispatch sources and terminate the process via
    /// `cleanupAndExit()`.
    ///
    /// Uses `DispatchSourceTimer` instead of recursive `asyncAfter` to avoid
    /// creating a new scheduled work item every tick.
    private func startBootPhase() {
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
                cleanupAndExit(0)
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
        restoreTerminal()
        removePIDFile()
        fflush(stdout)
        runContinuation?.resume()
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

        // SIGHUP triggers graceful shutdown, then launchd / Homebrew
        // keep_alive restarts the process — giving the user a clean
        // config-change restart path.
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
        // Initialize the gauge so it appears in /metrics even before
        // any accessory connects (zero is a meaningful initial value).
        Gauge(label: "havm_usb_accessories").record(0)

        // AAUSBAccessoryManager needs a running NSApplication.
        // Called from main queue via DispatchQueue.main.async, but NSApplication
        // is @MainActor — use MainActor.assumeIsolated to satisfy the compiler.
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.accessory)
        } as Void

        AAUSBAccessoryManager.shared.registerListener(
            self, matchingCriteria: [],
            completionHandler: { [weak self] accessories, error in
                if let error {
                    self?.logger.info("USB: Listener not available (restricted entitlement missing): \(error.localizedDescription)")
                    return
                }
                self?.logger.info("USB: Listener registered — \(accessories.count) already connected")
                for acc in accessories {
                    self?.vmController.attachAccessory(acc)
                }
            }
        )
    }

    // MARK: - AAUSBAccessoryListener

    public func usbAccessoryDidConnect(_ accessory: AAUSBAccessory) {
        let (vid, pid) = accessory.vendorProductID
        logger.info("USB: Accessory connected — 0x\(String(vid, radix: 16, uppercase: true)):0x\(String(pid, radix: 16, uppercase: true)) (registryID=\(accessory.registryID))")
        vmController.attachAccessory(accessory)
        usbAccessoryCount += 1
        Gauge(label: "havm_usb_accessories").record(Double(usbAccessoryCount))
    }

    public func usbAccessoryDidDisconnect(_ accessory: AAUSBAccessory) {
        let (vid, pid) = accessory.vendorProductID
        logger.info("USB: Accessory disconnected — 0x\(String(vid, radix: 16, uppercase: true)):0x\(String(pid, radix: 16, uppercase: true)) (registryID=\(accessory.registryID))")
        usbAccessoryCount = max(0, usbAccessoryCount - 1)
        Gauge(label: "havm_usb_accessories").record(Double(usbAccessoryCount))
    }

    // MARK: - Config hot-reload

    private func startConfigWatcher() {
        guard let path = config.configPath else { return }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path

        // 1. Directory watcher — catches atomic saves (temp file + rename).
        let dirFD = open(dir, O_EVTONLY)
        guard dirFD >= 0 else {
            logger.debug("Config watcher: cannot open \(dir)")
            return
        }
        configDirDescriptor = dirFD
        let dirSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD, eventMask: .write, queue: .main
        )
        dirSource.setEventHandler { [weak self] in
            guard let self, let path = self.config.configPath else { return }
            guard FileManager.default.fileExists(atPath: path) else { return }
            self.reloadConfig()
            self.restartFileWatcher()  // atomic save → new inode
        }
        dirSource.setCancelHandler { [weak self] in
            if let fd = self?.configDirDescriptor, fd >= 0 {
                close(fd)
                self?.configDirDescriptor = -1
            }
        }
        dirSource.resume()
        configDirWatcher = dirSource

        // 2. File watcher — catches in-place writes.
        restartFileWatcher()
    }

    private func restartFileWatcher() {
        configFileWatcher?.cancel()
        configFileWatcher = nil
        guard let path = config.configPath else { return }
        let fileFD = open(path, O_EVTONLY)
        guard fileFD >= 0 else { return }
        let fileSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileFD, eventMask: [.write, .extend], queue: .main
        )
        fileSource.setEventHandler { [weak self] in
            self?.reloadConfig()
        }
        fileSource.setCancelHandler { close(fileFD) }
        fileSource.resume()
        configFileWatcher = fileSource
    }

    private func reloadConfig() {
        guard !shutdownRequested else { return }
        guard let path = config.configPath else { return }
        guard let newConfig = try? loadConfig(path: path) else {
            logger.debug("Config reload: failed to parse — keeping current config")
            return
        }
        let oldConfig = config

        let levelChanged = newConfig.effectiveLogLevel != oldConfig.effectiveLogLevel
        let tokenChanged = newConfig.effectiveHAAPIToken != oldConfig.effectiveHAAPIToken

        let metricsEnabledChanged = newConfig.effectiveMetricsEnabled != oldConfig.effectiveMetricsEnabled
        let metricsHostChanged = newConfig.effectivePrometheusHosts != oldConfig.effectivePrometheusHosts
        let metricsPortChanged = newConfig.effectivePrometheusPort != oldConfig.effectivePrometheusPort
        let metricsChanged = metricsEnabledChanged || metricsHostChanged || metricsPortChanged

        if metricsChanged { applyMetricsConfig(old: oldConfig, new: newConfig) }

        config = newConfig

        guard levelChanged || tokenChanged || metricsChanged else { return }

        if levelChanged {
            logger.logLevel = newConfig.effectiveLogLevel
        }
        logger.info("Config reloaded")
    }

    private func applyMetricsConfig(old oldConfig: HavmConfig, new newConfig: HavmConfig) {
        if !newConfig.effectiveMetricsEnabled {
            if metricsServer != nil {
                metricsServer?.stop()
                metricsServer = nil
                logger.info("Metrics: Server stopped (disabled).")
            }
            return
        }

        // Enabled — if host or port changed (or first enable), restart.
        let hostChanged = newConfig.effectivePrometheusHosts != oldConfig.effectivePrometheusHosts
        let portChanged = newConfig.effectivePrometheusPort != oldConfig.effectivePrometheusPort

        if hostChanged || portChanged || metricsServer == nil {
            metricsServer?.stop()
            let hosts = newConfig.effectivePrometheusHosts
            let server = MetricsServer(
                registry: registry,
                hosts: hosts,
                port: newConfig.effectivePrometheusPort,
                logger: logger
            )
            server.preScrape = { [weak self] in self?.collectDiskMetrics() }
            do {
                try server.start()
                metricsServer = server
                let addr = MetricsServer.formatHostsPort(hosts, port: newConfig.effectivePrometheusPort)
                logger.info("Metrics: Prometheus exporter on \(addr)")
            } catch {
                logger.warning("Metrics: Failed to start server on port \(newConfig.effectivePrometheusPort) — \(error).")
            }
        }
    }

    private func signalShutdown(name: String) {
        guard !shutdownRequested else {
            // Second signal — force immediate exit
            logger.warning("\(name) received again — exiting immediately")
            cleanupAndExit(1)
        }
        shutdownRequested = true
        if name == "SIGHUP" {
            restartRequested = true
            logger.info("\(name) received — restarting VM...")
        } else {
            logger.info("\(name) received — initiating graceful shutdown...")
        }
        let ip = guestIP
        let cfg = config
        Task { await performGracefulShutdown(guestIP: ip, config: cfg) }
    }

    private func performGracefulShutdown(guestIP: String?, config: HavmConfig) async {
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

        let timeout = config.effectiveShutdownTimeout

        if let ip = guestIP {
            // 1. HA REST API on port 8123 (if api_token is configured)
            if let token = config.effectiveHAAPIToken {
                logger.info("Attempting shutdown via REST API...")
                let result = await supervisorShutdown(host: ip, token: token, timeout: timeout)
                switch result {
                case .success:
                    if await waitForStop(timeout: timeout) { return }
                case .timedOut:
                    // Request sent but host may be shutting down — response
                    // didn't come back. Wait for the VM to stop anyway.
                    logger.debug("REST API timed out — host may already be shutting down.")
                    if await waitForStop(timeout: timeout) { return }
                case .failed:
                    break // fall through to SSH
                }
            }
            // 2. Debug SSH on port 22222 (root on host, direct shutdown)
            logger.info("Attempting SSH shutdown via port 22222...")
            if await sshShutdown(host: ip, port: 22222, command: "shutdown -h now", timeout: timeout),
               await waitForStop(timeout: timeout) {
                return
            }
            // 3. Terminal & SSH add-on on port 22 (container, uses ha host shutdown)
            logger.info("Attempting SSH shutdown via port 22...")
            if await sshShutdown(host: ip, port: 22, command: "ha host shutdown", timeout: timeout),
               await waitForStop(timeout: timeout) {
                return
            }
            if config.effectiveHAAPIToken == nil {
                logger.warning(
                    "Tip: configure ha.api_token (REST API), ssh.authorized_keys (debug SSH), or install the Terminal & SSH app in Home Assistant."
                )
            }
            logger.warning("All shutdown methods failed — force-stopping...")
        } else {
            logger.warning("Guest IP unknown (network not ready) — force-stopping...")
        }

        do {
            try await vmController.forceStop()
            logger.info("Force stop completed.")
        }
        catch { logger.error("Force stop failed: \(error)") }
        // defer block above handles restart-vs-exit decision
    }

    /// Restart the VM in-process: reload config, create a fresh
    /// `VMController`, and start the new VM with updated config.
    /// Called after graceful shutdown when `restartRequested` is set
    /// (e.g. SIGHUP). No process exit — the calling task continues.
    private func restartVM() {
        // Reload config from disk so VM settings (CPU, memory, disk,
        // network) take effect on restart.
        do {
            config = try loadConfig()
            logger.info("Config reloaded for restart")
        } catch {
            logger.warning("Failed to reload config: \(error) — keeping current config")
        }

        // Re-apply hot-reloadable settings (log level may have changed).
        logger.logLevel = config.effectiveLogLevel

        // Use a fresh logger for the new VM controller so its label
        // doesn't carry the old instance's identity.
        var vmLogger = Logger(label: "havm.vm")
        vmLogger.logLevel = config.effectiveLogLevel

        let newController = VMController(config: config, consoleMode: consoleMode, logger: vmLogger)

        // Reset boot-phase state for the new VM.
        guestReachableNotified = false
        supervisorReachableNotified = false
        webUIReadyNotified = false
        firstProbeDone = false
        guestIP = nil
        observerPollCount = 0
        healthPollCount = 0
        shutdownRequested = false
        restartRequested = false
        bootTimer?.cancel()
        observerTask?.cancel()
        webUITask?.cancel()

        // VZVirtualMachine.start() asserts for the main queue, but
        // restartVM() is called from the defer of an async Task on the
        // global executor. Dispatch explicitly.
        DispatchQueue.main.async { [self] in
            newController.startVMBlocking { [weak self] startError in
                guard let self else { return }
                if let error = startError {
                    self.logger.error("Failed to restart VM: \(error)")
                    self.cleanupAndExit(1)
                }

                self.vmController = newController

                // USB accessories are hot-attached — the new controller's
                // XHCI configuration will pick up any devices the listener
                // re-discovers after the new VM boots.
                self.setupUSBDiscovery()

                self.logger.info("VM restarted successfully")
                self.startBootPhase()
            }
        }
    }

    /// Wait for the VM to reach `.stopped` state.
    /// - Returns: `true` if the VM stopped, `false` if timed out.
    private func waitForStop(timeout: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            if vmController.state == .stopped {
                logger.info("VM stopped gracefully.")
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// Result of a REST API shutdown call.
    private enum RESTAPIResult {
        case success   // HTTP 200 — shutdown accepted
        case timedOut  // Request timed out — host may be shutting down
        case failed    // Definitive failure — fall through to next method
    }

    private static let emptyJSONBody = Data("{}".utf8)

    /// Resolve the base URL for the Home Assistant REST API.
    private func haBaseURL(host: String? = nil) -> String? {
        if let configured = config.effectiveHAURL {
            return configured
        }
        if let ip = host ?? guestIP {
            // Bracket IPv6 addresses for URL authority: http://[::1]:8123
            let authority = ip.contains(":") ? "[\(ip)]" : ip
            return "http://\(authority):8123"
        }
        return nil
    }

    /// Send a shutdown command to the guest via the Home Assistant REST API.
    /// Calls the `hassio.host_shutdown` service with a Bearer token.
    /// Uses `ha.url` if configured, otherwise defaults to
    /// `http://<discovered-ip>:8123`.
    private func supervisorShutdown(host: String, token: String, timeout: Int) async -> RESTAPIResult {
        guard let baseURL = haBaseURL(host: host) else { return .failed }
        guard let url = URL(string: "\(baseURL)/api/services/hassio/host_shutdown") else {
            return .failed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.emptyJSONBody
        request.timeoutInterval = TimeInterval(min(timeout, 10))

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed
            }
            if httpResponse.statusCode == 200 {
                logger.info("REST API shutdown accepted.")
                return .success
            }
            // 401/403: token is wrong or expired — user needs to know.
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                logger.warning("REST API: HTTP \(httpResponse.statusCode) — check ha.api_token in config.")
            } else {
                logger.info("REST API: HTTP \(httpResponse.statusCode) — falling through to SSH.")
            }
            return .failed
        } catch let error as URLError where error.code == .timedOut {
            return .timedOut
        } catch {
            logger.info("REST API unavailable (\(error.localizedDescription)) — falling through to SSH.")
            return .failed
        }
    }

    /// Send a shutdown command to the guest via SSH.
    /// - Returns: `true` if the SSH command succeeded (exit code 0).
    private func sshShutdown(host: String, port: Int, command: String, timeout: Int) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=\(min(timeout, 5))",
            "-o", "BatchMode=yes",
            "-p", "\(port)",
            "root@\(host)",
            command
        ]

        // Capture stderr so we can log why SSH failed (key issues, connection
        // refused, etc.). This helps users troubleshoot SSH shutdown problems.
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        let logger = self.logger
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
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
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Guest connectivity

    /// Discover the guest IP. If a hostname is configured (or defaults to
    /// `homeassistant.local` in bridge mode), try mDNS resolution. Falls back
    /// to DHCP lease parsing in NAT mode.
    private func checkGuestNetwork() {
        let ip: String?

        if let hostname = config.effectiveGuestHostname {
            // If it looks like an IP, use it directly; otherwise resolve via DNS/mDNS
            ip = resolveOrUseIP(hostname)
        } else {
            // NAT mode without explicit hostname: parse DHCP lease file by MAC
            ip = discoverViaDHCPLeases()
        }

        if ip == nil, !firstProbeDone {
            firstProbeDone = true
            if let hostname = config.effectiveGuestHostname {
                logger.info("Waiting for resolution of \(hostname)...")
            } else if let mac = vmController.guestMAC {
                logger.info("Waiting for guest DHCP lease (MAC \(mac))...")
            }
        }

        guard let ip, !ip.isEmpty, ip != guestIP else { return }
        guestIP = ip

        if !guestReachableNotified {
            guestReachableNotified = true
            logger.info("Guest reachable at \(ip) — Home Assistant should be ready shortly")
            logger.info("  Web: http://\(ip):8123")
            logger.info("  SSH: ssh root@\(ip) -p 22222")
        }
    }

    /// Poll the Supervisor's Observer `/ping` endpoint on port 4357.
    /// The Observer is a Supervisor plugin that starts before Home Assistant Core,
    /// so it can provide an earlier readiness signal. This check is fully optional —
    /// it stops as soon as the web UI responds (or we've tried 120 times, ~30s).
    private func checkObserver() {
        guard observerPollCount < observerPollMax else { return }
        observerPollCount += 1
        guard let ip = guestIP else { return }

        guard let url = URL(string: "http://\(ip):4357/ping") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        observerTask?.cancel()
        observerTask = Task { @MainActor in
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
                guard !self.supervisorReachableNotified else { return }
                self.supervisorReachableNotified = true
                self.logger.info("Supervisor is running at \(ip):4357 — Home Assistant is starting up...")
            } catch {
                // Observer not up yet — retry silently on next poll
            }
        }
    }

    /// Poll the Home Assistant web UI health-check endpoint until it responds.
    /// Stops after the first successful response or after `healthPollMax` attempts
    /// (~5 minutes at the 250 ms tick cadence).
    private func checkWebUI() {
        guard healthPollCount < healthPollMax else { return }
        healthPollCount += 1

        guard let baseURL = haBaseURL() else { return }

        guard let url = URL(string: "\(baseURL)/manifest.json") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        webUITask?.cancel()
        webUITask = Task { @MainActor in
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
                guard !self.webUIReadyNotified else { return }
                self.webUIReadyNotified = true
                self.logger.info("Home Assistant is ready at \(baseURL)")
            } catch {
                // UI not up yet — retry silently on next poll
            }
        }
    }

    // MARK: - Disk metrics

    /// Collect disk usage metrics for VM disk images. Called on each
    /// Prometheus scrape via a ``MetricsServer/preScrape`` hook so the
    /// gauge is always fresh without a recurring timer.
    ///
    /// Uses URL resource values to get both the logical size and the actual
    /// allocated size (APFS sparse files typically allocate far less than
    /// their logical size).
    public func collectDiskMetrics() {
        let disks: [(String, String)] = [
            ("main", HavmConfig.persistentDiskPath),
        ]
        for (label, path) in disks {
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey]) else {
                continue
            }
            if let logical = values.fileSize {
                Gauge(label: "havm_disk_usage_bytes", dimensions: [
                    ("disk", label),
                    ("type", "logical"),
                ]).record(Double(logical))
            }
            if let allocated = values.fileAllocatedSize {
                Gauge(label: "havm_disk_usage_bytes", dimensions: [
                    ("disk", label),
                    ("type", "allocated"),
                ]).record(Double(allocated))
            }
        }
    }

    /// If the string looks like an IPv4 or IPv6 address, return it as-is.
    /// Otherwise, resolve it via getaddrinfo (which triggers mDNS for `.local` names).
    private func resolveOrUseIP(_ hostname: String) -> String? {
        // Quick check: if it's already an IP, use it (check both families).
        var v4 = sockaddr_in()
        if inet_pton(AF_INET, hostname, &v4.sin_addr) == 1 {
            return hostname
        }
        var v6 = sockaddr_in6()
        if inet_pton(AF_INET6, hostname, &v6.sin6_addr) == 1 {
            return hostname
        }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        defer { if let r = result { freeaddrinfo(r) } }

        guard getaddrinfo(hostname, nil, &hints, &result) == 0, result != nil else {
            return nil
        }

        var addr = result!.pointee.ai_addr.pointee
        switch Int32(addr.sa_family) {
        case AF_INET:
            return withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &$0.pointee.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                    let bytes = buf.map(UInt8.init(bitPattern:))
                    let end = bytes.firstIndex(of: 0) ?? bytes.count
                    return String(bytes: bytes[0..<end], encoding: .utf8)
                }
            }
        case AF_INET6:
            return withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    inet_ntop(AF_INET6, &$0.pointee.sin6_addr, &buf, socklen_t(INET6_ADDRSTRLEN))
                    let bytes = buf.map(UInt8.init(bitPattern:))
                    let end = bytes.firstIndex(of: 0) ?? bytes.count
                    return String(bytes: bytes[0..<end], encoding: .utf8)
                }
            }
        default:
            return nil
        }
    }

    /// Parse the macOS DHCP lease file to find the guest's IP by its MAC address.
    /// Only works in NAT mode where macOS vmnet acts as the DHCP server.
    /// The MAC address is stable after VM start, so we parse the byte representation
    /// once on first call.
    private lazy var guestMACBytes: [UInt8]? = {
        vmController.guestMAC?.split(separator: ":").compactMap { UInt8($0, radix: 16) }
    }()

    private func discoverViaDHCPLeases() -> String? {
        guard let guestMACBytes else { return nil }

        guard let leaseData = try? Data(contentsOf: URL(fileURLWithPath: "/var/db/dhcpd_leases")),
              let leaseText = String(data: leaseData, encoding: .utf8) else { return nil }

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
                return ip
            }
        }

        return nil
    }

    // MARK: - PID file

    private func writePIDFile() {
        let pidPath = HavmConfig.pidFilePath
        let pidDir = URL(fileURLWithPath: pidPath).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: pidDir, withIntermediateDirectories: true)
        let pidString = "\(getpid())\n"
        try? pidString.write(toFile: pidPath, atomically: true, encoding: .utf8)
    }

    private func removePIDFile() {
        try? FileManager.default.removeItem(atPath: HavmConfig.pidFilePath)
    }

    // MARK: - Terminal raw mode

    /// Enable raw terminal mode so keystrokes pass directly to the guest
    /// without line buffering, local echo, or signal generation (ISIG).
    /// Stores the original termios for restoration on exit.
    private func enableRawMode() {
        guard !rawModeEnabled else { return }
        var raw = termios()
        guard tcgetattr(STDIN_FILENO, &raw) == 0 else {
            logger.warning("Console: tcgetattr failed — terminal may behave unexpectedly")
            return
        }
        originalTermios = raw
        cfmakeraw(&raw)
        // Re-enable NL→CR-NL translation so stderr log lines don't drift
        // across the terminal at whatever column the guest cursor left off.
        // OPOST must be set for ONLCR to take effect.
        raw.c_oflag |= tcflag_t(OPOST | ONLCR)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            logger.warning("Console: tcsetattr failed — terminal may behave unexpectedly")
            return
        }
        rawModeEnabled = true
    }

    /// Restore the original terminal settings saved by ``enableRawMode()``.
    /// Safe to call even if raw mode was never enabled.
    private func restoreTerminal() {
        guard rawModeEnabled, let original = originalTermios else { return }
        var copy = original
        tcsetattr(STDIN_FILENO, TCSANOW, &copy)
        rawModeEnabled = false
    }

}
