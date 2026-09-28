import Foundation
import Logging
import Yams

// MARK: - Minimal optional configuration

/// All fields optional — `havm run` works with zero config.
public struct HavmConfig: Decodable, Sendable {
    public var vm: VMOverrides?
    public var network: NetworkOverrides?
    public var haos: HAOSOverrides?
    public var usb: USBConfig?
    public var ssh: SSHOverrides?
    public var ha: HAConfig?
    public var shutdown: ShutdownOverrides?
    public var logging: LoggingOverrides?
    public var metrics: MetricsConfig?
    /// Path to the effective config file (where havm looks), for file
    /// watching / hot-reload. `loadConfig` always sets this — even when the
    /// file doesn't exist yet (defaults are used in that case).
    public var configPath: String?

    public struct VMOverrides: Decodable, Sendable {
        public var cpuCount: Int?
        public var memorySize: MemorySize?
        public var diskSize: MemorySize?

        // Yams matches keys exactly (no snake_case strategy), so the documented
        // snake_case keys need explicit CodingKeys. camelCase keys are not
        // supported (breaking change allowed before 1.0).
        private enum CodingKeys: String, CodingKey {
            case cpuCount = "cpu_count"
            case memorySize = "memory_size"
            case diskSize = "disk_size"
        }

        public init(cpuCount: Int? = nil, memorySize: MemorySize? = nil, diskSize: MemorySize? = nil) {
            self.cpuCount = cpuCount
            self.memorySize = memorySize
            self.diskSize = diskSize
        }
    }

    public struct NetworkOverrides: Decodable, Sendable {
        public var type: NetworkType?
        public var interface: String?
        /// Optional MAC address for the guest network interface.
        /// Must be a locally-administered unicast address (e.g., `02:00:00:00:00:01`).
        /// If not set, a random MAC is generated and persisted on first boot.
        public var mac: String?
        /// Hostname or static IP for reaching the guest.
        /// In bridge mode, defaults to `homeassistant.local` (mDNS).
        /// Set this if you run multiple HA instances or use a static IP.
        public var hostname: String?

        public init(type: NetworkType? = nil, interface: String? = nil, mac: String? = nil, hostname: String? = nil) {
            self.type = type
            self.interface = interface
            self.mac = mac
            self.hostname = hostname
        }
    }

    public enum NetworkType: String, Decodable, Sendable {
        case bridge
        case nat
    }

    public struct HAOSOverrides: Decodable, Sendable {
        public var releaseChannel: ReleaseChannel?

        public enum ReleaseChannel: String, Decodable, Sendable {
            case stable
            case preRelease = "pre-release"
        }

        // Documented key is `release_channel`; camelCase is not supported
        // (breaking change allowed before 1.0).
        private enum CodingKeys: String, CodingKey {
            case releaseChannel = "release_channel"
        }

        public init(releaseChannel: ReleaseChannel? = nil) {
            self.releaseChannel = releaseChannel
        }
    }

    /// USB passthrough is managed via the macOS menu bar item, not via config.
    /// The `enabled` flag controls whether USB passthrough is active.
    public struct USBConfig: Decodable, Sendable {
        public var enabled: Bool?

        public init(enabled: Bool? = nil) {
            self.enabled = enabled
        }
    }

    public struct SSHOverrides: Decodable, Sendable {
        /// Path to an SSH authorized_keys file (e.g. ~/.ssh/id_ed25519.pub).
        /// If set, a virtual CONFIG disk with the key is created and attached
        /// to the VM. HA OS auto-imports the key on boot for root SSH access
        /// on port 22222.
        public var authorizedKeys: String?

        enum CodingKeys: String, CodingKey {
            case authorizedKeys = "authorized_keys"
        }

        public init(authorizedKeys: String? = nil) {
            self.authorizedKeys = authorizedKeys
        }
    }

    /// Home Assistant connection settings. Used for both shutdown and
    /// pre-UI-ready checks (e.g. manifest.json polling).
    public struct HAConfig: Decodable, Sendable {
        /// Base URL of the Home Assistant instance.
        /// Overrides the default `http://<discovered-ip>:8123`.
        /// Use this if HA runs on a different port or uses HTTPS,
        /// e.g. `https://homeassistant.local:443`.
        public var url: String?
        /// Long-lived access token for REST API calls (shutdown, etc.).
        /// Create one at http://<ip>:8123/profile/security.
        public var apiToken: String?

        enum CodingKeys: String, CodingKey {
            case url
            case apiToken = "api_token"
        }

