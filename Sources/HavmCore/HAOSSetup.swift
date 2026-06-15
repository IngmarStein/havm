import Foundation
import CXZ
import Logging

// MARK: - GitHub Release model

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case assets
    }
}

struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String
    let size: Int64

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

// MARK: - Setup error

public enum SetupError: Error, CustomStringConvertible {
    case noAssetsFound(String)
    case downloadFailed(String, Error)
    case decompressFailed(String)
    case diskCopyFailed(String)

    public var description: String {
        switch self {
        case .noAssetsFound(let version):
            return "No aarch64 image found for HA OS \(version)."
        case .downloadFailed(let url, let error):
            return "Failed to download \(url): \(error.localizedDescription)"
        case .decompressFailed(let path):
            return "Failed to decompress \(path)."
        case .diskCopyFailed(let path):
            return "Failed to copy disk image to \(path)."
        }
    }
}

// MARK: - Setup manager

/// Manages initial HA OS setup: download, prepare persistent disk.
/// Uses VZEFIBootLoader — no kernel extraction needed.
public final class HAOSSetupManager: @unchecked Sendable {
    private let config: HavmConfig
    private let logger: Logger
    private let fileManager = FileManager.default
    private let session: URLSession

    public init(config: HavmConfig, logger: Logger = Logger(label: "havm.setup")) {
        self.config = config
        self.logger = logger
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Public API

    /// Check if a VM has already been set up (persistent disk exists).
    public var isSetupComplete: Bool {
        fileManager.fileExists(atPath: HavmConfig.persistentDiskPath)
    }

    /// Run the full setup: download (if needed), prepare persistent disk.
    /// Idempotent — skips if the disk already exists.
    public func setupIfNeeded() async throws {
        if isSetupComplete {
            logger.info("VM already set up, skipping download.")
            // Still update SSH CONFIG disk in case config changed
            try setupSSHConfigDisk()
            return
        }

        logger.info("Starting HA OS setup...")
        createDirectories()

        // 1. Find the best release
        let release = try await fetchRelease()
        let imageAsset = try findAArch64Image(in: release)
        logger.info("Found HA OS \(release.tagName): \(imageAsset.name)")

        // 2. Download and decompress disk image if needed
        let cachedImagePath = (HavmConfig.cacheDirectory as NSString)
            .appendingPathComponent(decompressedName(for: imageAsset.name))
        let cachedXZPath = (HavmConfig.cacheDirectory as NSString)
            .appendingPathComponent(imageAsset.name)

        if fileManager.fileExists(atPath: cachedImagePath) {
            logger.info("Using cached image: \(cachedImagePath)")
        } else {
            if !fileManager.fileExists(atPath: cachedXZPath) {
                _ = try await downloadAsset(imageAsset, to: cachedXZPath)
            } else {
                logger.info("Using cached download: \(cachedXZPath)")
            }
            let rawPath = try decompressXZ(cachedXZPath, to: cachedImagePath)
            logger.info("Decompressed to \(rawPath)")
        }

        // 3. Copy disk image to persistent location
        try copyDiskImage(from: cachedImagePath, to: HavmConfig.persistentDiskPath)
        logger.info("Copied disk image to \(HavmConfig.persistentDiskPath)")

        // 4. Resize disk image if needed
        let targetSize = config.effectiveDiskSize
        try resizeDiskIfNeeded(at: HavmConfig.persistentDiskPath, targetSize: targetSize)

        // 5. Create SSH CONFIG disk if authorized_keys is configured
        try setupSSHConfigDisk()

        logger.info("✅ HA OS setup complete.")
    }

    // MARK: - SSH CONFIG disk

    private func setupSSHConfigDisk() throws {
        guard let keyPath = config.effectiveSSHKeyPath else {
            logger.debug("No SSH authorized_keys configured, skipping CONFIG disk")
            return
        }
        logger.info("SSH key path configured: \(keyPath)")

        let expandedPath = (keyPath as NSString).expandingTildeInPath
        guard fileManager.fileExists(atPath: expandedPath) else {
            logger.warning("SSH authorized_keys file not found: \(expandedPath)")
            return
        }

        let keyData = try Data(contentsOf: URL(fileURLWithPath: expandedPath))
        guard !keyData.isEmpty else {
            logger.warning("SSH authorized_keys file is empty")
            return
        }

        let configDisk = CONFIGDiskBuilder.build(authorizedKey: keyData)
        try configDisk.write(to: URL(fileURLWithPath: HavmConfig.configDiskPath))
        logger.info("SSH CONFIG disk created at \(HavmConfig.configDiskPath)")
    }

    // MARK: - GitHub API

    private static let haosRepoAPI = "https://api.github.com/repos/home-assistant/operating-system/releases"

    private func fetchRelease() async throws -> GitHubRelease {
        var urlString = Self.haosRepoAPI
        switch config.effectiveReleaseChannel {
        case .stable: urlString += "/latest"
        case .preRelease: urlString += "?per_page=5"
        }

        guard let url = URL(string: urlString) else {
            throw SetupError.noAssetsFound("invalid URL")
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SetupError.noAssetsFound("HTTP error")
        }

        if config.effectiveReleaseChannel == .preRelease {
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            guard let first = releases.first else {
                throw SetupError.noAssetsFound("no releases found")
            }
            return first
        } else {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        }
    }

    private func findAArch64Image(in release: GitHubRelease) throws -> GitHubAsset {
        let candidates = release.assets.filter { asset in
            asset.name.hasPrefix("haos_generic-aarch64") && asset.name.hasSuffix(".img.xz")
        }
        guard let best = candidates.first else {
            throw SetupError.noAssetsFound(release.tagName)
        }
        return best
    }

    // MARK: - Download

    private func downloadAsset(_ asset: GitHubAsset, to destination: String) async throws -> String {
        guard let url = URL(string: asset.browserDownloadURL) else {
            throw SetupError.downloadFailed(asset.browserDownloadURL,
                NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
        }

        logger.info("Downloading \(asset.name) (\(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file)))...")

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SetupError.downloadFailed(asset.browserDownloadURL,
                NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "HTTP error"]))
        }

        try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
        return destination
    }

    // MARK: - Decompress

    private func decompressedName(for xzName: String) -> String {
        if xzName.hasSuffix(".xz") { return String(xzName.dropLast(3)) }
        return xzName + ".raw"
    }

    private func decompressXZ(_ xzPath: String, to outputPath: String) throws -> String {
        logger.info("Decompressing \(xzPath)...")
        let result = xz_decompress_file(xzPath, outputPath)
        guard result == 0 else {
            throw SetupError.decompressFailed(xzPath)
        }
        return outputPath
    }

    // MARK: - Disk image

    private func copyDiskImage(from source: String, to destination: String) throws {
        try fileManager.copyItem(atPath: source, toPath: destination)
    }

    private func resizeDiskIfNeeded(at path: String, targetSize: UInt64) throws {
        let attrs = try fileManager.attributesOfItem(atPath: path)
        let currentSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

        if currentSize < targetSize {
            logger.info("Resizing disk from \(MemorySize(bytes: currentSize)) to \(MemorySize(bytes: targetSize))...")

            let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? fh.close() }
            try fh.seek(toOffset: targetSize - 1)
            try fh.write(contentsOf: Data([0]))
            try fh.synchronize()

            logger.info("Disk resized. HA OS will auto-expand partitions on first boot.")
        }
    }

    private func createDirectories() {
        for dir in [HavmConfig.dataDirectory, HavmConfig.cacheDirectory, HavmConfig.vmDirectory] {
            try? fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }
}
