import Foundation
import HavmCore
@preconcurrency import Virtualization
import Logging
import AppKit
import AccessoryAccess

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
    private let vmController: VMController
    private var logger: Logger

    private var shutdownRequested = false
    private var guestReachableNotified = false
    private var webUIReadyNotified = false
    private var firstProbeDone = false
    private var guestIP: String?
    private var signalSourceTerm: DispatchSourceSignal?
    private var signalSourceInt: DispatchSourceSignal?
    private var configDirWatcher: DispatchSourceFileSystemObject?
    private var configDirDescriptor: Int32 = -1
    private var configFileWatcher: DispatchSourceFileSystemObject?
    private var healthPollCount = 0
    private let healthPollMax = 300  // 300 × 1s = 5 minutes

    public init(config: HavmConfig, vmController: VMController, logger: Logger = Logger(label: "havm.runtime")) {
        self.config = config
        self.vmController = vmController
        self.logger = logger
        super.init()

        vmController.onStateChange = { [weak self] state in
            let name = Self.stateDescription(state)
            self?.logger.info("VM state: \(name)")
        }
    }

    /// Run the VM, blocking the calling thread until the VM exits or a signal is received.
    public func runBlocking() -> Int32 {
        // Write PID file for external tooling (Homebrew services, monitoring).
        writePIDFile()

        DispatchQueue.main.async {
            self.setupSignalHandlers()

            self.vmController.startVMBlocking { startError in
                if let error = startError {
                    self.logger.error("Failed to start VM: \(error)")
                    exit(1)
                }

                self.logger.info("VM is running. Press Ctrl+C to stop, or send SIGTERM for graceful shutdown.")
                self.setupUSBDiscovery()
                self.printBootingInstructions()

                func poll(tick: Int = 0) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
                        guard !self.shutdownRequested else { return }

                        if self.vmController.state == .stopped {
                            self.logger.info("VM stopped.")
                            self.removePIDFile()
                            fflush(stdout)
                            _exit(0)
                        }

                        // Drain CFRunLoop — VZVirtualMachine uses XPC which
                        // requires the run loop for Mach port event delivery.
                        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))

                        let newTick = tick + 1
                        if newTick % 4 == 0 {
                            if !self.guestReachableNotified {
                                self.checkGuestNetwork()
                            } else if !self.webUIReadyNotified {
                                self.checkWebUI()
                            }
                        }
                        poll(tick: newTick)
                    }
                }
                poll()
            }
        }

        // Block calling thread. The semaphore is never signaled — all exit
        // paths use _exit() from the main queue poll loop (VM stopped, signal
        // received, or start failure via exit()).
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

    /// Register DispatchSource signal monitors. Signals are delivered as GCD
    /// events on the main queue via kqueue, avoiding the async-signal-safety
    /// constraints of raw `signal()` handlers. A second signal during shutdown
    /// triggers immediate exit.
    private func setupSignalHandlers() {
        // Block default signal behavior — DispatchSource monitors via kqueue.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signalSourceTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signalSourceTerm?.setEventHandler { [weak self] in
            self?.signalShutdown(name: "SIGTERM")
        }
        signalSourceTerm?.resume()

        signalSourceInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSourceInt?.setEventHandler { [weak self] in
            self?.signalShutdown(name: "SIGINT")
        }
        signalSourceInt?.resume()

        startConfigWatcher()
    }

    private func setupUSBDiscovery() {
        guard config.effectiveUSBEnabled else {
            logger.debug("USB: Not enabled in config — skipping accessory discovery")
            return
        }
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
    }

    public func usbAccessoryDidDisconnect(_ accessory: AAUSBAccessory) {
        let (vid, pid) = accessory.vendorProductID
        logger.info("USB: Accessory disconnected — 0x\(String(vid, radix: 16, uppercase: true)):0x\(String(pid, radix: 16, uppercase: true)) (registryID=\(accessory.registryID))")
    }

    // MARK: - Config hot-reload

    private func startConfigWatcher() {
        guard let path = config.configPath else { return }
        let dir = (path as NSString).deletingLastPathComponent

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
        guard let path = config.configPath else { return }
        guard let newConfig = try? loadConfig(path: path) else {
            logger.debug("Config reload: failed to parse — keeping current config")
            return
        }
        let oldConfig = config
        config = newConfig

        let levelChanged = newConfig.effectiveLogLevel != oldConfig.effectiveLogLevel
        let tokenChanged = newConfig.effectiveHAAPIToken != oldConfig.effectiveHAAPIToken
        guard levelChanged || tokenChanged else { return }

        if levelChanged {
            logger.logLevel = newConfig.effectiveLogLevel
        }
        logger.info("Config reloaded")
    }

    private func signalShutdown(name: String) {
        guard !shutdownRequested else {
            // Second signal — force immediate exit
            logger.warning("\(name) received again — exiting immediately")
            removePIDFile()
            _exit(1)
        }
        shutdownRequested = true
        logger.info("\(name) received — initiating graceful shutdown...")
        Task { await performGracefulShutdown() }
    }

    private func performGracefulShutdown() async {
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
            // 3. SSH add-on on port 22 (container, uses ha host shutdown)
            logger.info("Attempting SSH shutdown via port 22...")
            if await sshShutdown(host: ip, port: 22, command: "ha host shutdown", timeout: timeout),
               await waitForStop(timeout: timeout) {
                return
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
        removePIDFile()
        fflush(stdout)
        _exit(0)
    }

    /// Wait for the VM to reach `.stopped` state.
    /// - Returns: `true` if the VM stopped, `false` if timed out.
    private func waitForStop(timeout: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            if vmController.state == .stopped {
                logger.info("VM stopped gracefully.")
                removePIDFile()
                fflush(stdout)
                _exit(0)
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
            return "http://\(ip):8123"
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

    /// Poll the Home Assistant web UI health-check endpoint until it responds.
    /// Stops after the first successful response or after `healthPollMax` attempts
    /// (~5 minutes at the 5-second poll cadence).
    private func checkWebUI() {
        guard healthPollCount < healthPollMax else { return }
        healthPollCount += 1

        guard let baseURL = haBaseURL() else { return }

        guard let url = URL(string: "\(baseURL)/manifest.json") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        Task { @MainActor in
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

    /// If the string looks like an IPv4 address, return it as-is.
    /// Otherwise, resolve it via getaddrinfo (which triggers mDNS for `.local` names).
    private func resolveOrUseIP(_ hostname: String) -> String? {
        // Quick check: if it's already an IP, use it
        var sin = sockaddr_in()
        if inet_pton(AF_INET, hostname, &sin.sin_addr) == 1 {
            return hostname
        }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        var result: UnsafeMutablePointer<addrinfo>?
        defer { if let r = result { freeaddrinfo(r) } }

        guard getaddrinfo(hostname, nil, &hints, &result) == 0, result != nil else {
            return nil
        }

        return result!.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr in
            var buf = [CChar](repeating: 0, count: 16)
            inet_ntop(AF_INET, &addr.pointee.sin_addr, &buf, socklen_t(16))
            let nullTerm = buf.firstIndex(of: 0) ?? buf.count
            let utf8Bytes = buf[0..<nullTerm].map { UInt8(bitPattern: $0) }
            return String(bytes: utf8Bytes, encoding: .utf8) ?? ""
        }
    }

    /// Parse the macOS DHCP lease file to find the guest's IP by its MAC address.
    /// Only works in NAT mode where macOS vmnet acts as the DHCP server.
    private func discoverViaDHCPLeases() -> String? {
        guard let mac = vmController.guestMAC else { return nil }

        guard let leaseData = try? Data(contentsOf: URL(fileURLWithPath: "/var/db/dhcpd_leases")),
              let leaseText = String(data: leaseData, encoding: .utf8) else { return nil }

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
                return ip
            }
        }

        return nil
    }

    // MARK: - PID file

    private func writePIDFile() {
        let pidPath = HavmConfig.pidFilePath
        let pidDir = (pidPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: pidDir, withIntermediateDirectories: true)
        let pidString = "\(getpid())\n"
        try? pidString.write(toFile: pidPath, atomically: true, encoding: .utf8)
    }

    private func removePIDFile() {
        try? FileManager.default.removeItem(atPath: HavmConfig.pidFilePath)
    }

    /// Human-readable VM state description.
    private static func stateDescription(_ state: VZVirtualMachine.State) -> String {
        switch state {
        case .stopped:   "stopped"
        case .running:   "running"
        case .paused:    "paused"
        case .starting:  "starting"
        case .saving:    "saving"
        case .restoring: "restoring"
        default:         "unknown (\(state.rawValue))"
        }
    }
}