        public init(url: String? = nil, apiToken: String? = nil) {
            self.url = url
            self.apiToken = apiToken
        }
    }

    public struct ShutdownOverrides: Decodable, Sendable {
        public var timeoutSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case timeoutSeconds = "timeout_seconds"
        }

        public init(timeoutSeconds: Int? = nil) {
            self.timeoutSeconds = timeoutSeconds
        }
    }

    public struct LoggingOverrides: Decodable, Sendable {
        public var level: LogLevel?
        public var format: LogFormat?

        public enum LogLevel: String, Decodable, Sendable {
            case debug, info, warning, error
        }

        public enum LogFormat: String, Decodable, Sendable {
            case text, json
        }

        public init(level: LogLevel? = nil, format: LogFormat? = nil) {
            self.level = level
            self.format = format
        }
    }

    public struct MetricsConfig: Decodable, Sendable {
        public var enabled: Bool?
        public var type: MetricsType?
        public var prometheus: PrometheusConfig?

        public enum MetricsType: String, Decodable, Sendable {
            case prometheus
        }

        public struct PrometheusConfig: Decodable, Sendable {
            /// Marks a `host` entry as a Unix domain socket path instead of a
            /// TCP bind address, e.g. `unix:///opt/homebrew/var/run/havm.sock`.
            public static let unixSocketPrefix = "unix://"

            public var port: Int?
            /// Bind addresses for the HTTP listener. Accepts a single string
            /// or an array in YAML. Defaults to both loopback addresses.
            /// Entries prefixed with `unix://` are Unix domain socket paths.
            public var hosts: [String]?

            enum CodingKeys: String, CodingKey {
                case port, host
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                port = try container.decodeIfPresent(Int.self, forKey: .port)
                // Accept both a single string and an array for backward compat.
                if let single = try? container.decodeIfPresent(String.self, forKey: .host) {
                    hosts = [single]
                } else {
                    hosts = try container.decodeIfPresent([String].self, forKey: .host)
                }
            }

            public init(port: Int? = nil, hosts: [String]? = nil) {
                self.port = port
                self.hosts = hosts
            }

            /// The Unix domain socket path in a `host` entry, or nil when the
            /// entry is a TCP bind address.
            public static func socketPath(in entry: String) -> String? {
                let trimmed = entry.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(unixSocketPrefix) else { return nil }
                return String(trimmed.dropFirst(unixSocketPrefix.count))
            }

            /// Split `host` entries into TCP bind addresses and socket paths.
            public static func split(
                _ entries: [String]
            ) -> (hosts: [String], sockets: [String]) {
                var hosts: [String] = []
                var sockets: [String] = []
                for entry in entries {
                    if let path = socketPath(in: entry) {
                        sockets.append(path)
                    } else {
                        let host = entry.trimmingCharacters(in: .whitespaces)
                        if !host.isEmpty { hosts.append(host) }
                    }
                }
                return (hosts, sockets)
            }

            /// Validate `port` and the `host` entries. Throws for a value that
            /// could never be bound as written, so a typo fails at config load
            /// instead of silently dropping a listener.
            public func validate() throws {
                if let port, !Self.portRange.contains(port) {
                    throw ConfigError.invalidMetricsPort(port)
                }
                for entry in hosts ?? [] {
                    let trimmed = entry.trimmingCharacters(in: .whitespaces)
                    if let path = Self.socketPath(in: entry) {
                        guard !path.isEmpty else {
                            throw ConfigError.invalidMetricsHost(
                                entry, reason: "no socket path after \(Self.unixSocketPrefix)")
                        }
                        guard path.hasPrefix("/") else {
                            throw ConfigError.invalidMetricsHost(
                                entry, reason: "socket path must be absolute")
                        }
                    } else if trimmed.isEmpty {
                        throw ConfigError.invalidMetricsHost(entry, reason: "empty host")
                    } else if trimmed.hasPrefix("unix:") {
                        throw ConfigError.invalidMetricsHost(
                            entry, reason: "socket paths are written \(Self.unixSocketPrefix)/absolute/path")
                    } else if trimmed.hasPrefix("[") {
                        // Brackets are the URL spelling, where they separate an
                        // IPv6 literal from a port this key does not accept.
                        throw ConfigError.invalidMetricsHost(
                            entry, reason: "write an IPv6 address without brackets, like \"::1\"")
                    } else if let port = Self.portSuffix(of: trimmed) {
                        throw ConfigError.invalidMetricsHost(
                            entry, reason: "\"\(port)\" is a port — the port comes from "
                                + "metrics.prometheus.port, and host takes a bind address only")
                    }
                }
            }

            /// The ports a listener can be asked for. 0 asks the kernel to pick
            /// one, which is never what a metrics endpoint is after.
            private static let portRange = 1...65535

            /// The trailing port of a `host:port` entry, or nil when the entry
            /// is a bare address.
            ///
            /// A bare IPv6 literal ends in a group, not a decimal port, so
            /// `::1` and `fe80::1%en0` are addresses while `localhost:9210`
            /// and `127.0.0.1:9210` are pairs. Names are left alone here: one
            /// that cannot be bound is caught by the bind check in
            /// ``MetricsServer/start()``, which reports what actually bound
            /// rather than predicting what can.
            private static func portSuffix(of entry: String) -> String? {
                guard let colon = entry.lastIndex(of: ":") else { return nil }
                let tail = entry[entry.index(after: colon)...]
                guard !tail.isEmpty, tail.allSatisfy(\.isNumber) else { return nil }
                guard !isIPv6Address(entry) else { return nil }
                return String(tail)
            }

            /// Whether the entry is a bare numeric IPv6 address.
            private static func isIPv6Address(_ entry: String) -> Bool {
                var address = in6_addr()
                return entry.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
            }
        }

        public init(enabled: Bool? = nil, type: MetricsType? = nil, prometheus: PrometheusConfig? = nil) {
            self.enabled = enabled
            self.type = type
            self.prometheus = prometheus
        }
    }

    /// Effective log format: defaults to `.text`.
    public var effectiveLogFormat: LoggingOverrides.LogFormat {
        logging?.format ?? .text
    }

    /// Effective log level: defaults to `.info`.
    public var effectiveLogLevel: Logger.Level {
        switch logging?.level {
        case .debug: .debug
        case .warning: .warning
        case .error: .error
        case .info, nil: .info
        }
    }

    // MARK: - Defaults

    /// Sensible defaults for Home Assistant OS.
    public static let defaults = HavmConfig()

    /// Default CPU count: 4 (safe default for Apple Virtualization).
    /// HA OS works well with 2-4 cores. Very high core counts can cause
    /// VZVirtualMachine to reject the configuration.
    public var effectiveCPUCount: Int {
        if let count = vm?.cpuCount { return count }
        return 4
    }

    /// Default memory: 4 GiB.
    public var effectiveMemorySize: UInt64 {
        vm?.memorySize?.bytes ?? (4 * 1024 * 1024 * 1024)
    }

    /// Default disk size: 32 GiB.
    public var effectiveDiskSize: UInt64 {
        vm?.diskSize?.bytes ?? (32 * 1024 * 1024 * 1024)
    }

    /// Default network: bridge (LAN-reachable IP for Home Assistant discovery).
    /// Falls back to NAT at runtime if the binary lacks the
    /// ``com.apple.vm.networking`` entitlement (e.g. self-compiled without tier 3).
    public var effectiveNetworkType: NetworkType {
        network?.type ?? .bridge
    }

    /// Default release channel: stable.
    public var effectiveReleaseChannel: HAOSOverrides.ReleaseChannel {
        haos?.releaseChannel ?? .stable
    }

    /// Default shutdown timeout: 90 seconds — the budget for the *entire*
    /// graceful phase, not per shutdown method. Covers reaching the guest
    /// (REST request, SSH connect) plus waiting for systemd to stop services
    /// and halt. 90 s matches systemd's `DefaultTimeoutStopSec`, so a single
    /// slow-stopping unit can't push the guest past the budget.
    ///
    /// Home Assistant OS can take ~55 s to halt on a modest install with a few
    /// add-ons; under-shooting this budget means havm hard-powers-off the VM
    /// (`forceStop`) while the guest is still shutting down cleanly.
    ///
    /// Keep the budget comfortably below the 120 s `ExitTimeOut` the Homebrew
    /// formula sets (`stop_timeout 120`): launchd `SIGKILL`s the process once
    /// that elapses, so a larger budget would skip the force-stop entirely.
    public var effectiveShutdownTimeout: Int {
        shutdown?.timeoutSeconds ?? 90
    }

    /// Home Assistant long-lived access token for REST API use.
    /// Set via `ha.api_token`. Used for API calls like shutdown.
    /// Returns nil for empty or whitespace-only strings so the
    /// shutdown chain skips the REST API step when no token is set.
    public var effectiveHAAPIToken: String? {
        guard let token = ha?.apiToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    /// Base URL for the Home Assistant web UI and REST API.
    /// Set via `ha.url`. If not set, defaults to `http://<discovered-ip>:8123`.
    public var effectiveHAURL: String? {
        ha?.url
    }

    // MARK: - Init

    public init(
        vm: VMOverrides? = nil,
        network: NetworkOverrides? = nil,
        haos: HAOSOverrides? = nil,
        usb: USBConfig? = nil,
        ssh: SSHOverrides? = nil,
        ha: HAConfig? = nil,
        shutdown: ShutdownOverrides? = nil,
        logging: LoggingOverrides? = nil,
        metrics: MetricsConfig? = nil,
        configPath: String? = nil
    ) {
        self.vm = vm
        self.network = network
        self.haos = haos
        self.usb = usb
        self.ssh = ssh
        self.ha = ha
        self.shutdown = shutdown
        self.logging = logging
        self.metrics = metrics
        self.configPath = configPath
    }

    /// USB passthrough enabled (defaults to true).
    public var effectiveUSBEnabled: Bool {
        usb?.enabled ?? true
    }

    /// SSH authorized keys path, if configured.
    public var effectiveSSHKeyPath: String? {
        ssh?.authorizedKeys
    }

    /// Hostname or IP for reaching the guest. In bridge mode, defaults to
    /// `homeassistant.local`. Override via `network.hostname` if you run
    /// multiple HA instances or use a static IP.
    public var effectiveGuestHostname: String? {
        if let hostname = network?.hostname { return hostname }
        switch effectiveNetworkType {
        case .bridge: return "homeassistant.local"
        case .nat: return nil  // DHCP lease parsing works, no hostname needed
        }
    }

    /// Metrics enabled (defaults to false).
    public var effectiveMetricsEnabled: Bool {
        metrics?.enabled ?? false
    }

    /// Metrics backend type (defaults to prometheus).
    public var effectiveMetricsType: MetricsConfig.MetricsType {
        metrics?.type ?? .prometheus
    }

    /// Prometheus metrics endpoint port (defaults to 9210).
    public var effectivePrometheusPort: Int {
        metrics?.prometheus?.port ?? 9210
    }

    /// Prometheus metrics bind addresses. Defaults to both IPv4 and IPv6
    /// loopback so the endpoint is reachable regardless of client stack.
    ///
    /// The default applies only when `host` is absent: a list holding nothing
    /// but `unix://` entries means socket-only, and must not silently regain
    /// TCP listeners.
    public var effectivePrometheusHosts: [String] {
        guard let entries = metrics?.prometheus?.hosts else { return ["127.0.0.1", "::1"] }
        return MetricsConfig.PrometheusConfig.split(entries).hosts
    }

    /// Prometheus metrics Unix domain socket paths, from `unix://<path>`
    /// entries in `metrics.prometheus.host`. Empty by default.
    public var effectivePrometheusSocketPaths: [String] {
        guard let entries = metrics?.prometheus?.hosts else { return [] }
        return MetricsConfig.PrometheusConfig.split(entries).sockets
    }
}

