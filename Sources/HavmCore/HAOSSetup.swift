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

// MARK: - Constants

private let havmErrorDomain = "havm"

// MARK: - Setup error

public enum SetupError: Error, CustomStringConvertible {
    case noAssetsFound(String)
    case downloadFailed(String, Error)
    case decompressFailed(String)
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
            try ensureDiskSize()
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
        let cachedImagePath = URL(fileURLWithPath: HavmConfig.cacheDirectory)
            .appendingPathComponent(decompressedName(for: imageAsset.name)).path
        let cachedXZPath = URL(fileURLWithPath: HavmConfig.cacheDirectory)
            .appendingPathComponent(imageAsset.name).path

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

        // 3. Clone disk image to persistent location (CoW on APFS, preserves sparseness)
        let destURL = URL(fileURLWithPath: HavmConfig.persistentDiskPath)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        let srcURL = URL(fileURLWithPath: cachedImagePath)
        if clonefile(srcURL.path, destURL.path, 0) != 0 {
            // Cross-volume fallback
            try FileManager.default.copyItem(at: srcURL, to: destURL)
        }
        logger.info("Copied disk image to \(HavmConfig.persistentDiskPath)")

        // 4. Resize disk image if needed
        try ensureDiskSize()

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

        let expandedPath = NSString(string: keyPath).expandingTildeInPath
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
        let (url, channelKey): (URL, String) = {
            var urlString = Self.haosRepoAPI
            let key: String
            switch config.effectiveReleaseChannel {
            case .stable:
                urlString += "/latest"
                key = "stable"
            case .preRelease:
                urlString += "?per_page=5"
                key = "pre-release"
            }
            // URL is built from hardcoded constants — cannot fail.
            return (URL(string: urlString)!, key)
        }()

        let cacheURL = URL(fileURLWithPath: HavmConfig.cacheDirectory)
            .appendingPathComponent("release-\(channelKey).cache")

        // Try conditional request with cached ETag — 304 responses
        // don't count against GitHub's rate limit.
        let cached = loadCachedRelease(from: cacheURL)
        let data: Data
        if let (cachedData, newEtag) = try await fetchWithEtag(
            url: url, etag: cached?.etag, description: "GitHub releases API"
        ) {
            data = cachedData
            if let etag = newEtag {
                saveCachedRelease(etag: etag, data: cachedData, to: cacheURL)
            }
        } else if let cachedData = cached?.data {
            // 304 Not Modified — use cached response (zero rate-limit cost)
            logger.debug("Release data unchanged — using cached response")
            data = cachedData
        } else {
            throw SetupError.noAssetsFound("release data unavailable")
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

    // MARK: - Rate limit help

    /// Extract the rate-limit reset time from an HTTP response, if present.
    private func rateLimitReset(from response: HTTPURLResponse) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "x-ratelimit-reset"),
              let epoch = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    /// Build a human-readable rate-limit error message.
    private func rateLimitMessage(statusCode: Int, resetDate: Date?) -> String {
        let prefix = statusCode == 429
            ? "GitHub API rate limit exceeded"
            : "GitHub API request blocked (HTTP \(statusCode))"
        guard let reset = resetDate else { return prefix }
        let interval = Int(reset.timeIntervalSinceNow)
        if interval <= 0 {
            return "\(prefix) — limit should reset momentarily"
        }
        let minutes = interval / 60
        let seconds = interval % 60
        if minutes > 0 {
            return "\(prefix) — try again in \(minutes)m \(seconds)s"
        }
        return "\(prefix) — try again in \(seconds)s"
    }

    // MARK: - ETag caching

    private struct CachedRelease: Codable {
        let etag: String
        let data: Data
    }

