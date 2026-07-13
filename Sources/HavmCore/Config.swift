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
    /// Path to the loaded config file, for file watching / hot-reload.
    public var configPath: String?

    public struct VMOverrides: Decodable, Sendable {
        public var cpuCount: Int?
        public var memorySize: MemorySize?
        public var diskSize: MemorySize?

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
            public var port: Int?
            public var host: String?

            public init(port: Int? = nil, host: String? = nil) {
                self.port = port
                self.host = host
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
        case .error: .critical
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

    /// Default shutdown timeout: 30 seconds.
    /// SSH-based shutdown sends `shutdown -h now` or `ha host shutdown` to the
    /// guest, then waits this long for systemd to stop services and halt.
    public var effectiveShutdownTimeout: Int {
        shutdown?.timeoutSeconds ?? 30
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

    /// Prometheus metrics endpoint host (defaults to 127.0.0.1).
    public var effectivePrometheusHost: String {
        metrics?.prometheus?.host ?? "127.0.0.1"
    }
}

// MARK: - MemorySize (human-readable bytes)

public struct MemorySize: Sendable, CustomStringConvertible {
    public let bytes: UInt64

    public init(bytes: UInt64) { self.bytes = bytes }

    public var description: String {
        if bytes >= 1024 * 1024 * 1024, bytes % (1024 * 1024 * 1024) == 0 {
            return "\(bytes / (1024 * 1024 * 1024)) GiB"
        }
        if bytes >= 1024 * 1024, bytes % (1024 * 1024) == 0 {
            return "\(bytes / (1024 * 1024)) MiB"
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
        guard bytes <= Double(UInt64.max), bytes >= 0 else {
            throw ConfigError.invalidMemorySize(string)
        }
        return UInt64(bytes)
    }
}

// MARK: - Config loading

public enum ConfigError: Error, CustomStringConvertible {
    case invalidMemorySize(String)

    public var description: String {
        switch self {
        case .invalidMemorySize(let s): return "Invalid memory size: \(s)"
        }
    }
}

/// Load the config file at the given path (or return defaults if path doesn't exist).
public func loadConfig(path: String? = nil) throws -> HavmConfig {
    let configPath: String
    if let path = path {
        configPath = URL(fileURLWithPath: path).standardizedFileURL.path
    } else {
        configPath = HavmConfig.defaultConfigPath
    }

    guard FileManager.default.fileExists(atPath: configPath) else {
        // Missing config is fine — use defaults.
        return HavmConfig.defaults
    }

    let yaml = try String(contentsOfFile: configPath, encoding: .utf8)
    // Empty, whitespace-only, or comment-only files are fine — use defaults.
    let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return HavmConfig.defaults
    }

    let decoder = YAMLDecoder()
    var config = try decoder.decode(HavmConfig.self, from: yaml)
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
    /// Uses the `data_directory` config value if set, otherwise defaults to
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
