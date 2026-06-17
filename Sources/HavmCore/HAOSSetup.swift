import Foundation
import CXZ
import Logging
import CryptoKit

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
    case diskTooSmall
    case checksumMismatch(String)
    case noChecksumAvailable(String)

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
        case .diskTooSmall:
            return "Disk image is too small for GPT repair."
        case .checksumMismatch(let path):
            return "SHA256 checksum mismatch for \(path). The file may be corrupted or truncated. Delete the cached file and try again."
        case .noChecksumAvailable(let path):
            return "No SHA256 checksum available to verify \(path)."
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

    public init(config: HavmConfig, logger: Logger = Logger(label: "havm.setup")) {
        self.config = config
        self.logger = logger
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
                // Verify checksum if available
                if let checksumAsset = findChecksumAsset(in: release, for: imageAsset.name) {
                    try await verifyChecksum(for: cachedXZPath, checksumAsset: checksumAsset)
                } else {
                    logger.warning("No SHA256 checksum found for \(imageAsset.name) — skipping integrity check")
                }
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
        // GPT repair is complex; deferring until we verify basic EFI boot works.
        let targetSize = config.effectiveDiskSize
        let attrs = try fileManager.attributesOfItem(atPath: HavmConfig.persistentDiskPath)
        let currentSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        if currentSize < targetSize {
            logger.info("Resizing disk from \(MemorySize(bytes: currentSize)) to \(MemorySize(bytes: targetSize))...")
            let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: HavmConfig.persistentDiskPath))
            defer { try? fh.close() }
            try fh.seek(toOffset: targetSize - 1)
            try fh.write(contentsOf: Data([0]))
            try fh.synchronize()
            logger.info("Disk resized. HA OS will auto-expand partitions on first boot.")
        }

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

        let data = try await fetchWithRetry(url: url, description: "GitHub releases API")

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

    /// Look for a SHA256 checksum file in the release assets.
    /// HA OS publishes a `.sha256` file alongside each `.img.xz`.
    private func findChecksumAsset(in release: GitHubRelease, for imageName: String) -> GitHubAsset? {
        // Expected: e.g. "haos_generic-aarch64-13.2.img.xz.sha256"
        let checksumName = "\(imageName).sha256"
        return release.assets.first { $0.name == checksumName }
    }

    // MARK: - Retry logic

    /// Fetch a URL with exponential backoff retry for transient errors.
    /// Retries up to 3 times for 5xx and 429 responses.
    private func fetchWithRetry(url: URL, description: String) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw SetupError.noAssetsFound("Not an HTTP response")
                }
                if (200...299).contains(httpResponse.statusCode) {
                    return data
                }
                if httpResponse.statusCode == 429 || (500...599).contains(httpResponse.statusCode) {
                    lastError = SetupError.downloadFailed(url.absoluteString,
                        NSError(domain: "", code: httpResponse.statusCode,
                                userInfo: [NSLocalizedDescriptionKey:
                                    "HTTP \(httpResponse.statusCode) (attempt \(attempt + 1)/3)"]))
                } else {
                    throw SetupError.noAssetsFound("HTTP \(httpResponse.statusCode)")
                }
            } catch let error as SetupError {
                lastError = error
            } catch {
                lastError = error
            }

            if attempt < 2 {
                let delay = Double(1 << attempt)  // 1s, 2s backoff
                logger.info("\(description): retrying in \(Int(delay))s...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError ?? SetupError.noAssetsFound("Failed after 3 attempts")
    }

    // MARK: - Download

    private func downloadAsset(_ asset: GitHubAsset, to destination: String) async throws -> String {
        guard let url = URL(string: asset.browserDownloadURL) else {
            throw SetupError.downloadFailed(asset.browserDownloadURL,
                NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
        }

        logger.info("Downloading \(asset.name) (\(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file)))...")

        // Stream to a temporary file first, then rename atomically.
        // Uses URLSession.download which streams to disk — no memory pressure
        // from large (300+ MB) images.
        let tempDir = (HavmConfig.cacheDirectory as NSString)
            .appendingPathComponent(".downloads")
        try fileManager.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        let tempPath = (tempDir as NSString).appendingPathComponent(UUID().uuidString)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = DownloadDelegate(tempPath: tempPath, logger: logger, assetName: asset.name)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            delegate.onComplete = { result in
                session.invalidateAndCancel()
                continuation.resume(with: result)
            }
            task.resume()
        }

        // Atomic rename: move from temp to final destination
        try fileManager.moveItem(atPath: tempPath, toPath: destination)

        return destination
    }

    // MARK: - Checksum verification

    private func verifyChecksum(for filePath: String, checksumAsset: GitHubAsset) async throws {
        guard let url = URL(string: checksumAsset.browserDownloadURL) else {
            logger.warning("Invalid checksum URL for \(checksumAsset.name)")
            return
        }

        logger.info("Verifying SHA256 checksum...")

        let checksumData: Data
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw SetupError.noChecksumAvailable(checksumAsset.name)
            }
            checksumData = data
        } catch let error as SetupError { throw error }
        catch {
            throw SetupError.downloadFailed(url.absoluteString, error)
        }

        // Parse checksum file: "<hex>  <filename>" or "<hex> *<filename>"
        guard let checksumText = String(data: checksumData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw SetupError.noChecksumAvailable(checksumAsset.name)
        }
        let expectedHex = checksumText.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? checksumText

        // Compute SHA256 of the downloaded file (streaming for memory efficiency)
        let fileURL = URL(fileURLWithPath: filePath)
        let computed = try SHA256.hash(url: fileURL)

        let computedHex = computed.compactMap { String(format: "%02x", $0) }.joined()
        guard computedHex.lowercased() == expectedHex.lowercased() else {
            // Remove the corrupted file so we re-download next time
            try? fileManager.removeItem(atPath: filePath)
            throw SetupError.checksumMismatch(filePath)
        }

        logger.info("SHA256 checksum OK")
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

    private func createDirectories() {
        for dir in [HavmConfig.dataDirectory, HavmConfig.cacheDirectory, HavmConfig.vmDirectory] {
            try? fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Download delegate (streaming)

/// URLSessionDownloadDelegate that reports completion and streams to disk.
/// The delegate keeps session alive via its `onComplete` closure.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let tempPath: String
    let logger: Logger
    let assetName: String
    var onComplete: ((Result<Void, Error>) -> Void)?

    init(tempPath: String, logger: Logger, assetName: String) {
        self.tempPath = tempPath
        self.logger = logger
        self.assetName = assetName
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            try FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: tempPath))
            onComplete?(.success(()))
        } catch {
            onComplete?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onComplete?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // Log progress periodically — totalBytesExpectedToWrite may be -1 (unknown)
        if totalBytesExpectedToWrite > 0 && totalBytesWritten % (5 * 1024 * 1024) < (bytesWritten) {
            let pct = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
            logger.info("Download progress: \(pct)% (\(ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)))")
        }
    }
}

// MARK: - SHA256 stream hash

extension SHA256 {
    /// Compute SHA256 hash of a file at a URL, reading in chunks to avoid
    /// loading the entire file into memory (important for 6+ GB decompressed images).
    fileprivate static func hash(url: URL) throws -> SHA256Digest {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        var hasher = SHA256()
        while let chunk = try fh.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }
}
