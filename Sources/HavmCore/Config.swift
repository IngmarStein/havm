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
    public var shutdown: ShutdownOverrides?
    public var logging: LoggingOverrides?

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

        public init(type: NetworkType? = nil, interface: String? = nil) {
            self.type = type
            self.interface = interface
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

    /// USB passthrough is managed through the havm-helper UI, not via config.
    /// The `enabled` flag controls whether persisted accessories are attached.
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

    public struct ShutdownOverrides: Decodable, Sendable {
        public var timeoutSeconds: Int?

        public init(timeoutSeconds: Int? = nil) {
            self.timeoutSeconds = timeoutSeconds
        }
    }

    public struct LoggingOverrides: Decodable, Sendable {
        public var level: LogLevel?
        public var format: LogFormat?
        public var file: String?

        public enum LogLevel: String, Decodable, Sendable {
            case debug, info, warning, error
        }

        public enum LogFormat: String, Decodable, Sendable {
            case text, json
        }

        public init(level: LogLevel? = nil, format: LogFormat? = nil, file: String? = nil) {
            self.level = level
            self.format = format
            self.file = file
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

    /// Default network: NAT (works without extra entitlements).
    /// Bridge available via config for LAN-reachable IP.
    public var effectiveNetworkType: NetworkType {
        network?.type ?? .nat
    }

    /// Default release channel: stable.
    public var effectiveReleaseChannel: HAOSOverrides.ReleaseChannel {
        haos?.releaseChannel ?? .stable
    }

    /// Default shutdown timeout: 5 seconds.
    /// HA OS on aarch64 uses PSCI, not ACPI power button, so `requestStop()`
    /// is silently ignored. A short timeout keeps Ctrl+C responsive.
    public var effectiveShutdownTimeout: Int {
        shutdown?.timeoutSeconds ?? 5
    }

    // MARK: - Init

    public init(
        vm: VMOverrides? = nil,
        network: NetworkOverrides? = nil,
        haos: HAOSOverrides? = nil,
        usb: USBConfig? = nil,
        ssh: SSHOverrides? = nil,
        shutdown: ShutdownOverrides? = nil,
        logging: LoggingOverrides? = nil
    ) {
        self.vm = vm
        self.network = network
        self.haos = haos
        self.usb = usb
        self.ssh = ssh
        self.shutdown = shutdown
        self.logging = logging
    }

    /// USB passthrough enabled (defaults to true).
    public var effectiveUSBEnabled: Bool {
        usb?.enabled ?? true
    }

    /// SSH authorized keys path, if configured.
    public var effectiveSSHKeyPath: String? {
        ssh?.authorizedKeys
    }
}

// MARK: - MemorySize (human-readable bytes)

public struct MemorySize: Sendable, CustomStringConvertible {
    public let bytes: UInt64

    public init(bytes: UInt64) { self.bytes = bytes }

    public var description: String {
        let gib = Double(bytes) / (1024 * 1024 * 1024)
        if gib >= 1, gib.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(gib)) GiB"
        }
        let mib = Double(bytes) / (1024 * 1024)
        if mib >= 1, mib.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(mib)) MiB"
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
    case fileNotFound(String)
    case parseError(String)
    case invalidMemorySize(String)

    public var description: String {
        switch self {
        case .fileNotFound(let path): return "Config not found: \(path)"
        case .parseError(let msg): return "Config parse error: \(msg)"
        case .invalidMemorySize(let s): return "Invalid memory size: \(s)"
        }
    }
}

/// Load the config file at the given path (or return defaults if path doesn't exist).
public func loadConfig(path: String? = nil) throws -> HavmConfig {
    let configPath: String
    if let path = path {
        configPath = (path as NSString).standardizingPath
    } else {
        configPath = HavmConfig.defaultConfigPath
    }

    guard FileManager.default.fileExists(atPath: configPath) else {
        if path != nil {
            throw ConfigError.fileNotFound(configPath)
        }
        // No user config at default path — use defaults, that's fine
        return HavmConfig.defaults
    }

    let yaml = try String(contentsOfFile: configPath, encoding: .utf8)
    guard (try? Yams.compose(yaml: yaml)) != nil else {
        throw ConfigError.parseError("Invalid YAML in \(configPath)")
    }

    let decoder = YAMLDecoder()
    let config = try decoder.decode(HavmConfig.self, from: yaml)
    return config
}

extension HavmConfig {
    /// Default config location: ~/.config/havm/config.yml
    public static var defaultConfigPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/havm/config.yml")
    }

    /// Base directory for havm persistent data: ~/Library/Application Support/havm/
    public static var dataDirectory: String {
        let appSupport = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support").path
        return (appSupport as NSString).appendingPathComponent("havm")
    }

    /// Directory for cached HA OS images: ~/Library/Caches/havm/
    public static var cacheDirectory: String {
        let caches = NSSearchPathForDirectoriesInDomains(
            .cachesDirectory, .userDomainMask, true
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches").path
        return (caches as NSString).appendingPathComponent("havm")
    }

    /// Directory for persistent VM data.
    public static var vmDirectory: String {
        (dataDirectory as NSString).appendingPathComponent("vm")
    }

    /// Path to the persistent disk image.
    public static var persistentDiskPath: String {
        (vmDirectory as NSString).appendingPathComponent("haos.img")
    }

    /// Path to the persisted machine identifier (stable MAC addresses across reboots).
    public static var machineIdentifierPath: String {
        (vmDirectory as NSString).appendingPathComponent("MachineIdentifier")
    }

    /// Path to the EFI NVRAM variable store.
    public static var nvramPath: String {
        (vmDirectory as NSString).appendingPathComponent("NVRAM")
    }

    /// Path to the SSH key import disk (FAT16 with volume label CONFIG).
    public static var configDiskPath: String {
        (vmDirectory as NSString).appendingPathComponent("config.img")
    }

    /// Directory for persisted USB accessory data (from havm-helper).
    public static var usbPersistenceDirectory: String {
        (dataDirectory as NSString).appendingPathComponent("usb")
    }
}