// MARK: - MemorySize (human-readable bytes)

public struct MemorySize: Sendable, CustomStringConvertible {
    public let bytes: UInt64

    public init(bytes: UInt64) { self.bytes = bytes }

    public var description: String {
        if bytes >= 1024 * 1024 * 1024 {
            let gb = Double(bytes) / (1024 * 1024 * 1024)
            let formatted = String(format: "%.1f GiB", gb)
            return formatted.hasSuffix(".0 GiB") ? "\(Int(gb)) GiB" : formatted
        }
        if bytes >= 1024 * 1024 {
            let mb = Double(bytes) / (1024 * 1024)
            let formatted = String(format: "%.1f MiB", mb)
            return formatted.hasSuffix(".0 MiB") ? "\(Int(mb)) MiB" : formatted
        }
        return "\(bytes) B"
    }
}

extension MemorySize: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        self.bytes = try MemorySize.parse(string)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public static func parse(_ string: String) throws -> UInt64 {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let bytes = UInt64(trimmed) { return bytes }

        // Scan value + suffix
        let pattern = #/^(?<value>[0-9.]+)\s*(?<suffix>[A-Za-z]+)?$/#
        guard let match = trimmed.wholeMatch(of: pattern),
              let value = Double(match.output.value) else {
            throw ConfigError.invalidMemorySize(string)
        }

