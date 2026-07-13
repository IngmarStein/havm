import Foundation

// MARK: - UTM Bundle model

/// Parsed representation of a UTM `.utm` bundle's `config.plist`.
/// Only supports Apple Virtualization backend with aarch64 UEFI boot.
public struct UTMBundle: Sendable {
    public let name: String
    public let bundleURL: URL
    public let cpuCount: Int
    public let memorySizeMB: Int
    public let drives: [Drive]
    public let networks: [Network]
    public let efiVariableStoragePath: String?
    public let machineIdentifierData: Data?

    public struct Drive: Sendable {
        public let identifier: String
        public let imageName: String
        public let isNVMe: Bool
        public let isReadOnly: Bool
    }

    public struct Network: Sendable {
        public let mode: String        // "Bridged" or "Shared"
        public let macAddress: String?
        public let bridgeInterface: String?
    }

    // MARK: - Parsing

    /// Parse a UTM bundle at the given path.
    /// - Parameter path: Path to the `.utm` bundle directory.
    /// - Throws: `UTMImportError` if the bundle is invalid or unsupported.
    public init(path: String) throws(UTMImportError) {
        let bundleURL = URL(fileURLWithPath: path, isDirectory: true)
        let configURL = bundleURL.appendingPathComponent("config.plist")

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw UTMImportError.notAUTMBundle(path)
        }

        let configData: Data
        do {
            configData = try Data(contentsOf: configURL)
        } catch {
            throw UTMImportError.invalidConfig("Failed to read config.plist: \(error.localizedDescription)")
        }
        let plist: [String: Any]
        do {
            guard let dict = try PropertyListSerialization.propertyList(
                from: configData, options: [], format: nil
            ) as? [String: Any] else {
                throw UTMImportError.invalidConfig("Top-level object is not a dictionary")
            }
            plist = dict
        } catch let error as UTMImportError {
            throw error
        } catch {
            throw UTMImportError.invalidConfig(error.localizedDescription)
        }

        // Validate backend
        guard let backend = plist["Backend"] as? String else {
            throw UTMImportError.invalidConfig("Missing Backend key")
        }
        guard backend == "Apple" else {
            throw UTMImportError.unsupportedBackend(backend)
        }

        // Validate system
        guard let system = plist["System"] as? [String: Any] else {
            throw UTMImportError.invalidConfig("Missing System key")
        }
        guard let arch = system["Architecture"] as? String else {
            throw UTMImportError.invalidConfig("Missing System.Architecture")
        }
        guard arch == "aarch64" else {
            throw UTMImportError.unsupportedArchitecture(arch)
        }
        guard let boot = system["Boot"] as? [String: Any],
              let uefiBoot = boot["UEFIBoot"] as? Bool, uefiBoot else {
            throw UTMImportError.invalidConfig("Only UEFI boot is supported")
        }

        self.bundleURL = bundleURL

        // Name
        if let info = plist["Information"] as? [String: Any],
           let vmName = info["Name"] as? String {
            self.name = vmName
        } else {
            self.name = bundleURL.deletingPathExtension().lastPathComponent
        }

        // CPU / memory
        self.cpuCount = system["CPUCount"] as? Int ?? 4
        self.memorySizeMB = system["MemorySize"] as? Int ?? 4096

        // EFI variable storage
        if let efiPath = boot["EfiVariableStoragePath"] as? String {
            self.efiVariableStoragePath = efiPath
        } else {
            self.efiVariableStoragePath = nil
        }

        // Machine identifier (base64-encoded data)
        if let platform = system["GenericPlatform"] as? [String: Any],
           let machineIDData = platform["machineIdentifier"] as? Data {
            self.machineIdentifierData = machineIDData
        } else {
            self.machineIdentifierData = nil
        }

        // Drives
        if let drivesArray = plist["Drive"] as? [[String: Any]] {
            self.drives = drivesArray.compactMap { dict in
                guard let id = dict["Identifier"] as? String,
                      let imageName = dict["ImageName"] as? String else {
                    return nil
                }
                return Drive(
                    identifier: id,
                    imageName: imageName,
                    isNVMe: dict["Nvme"] as? Bool ?? false,
                    isReadOnly: dict["ReadOnly"] as? Bool ?? false
                )
            }
        } else {
            self.drives = []
        }

        // Networks
        if let netArray = plist["Network"] as? [[String: Any]] {
            self.networks = netArray.compactMap { dict in
                guard let mode = dict["Mode"] as? String else { return nil }
                return Network(
                    mode: mode,
                    macAddress: dict["MacAddress"] as? String,
                    bridgeInterface: dict["BridgeInterface"] as? String
                )
            }
        } else {
            self.networks = []
        }
    }

    // MARK: - Derived accessors

    /// The main writable non-NVMe disk (largest by convention — typically the HA OS image).
    /// Returns `nil` if no suitable disk is found.
    public var mainDisk: Drive? {
        let candidates = drives.filter { !$0.isNVMe && !$0.isReadOnly }
        guard !candidates.isEmpty else { return nil }
        // Pick the largest disk image by file size
        return candidates.max(by: { a, b in
            let sizeA = imageFileSize(a) ?? 0
            let sizeB = imageFileSize(b) ?? 0
            return sizeA < sizeB
        })
    }

    /// All drives other than the main disk (for warning users about skipped data).
    public var auxiliaryDisks: [Drive] {
        guard let main = mainDisk else { return drives }
        return drives.filter { $0.identifier != main.identifier }
    }

    /// Resolved URL for the EFI variable store file, if it exists.
    public var efiVarsURL: URL? {
        guard let path = efiVariableStoragePath else { return nil }
        let url = resolveURL(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Resolve a relative path (from config.plist) against the Data/ directory.
    public func resolveURL(_ relativePath: String) -> URL {
        let dataDir = bundleURL.appendingPathComponent("Data", isDirectory: true)
        // The path may contain components — use appendingPathComponent for each
        // to ensure proper URL construction.
        var url = dataDir
        let components = relativePath.split(separator: "/")
        for component in components {
            url = url.appendingPathComponent(String(component))
        }
        return url
    }

    /// File size of a drive's image, or nil if it doesn't exist.
    private func imageFileSize(_ drive: Drive) -> Int64? {
        let url = resolveURL(drive.imageName)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return (attrs[.size] as? NSNumber)?.int64Value
    }
}

// MARK: - Import errors

public enum UTMImportError: Error, CustomStringConvertible {
    case notAUTMBundle(String)
    case invalidConfig(String)
    case unsupportedBackend(String)
    case unsupportedArchitecture(String)
    case noSuitableDisk
    case existingVMData(String)

    public var description: String {
        switch self {
        case .notAUTMBundle(let path):
            return "Not a UTM bundle (no config.plist found): \(path)"
        case .invalidConfig(let detail):
            return "Invalid UTM config: \(detail)"
        case .unsupportedBackend(let backend):
            return "Unsupported UTM backend '\(backend)' — only Apple Virtualization is supported"
        case .unsupportedArchitecture(let arch):
            return "Unsupported architecture '\(arch)' — only aarch64 is supported"
        case .noSuitableDisk:
            return "No suitable writable non-NVMe disk found in the UTM bundle"
        case .existingVMData(let path):
            return "VM data already exists at \(path). Use --force to overwrite."
        }
    }
}