    private func loadCachedRelease(from url: URL) -> CachedRelease? {
        guard let encoded = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedRelease.self, from: encoded) else {
            return nil
        }
        return cached
    }

    private func saveCachedRelease(etag: String, data: Data, to url: URL) {
        let cached = CachedRelease(etag: etag, data: data)
        if let encoded = try? JSONEncoder().encode(cached) {
            try? encoded.write(to: url, options: .atomic)
        }
    }

    /// Fetch a URL with optional `If-None-Match` header.
    /// - Returns: `(data, etag?)` on 200, `nil` on 304, throws on error.
    private func fetchWithEtag(
        url: URL, etag: String?, description: String
    ) async throws -> (Data, String?)? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }

        if http.statusCode == 304 {
            return nil  // Not modified — use cache
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 403 || http.statusCode == 429 {
                let resetDate = rateLimitReset(from: http)
                let message = rateLimitMessage(statusCode: http.statusCode, resetDate: resetDate)
                throw SetupError.downloadFailed(url.absoluteString,
                    NSError(domain: havmErrorDomain, code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: message]))
            }
            throw SetupError.noAssetsFound("HTTP \(http.statusCode)")
        }

        // GitHub returns ETag values like W/"abc123". Strip the qualifier
        // so re-sending the raw value as If-None-Match works correctly.
        let responseEtag: String? = {
            guard var raw = (http.allHeaderFields["Etag"] as? String) ?? nil else {
                return nil
            }
            if raw.hasPrefix("W/\"") && raw.hasSuffix("\"") {
                raw = String(raw.dropFirst(3).dropLast(1))
            } else if raw.hasPrefix("\"") && raw.hasSuffix("\"") {
                raw = String(raw.dropFirst().dropLast())
            }
            return raw.isEmpty ? nil : raw
        }()

        return (data, responseEtag)
    }

    private func findAArch64Image(in release: GitHubRelease) throws -> GitHubAsset {
        guard let image = release.assets.first(where: { asset in
            asset.name.hasPrefix("haos_generic-aarch64") && asset.name.hasSuffix(".img.xz")
        }) else {
            throw SetupError.noAssetsFound(release.tagName)
        }
        return image
    }

    /// Look for a SHA256 checksum file in the release assets.
    /// HA OS publishes a `.sha256` file alongside each `.img.xz`.
    private func findChecksumAsset(in release: GitHubRelease, for imageName: String) -> GitHubAsset? {
        // Expected: e.g. "haos_generic-aarch64-13.2.img.xz.sha256"
        let checksumName = "\(imageName).sha256"
        return release.assets.first { $0.name == checksumName }
    }

    // MARK: - Download

    private func downloadAsset(_ asset: GitHubAsset, to destination: String) async throws -> String {
        guard let url = URL(string: asset.browserDownloadURL) else {
            throw SetupError.downloadFailed(asset.browserDownloadURL,
                NSError(domain: havmErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
        }

        logger.info("Downloading \(asset.name) (\(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file)))...")

        // Stream to a temporary file first, then rename atomically.
        // Uses URLSession.download which streams to disk — no memory pressure
        // from large (300+ MB) images.
        let tempDir = URL(fileURLWithPath: HavmConfig.cacheDirectory)
            .appendingPathComponent(".downloads").path
        try fileManager.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        let tempPath = URL(fileURLWithPath: tempDir).appendingPathComponent(UUID().uuidString).path

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

    /// Ensure the persistent disk is at least the configured size.
    /// Runs on every boot — if the user increased `disk_size` in config,
    /// the file is extended. Shrinking is not supported.
    private func ensureDiskSize() throws {
        let targetSize = config.effectiveDiskSize
        let attrs = try fileManager.attributesOfItem(atPath: HavmConfig.persistentDiskPath)
        let currentSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        guard currentSize < targetSize else { return }
        logger.info("Resizing disk from \(MemorySize(bytes: currentSize)) to \(MemorySize(bytes: targetSize))...")
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: HavmConfig.persistentDiskPath))
        defer { try? fh.close() }
        // APFS extends files with sparse zero blocks — no actual data written.
        try fh.truncate(atOffset: targetSize)
        logger.info("Disk resized. HA OS will auto-expand partitions on first boot.")
    }

    // MARK: - Console cmdline patching

    /// Patch the EFI partition `cmdline.txt` to include `console=hvc0` so
    /// kernel messages appear on the virtio serial console. Idempotent.
    public static func ensureConsoleCmdline() {
        let logger = Logger(label: "havm.console-patch")
        let diskPath = HavmConfig.persistentDiskPath
        guard FileManager.default.fileExists(atPath: diskPath) else {
            logger.debug("Disk image not found — skipping console cmdline patch")
            return
        }

        guard let fh = try? FileHandle(forUpdating: URL(fileURLWithPath: diskPath)) else {
            logger.warning("Could not open disk image for console cmdline patch")
            return
        }
        defer { try? fh.close() }

        // Read LBA 0 (protective MBR) and LBA 1 (GPT header).
        guard let headerBlock = try? fh.read(upToCount: 1024), headerBlock.count >= 1024 else { return }
        let headerBytes = [UInt8](headerBlock)
        guard String(bytes: headerBytes[512..<520], encoding: .utf8) == "EFI PART" else { return }

        // GPT header: entry count at byte 80, entry size at byte 84 (both uint32 LE).
        let entryCount = Int(UInt32(littleEndian: headerBytes[512+80..<512+84].withUnsafeBytes { $0.load(as: UInt32.self) }))
        let entrySize  = Int(UInt32(littleEndian: headerBytes[512+84..<512+88].withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard entryCount > 0, entrySize > 0 else { return }

        // Partition entries start at LBA 2 (offset 1024).
        let entryBufSize = entryCount * entrySize
        try? fh.seek(toOffset: 1024)
        guard let entryData = try? fh.read(upToCount: entryBufSize),
              entryData.count >= entryBufSize else { return }
        let entryBytes = [UInt8](entryData)

        // EFI System Partition (standard GUID, not HA OS specific).
        let espGUID: [UInt8] = [0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
                                0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B]
        var efiOffset: UInt64 = 0
        var efiSize: UInt64 = 0
        for i in 0..<entryCount {
            let off = i * entrySize
            guard off + 48 <= entryBytes.count else { break }
            guard Array(entryBytes[off..<off+16]) == espGUID else { continue }
            let startLBA = entryBytes[off+32..<off+40].withUnsafeBytes { $0.load(as: UInt64.self) }
            let endLBA   = entryBytes[off+40..<off+48].withUnsafeBytes { $0.load(as: UInt64.self) }
            efiOffset = startLBA * 512
            efiSize = (endLBA - startLBA + 1) * 512
            break
        }
        guard efiOffset > 0, efiSize > 0 else {
            logger.debug("EFI partition not found — skipping console cmdline patch")
            return
        }

        // Read the EFI partition.
        try? fh.seek(toOffset: efiOffset)
        guard let efiData = try? fh.read(upToCount: Int(efiSize)), !efiData.isEmpty else { return }
        var efiBytes = [UInt8](efiData)

        let consolePrefix: [UInt8] = [0x63, 0x6f, 0x6e, 0x73, 0x6f, 0x6c, 0x65, 0x3d]  // "console="
        let hvc0: [UInt8] = [0x68, 0x76, 0x63, 0x30]  // "hvc0"

        // Scan for "console=". Only replace console values that are known
        // non-virtio types — never touch an unrecognized value.
        var patched = false
        var idx = 0
        while idx <= efiBytes.count - consolePrefix.count {
            guard Array(efiBytes[idx..<idx+consolePrefix.count]) == consolePrefix else { idx += 1; continue }
            let valStart = idx + consolePrefix.count
            let remain = efiBytes.count - valStart
            if remain >= 4, Array(efiBytes[valStart..<valStart+4]) == hvc0 {
                logger.debug("Console cmdline already set to hvc0")
                return
            }
            // Determine the console value up to the next whitespace or null.
            var end = valStart
            while end < efiBytes.count, efiBytes[end] != 0x20, efiBytes[end] != 0x0a, efiBytes[end] != 0x00 {
                end += 1
            }
            let oldValue = Array(efiBytes[valStart..<end])
            let oldStr = String(bytes: oldValue, encoding: .utf8) ?? ""

            // Only replace known non-virtio console devices. A future HA OS
            // release might already ship with hvc0 or a different device we
            // shouldn't touch.
            let safeToReplace = oldStr.hasPrefix("tty") || oldStr.hasPrefix("hvc")
            guard safeToReplace else {
                logger.debug("Unrecognised console=\(oldStr) — leaving as-is")
                idx = end; continue
            }

            // Consume following space-separated console= entries too.
            while end < efiBytes.count, efiBytes[end] == 0x20 {
                let next = end + 1
                if next + consolePrefix.count <= efiBytes.count,
                   Array(efiBytes[next..<next+consolePrefix.count]) == consolePrefix {
                    end = next + consolePrefix.count
                    while end < efiBytes.count, efiBytes[end] != 0x20, efiBytes[end] != 0x0a, efiBytes[end] != 0x00 {
                        end += 1
                    }
                } else { break }
            }

            // Write "console=hvc0\0" and null remaining old bytes in place.
            let replacement: [UInt8] = [0x63, 0x6f, 0x6e, 0x73, 0x6f, 0x6c, 0x65, 0x3d, 0x68, 0x76, 0x63, 0x30, 0x00]
            for (j, byte) in replacement.enumerated() {
                guard idx + j < efiBytes.count else { break }
                efiBytes[idx + j] = byte
            }
            for j in (idx + replacement.count)..<end {
                guard j < efiBytes.count else { break }
                efiBytes[j] = 0
            }
            patched = true
            idx = end
        }
        guard patched else { return }

        try? fh.seek(toOffset: efiOffset)
        try? fh.write(contentsOf: efiBytes)
        try? fh.synchronize()
        logger.info("Console: patched EFI cmdline.txt — console=hvc0")
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