        let suffix = match.output.suffix?.lowercased() ?? "b"
        let multiplier: Double
        switch suffix {
        case "gib": multiplier = 1_073_741_824
        case "gb":  multiplier = 1_000_000_000
        case "mib": multiplier = 1_048_576
        case "mb":  multiplier = 1_000_000
        case "kib": multiplier = 1_024
        case "kb":  multiplier = 1_000
        case "b":   multiplier = 1
        default: throw ConfigError.invalidMemorySize(string)
        }
        let bytes = value * multiplier
        guard bytes >= 0, bytes < Double(UInt64.max) else {
            throw ConfigError.invalidMemorySize(string)
        }
        return UInt64(bytes)
    }
}

// MARK: - Config loading

public enum ConfigError: Error, CustomStringConvertible {
    case invalidMemorySize(String)
    case invalidMetricsHost(String, reason: String)
    case invalidMetricsPort(Int)

    public var description: String {
        switch self {
        case .invalidMemorySize(let s): return "Invalid memory size: \(s)"
        case .invalidMetricsHost(let entry, let reason):
            return "Invalid metrics.prometheus.host entry \"\(entry)\": \(reason)"
        case .invalidMetricsPort(let port):
            return "Invalid metrics.prometheus.port value \(port): must be between 1 and 65535"
        }
    }
}

/// Load the config file at the given path (or return defaults if the path
/// doesn't exist). The returned config always has `configPath` set to the
/// resolved path that was checked.
public func loadConfig(path: String? = nil) throws -> HavmConfig {
    let configPath: String
    if let path = path {
        configPath = URL(fileURLWithPath: path).standardizedFileURL.path
    } else {
        configPath = HavmConfig.defaultConfigPath
    }

    guard FileManager.default.fileExists(atPath: configPath) else {
        // Missing config is fine — use defaults, but still report the path
        // havm looks at so it can tell the user where to put overrides.
        var config = HavmConfig.defaults
        config.configPath = configPath
        return config
    }

    let yaml = try String(contentsOfFile: configPath, encoding: .utf8)
    // Empty, whitespace-only, or comment-only files are fine — use defaults.
    let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        var config = HavmConfig.defaults
        config.configPath = configPath
        return config
    }

    let decoder = YAMLDecoder()
    var config = try decoder.decode(HavmConfig.self, from: yaml)
    try config.metrics?.prometheus?.validate()
    config.configPath = configPath
    return config
}

extension HavmConfig {
    /// Default config location: ~/.config/havm/config.yml
    public static var defaultConfigPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/havm/config.yml")
            .path
    }

    /// Override for data directory, set during config loading.
    public static nonisolated(unsafe) var dataDirectoryOverride: String?

    private static let _defaultDataDirectory: String = {
        let appSupport = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support").path
        return URL(fileURLWithPath: appSupport)
            .appendingPathComponent("havm")
            .path
    }()

    /// Base directory for havm persistent data.
    ///
    /// Uses the `--data-dir` CLI flag if set, otherwise defaults to
    /// `~/Library/Application Support/havm/`.
    public static var dataDirectory: String {
        dataDirectoryOverride ?? _defaultDataDirectory
    }

    /// Directory for cached HA OS images: ~/Library/Caches/havm/
    public static let cacheDirectory: String = {
        let caches = NSSearchPathForDirectoriesInDomains(
            .cachesDirectory, .userDomainMask, true
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches").path
        return URL(fileURLWithPath: caches)
            .appendingPathComponent("havm")
            .path
    }()

    /// Directory for persistent VM data.
    public static var vmDirectory: String {
        URL(fileURLWithPath: dataDirectory)
            .appendingPathComponent("vm")
            .path
    }

    /// Path to the persistent disk image.
    public static var persistentDiskPath: String {
        URL(fileURLWithPath: vmDirectory)
            .appendingPathComponent("haos.img")
            .path
    }

    /// Path to the persisted machine identifier.
    public static var machineIdentifierPath: String {
        URL(fileURLWithPath: vmDirectory)
            .appendingPathComponent("MachineIdentifier")
            .path
    }

    /// Path to the persisted MAC address (randomly generated on first boot).
    public static var macAddressPath: String {
        URL(fileURLWithPath: vmDirectory)
            .appendingPathComponent("MACAddress")
            .path
    }

    /// Path to the EFI NVRAM variable store.
    public static var nvramPath: String {
        URL(fileURLWithPath: vmDirectory)
            .appendingPathComponent("NVRAM")
            .path
    }

    /// Path to the SSH key import disk (FAT16 with volume label CONFIG).
    public static var configDiskPath: String {
        URL(fileURLWithPath: vmDirectory)
            .appendingPathComponent("config.img")
            .path
    }

    /// Path to the PID file for the running VM process.
    public static var pidFilePath: String {
        URL(fileURLWithPath: vmDirectory)
            .appendingPathComponent("havm.pid")
            .path
    }
}
