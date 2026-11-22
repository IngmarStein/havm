import Darwin
import Foundation
import CXZ
import Logging
import CryptoKit
import Synchronization

// MARK: - GitHub Release model

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String
    /// Prereleases are what the `pre-release` channel exists to offer.
    let prerelease: Bool
    let draft: Bool
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case prerelease
        case draft
        case assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        assets = try container.decodeIfPresent([GitHubAsset].self, forKey: .assets) ?? []
    }

    init(tagName: String, name: String = "", prerelease: Bool = false,
         draft: Bool = false, assets: [GitHubAsset]) {
        self.tagName = tagName
        self.name = name
        self.prerelease = prerelease
        self.draft = draft
        self.assets = assets
    }
}

struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String
    let size: Int64
    /// GitHub's own SHA-256 of the uploaded file (`sha256:<hex>`), the value
    /// the release page shows beside each asset. HA OS publishes no per-file
    /// `.sha256` assets, so this is the checksum there is.
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
        case digest
    }

    init(name: String, browserDownloadURL: String, size: Int64, digest: String? = nil) {
        self.name = name
        self.browserDownloadURL = browserDownloadURL
        self.size = size
        self.digest = digest
    }
}

// MARK: - Checksum parsing

/// Where a release's SHA-256 digests come from.
///
/// HA OS does not publish per-file `.sha256` assets — the lookup that expected
/// `haos_generic-aarch64-<version>.img.xz.sha256` never found anything, so
/// every download was accepted unverified. What a release does publish is a
/// digest for each asset in GitHub's API (`sha256:<hex>`, the value the release
/// page shows) and a `SHA256SUMS` file in the release assets.
enum HAOSChecksums {
    /// The hex of a GitHub `digest` field, if it is a SHA-256.
    static func sha256(fromDigest digest: String) -> String? {
        let parts = digest.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "sha256" else { return nil }
        let hex = parts[1].lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    /// The hex `SHA256SUMS` lists for `fileName`.
    ///
    /// The format is `sha256sum`'s: `<hex>  <name>`, or `<hex> *<name>` for an
    /// entry recorded in binary mode.
    static func sha256(fromSumsFile text: String, for fileName: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            let hex = String(fields[0]).lowercased()
            guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { continue }
            let name = fields[1].hasPrefix("*") ? fields[1].dropFirst() : fields[1]
            if name == fileName { return hex }
        }
        return nil
    }
}

// MARK: - ETag caching

/// GitHub's `Etag` response header, turned into the value to send back in
/// `If-None-Match`.
///
/// The header arrives as `W/"<hex>"`. Only the weak marker is dropped, not the
/// quotes: an entity-tag is a quoted string (RFC 9110 §8.8.3), and a bare hex
/// value is not one. GitHub answers 200 rather than 304 for an unquoted value,
/// which turned the cache into a no-op that still spent a request against the
/// rate limit. Both `W/"…"` and `"…"` are accepted back; the strong form is
/// the one to store, since weak comparison is what `If-None-Match` uses.
enum HAOSETag {
    /// The `If-None-Match` value for a response's `Etag` header, or `nil` when
    /// the header is missing or not an entity-tag at all.
    static func ifNoneMatch(fromHeader raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("W/") { value = String(value.dropFirst(2)) }
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return nil }
        return value
    }
}

// MARK: - Release selection

/// Picks the HA OS release to install from the repo's release list.
///
/// GitHub's `/releases/latest` answers "newest release", which is not the same
/// question: HA OS publishes board-specific releases — 18.5 shipped images for
/// Raspberry Pi and Yellow only — so the newest release may carry no
/// `haos_generic-aarch64` image at all. Selecting from the list lets the newest
/// *installable* release win instead of failing on the newest one.
enum HAOSReleaseSelection {
    struct Result {
        let release: GitHubRelease
        /// Releases newer than `release` that were passed over for want of an
        /// aarch64 image. Logged, so a user comparing against the HA release
        /// notes can see why havm installed an older version.
        let skipped: [GitHubRelease]
    }

    /// Whether an asset name is the aarch64 disk image for this Mac.
    static func isAArch64ImageName(_ name: String) -> Bool {
        name.hasPrefix("haos_generic-aarch64") && name.hasSuffix(".img.xz")
    }

    static func hasAArch64Image(_ release: GitHubRelease) -> Bool {
        release.assets.contains { isAArch64ImageName($0.name) }
    }

    /// Newest release of `channel` that carries an aarch64 image.
    ///
    /// The list is newest-first, as GitHub returns it. Prereleases are filtered
    /// out for the stable channel — without that, a stable install would fall
    /// back onto an RC whenever the newest stable is board-specific.
    static func select(
        from releases: [GitHubRelease],
        channel: HavmConfig.HAOSOverrides.ReleaseChannel
    ) throws -> Result {
        let candidates = releases.filter { release in
            guard !release.draft else { return false }
            return channel == .preRelease || !release.prerelease
        }
        guard let index = candidates.firstIndex(where: hasAArch64Image) else {
            throw SetupError.noAArch64Release(
                scanned: candidates.count,
                newest: candidates.first?.tagName)
        }
        return Result(release: candidates[index],
                      skipped: Array(candidates[..<index]))
    }
}

// MARK: - Constants

private let havmErrorDomain = "havm"

// MARK: - Setup error

public enum SetupError: Error, CustomStringConvertible {
    case noAssetsFound(String)
    case noAArch64Release(scanned: Int, newest: String?)
    case downloadFailed(String, Error)
    case decompressFailed(String)
    case checksumMismatch(String)

    public var description: String {
        switch self {
        case .noAssetsFound(let version):
            return "No aarch64 image found for HA OS \(version)."
        case .noAArch64Release(let scanned, let newest):
            let scope = newest.map { " (newest: \($0))" } ?? ""
            return "No aarch64 image found in the \(scanned) most recent HA OS releases\(scope)."
        case .downloadFailed(let url, let error):
            return "Failed to download \(url): \(error.localizedDescription)"
        case .decompressFailed(let path):
            return "Failed to decompress \(path)."
        case .checksumMismatch(let path):
            return "SHA256 checksum mismatch for \(path). The file may be corrupted or truncated. Delete the cached file and try again."
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
            try refreshBeforeBoot()
            return
        }

        // A VM somewhere else is almost always the one the user meant: the
        // `brew services` job runs with Homebrew's own --data-dir, so a VM
        // imported with the CLI defaults is invisible to it. Say so before
        // spending a download on a second guest.
        if let elsewhere = HavmConfig.diskInDefaultDataDirectory() {
            logger.warning(
                """
                No VM data in \(HavmConfig.dataDirectory), but one exists at \(elsewhere). \
                This run will download a fresh HA OS image — pass --data-dir \(HavmConfig.defaultDataDirectory) \
                to use the existing VM instead.
                """
            )
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
                let tempPath = try await downloadAssetToTemp(imageAsset)
                do {
                    if let expected = await expectedSHA256(for: imageAsset, in: release) {
                        try verifyChecksum(for: tempPath, expectedHex: expected)
                    } else {
                        logger.warning("The release publishes no SHA-256 for \(imageAsset.name) — skipping integrity check")
                    }
                    try Self.atomicMove(from: tempPath, to: cachedXZPath)
                } catch {
                    try? fileManager.removeItem(atPath: tempPath)
                    throw error
                }
            } else {
                logger.info("Using cached download: \(cachedXZPath)")
            }
            let rawPath = try decompressXZ(cachedXZPath, to: cachedImagePath)
            logger.info("Decompressed to \(rawPath)")
        }

        // 3. Clone disk image to persistent location atomically (CoW on APFS, preserves sparseness)
        let destPath = HavmConfig.persistentDiskPath
        let tempDest = destPath + ".tmp-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(atPath: tempDest) }
        if clonefile(cachedImagePath, tempDest, 0) != 0 {
            try fileManager.copyItem(atPath: cachedImagePath, toPath: tempDest)
        }
        try Self.atomicMove(from: tempDest, to: destPath)
        logger.info("Copied disk image to \(destPath)")

        // 4. Resize disk image if needed & create SSH CONFIG disk
        try refreshBeforeBoot()

        logger.info("✅ HA OS setup complete.")
    }

    /// Re-apply mutable pre-boot disk settings (disk size increase and SSH
    /// CONFIG disk) before starting or restarting a VM.
    public func refreshBeforeBoot() throws {
        try ensureDiskSize()
        try setupSSHConfigDisk()
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

        let configDisk: Data
        do {
            configDisk = try ConfigDiskBuilder.build(authorizedKey: keyData)
        } catch {
            // The guest boots either way, and the same is true when the key
            // file is missing — but a key file that is simply too large is a
            // configuration mistake worth naming, not a reason to abort setup.
            logger.warning("SSH CONFIG disk not created: \(error)")
            return
        }
        try configDisk.write(to: URL(fileURLWithPath: HavmConfig.configDiskPath), options: .atomic)
        logger.info("SSH CONFIG disk created at \(HavmConfig.configDiskPath)")
    }

    // MARK: - GitHub API

    private static let haosRepoAPI = "https://api.github.com/repos/home-assistant/operating-system/releases"

    /// How many releases to consider when looking for one with an aarch64
    /// image. Each release carries the assets of every board (~40 KB), so this
    /// is a ~400 KB response — fetched once, on first setup, and ETag-cached
    /// from then on. One board-specific release in a row is the norm; ten
    /// without an aarch64 image is not a case worth designing for beyond a
    /// clear error.
    private static let releaseScanDepth = 10

    private func fetchRelease() async throws -> GitHubRelease {
        // One request either way: the list costs the same against the rate
        // limit as `/latest` did, and the response is cached by ETag.
        // URL is built from hardcoded constants — cannot fail.
        let url = URL(string: "\(Self.haosRepoAPI)?per_page=\(Self.releaseScanDepth)")!

        let cacheURL = URL(fileURLWithPath: HavmConfig.cacheDirectory)
            .appendingPathComponent("releases.cache")

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

        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        guard !releases.isEmpty else {
            throw SetupError.noAssetsFound("no releases found")
        }
        let selection = try HAOSReleaseSelection.select(
            from: releases, channel: config.effectiveReleaseChannel)
        for skipped in selection.skipped {
            logger.warning("HA OS \(skipped.tagName) ships no aarch64 image — using \(selection.release.tagName)")
        }
        return selection.release
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
        // Sanitized again on the way out: a cache written before this was
        // fixed stored the tag without its quotes, which no server matches.
        // Such an entry simply stops being sent, and the 200 replaces it.
        if let value = HAOSETag.ifNoneMatch(fromHeader: etag) {
            request.setValue(value, forHTTPHeaderField: "If-None-Match")
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

        return (data, HAOSETag.ifNoneMatch(fromHeader: http.value(forHTTPHeaderField: "Etag")))
    }

    private func findAArch64Image(in release: GitHubRelease) throws -> GitHubAsset {
        guard let image = release.assets.first(where: { asset in
            HAOSReleaseSelection.isAArch64ImageName(asset.name)
        }) else {
            throw SetupError.noAssetsFound(release.tagName)
        }
        return image
    }

    /// The SHA-256 the release publishes for `asset`, if it publishes one.
    ///
    /// The asset's own digest is what GitHub recorded when the file was
    /// uploaded; a release's `SHA256SUMS` covers an asset that has none. When
    /// neither is available the caller warns and installs unverified, which is
    /// what every install did until the digest was used.
    private func expectedSHA256(for asset: GitHubAsset, in release: GitHubRelease) async -> String? {
        if let digest = asset.digest, let hex = HAOSChecksums.sha256(fromDigest: digest) {
            return hex
        }

        guard let sums = release.assets.first(where: { $0.name == "SHA256SUMS" }),
              let url = Self.validatedHTTPSURL(sums.browserDownloadURL) else {
            return nil
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8) else {
                logger.warning("Could not read SHA256SUMS for \(release.tagName) — skipping integrity check")
                return nil
            }
            return HAOSChecksums.sha256(fromSumsFile: text, for: asset.name)
        } catch {
            logger.warning("Could not fetch SHA256SUMS for \(release.tagName): \(error) — skipping integrity check")
            return nil
        }
    }

    /// Reject non-HTTPS or hostless URLs (defense against tampered `releases.cache`).
    static func validatedHTTPSURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    // MARK: - Download

    private func downloadTempDirectory() throws -> String {
        let tempDir = URL(fileURLWithPath: HavmConfig.cacheDirectory)
            .appendingPathComponent(".downloads").path
        try fileManager.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// Atomically replace `destinationPath` with `sourcePath` via `rename(2)`
    /// (same-volume atomic swap), falling back to remove+move only across volumes.
    static func atomicMove(from sourcePath: String, to destinationPath: String) throws {
        if Darwin.rename(sourcePath, destinationPath) == 0 {
            return
        }
        let code = errno
        guard code == EXDEV else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
            )
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationPath) {
            try fm.removeItem(atPath: destinationPath)
        }
        try fm.moveItem(atPath: sourcePath, toPath: destinationPath)
    }

    private func downloadAssetToTemp(_ asset: GitHubAsset) async throws -> String {
        guard let url = Self.validatedHTTPSURL(asset.browserDownloadURL) else {
            throw SetupError.downloadFailed(asset.browserDownloadURL,
                NSError(domain: havmErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid or non-HTTPS URL"]))
        }

        logger.info("Downloading \(asset.name) (\(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file)))...")

        let tempDir = try downloadTempDirectory()
        let tempPath = URL(fileURLWithPath: tempDir).appendingPathComponent(UUID().uuidString).path

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = DownloadDelegate(
                tempPath: tempPath,
                sourceURL: asset.browserDownloadURL,
                logger: logger
            )
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            delegate.setCompletion { result in
                session.invalidateAndCancel()
                continuation.resume(with: result)
            }
            task.resume()
        }

        return tempPath
    }

    // MARK: - Checksum verification

    private func verifyChecksum(for filePath: String, expectedHex: String) throws {
        logger.info("Verifying SHA256 checksum...")

        // Compute SHA256 of the downloaded file (streaming for memory efficiency)
        let computed = try SHA256.hash(url: URL(fileURLWithPath: filePath))
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
        let tempDir = try downloadTempDirectory()
        let tempOut = URL(fileURLWithPath: tempDir)
            .appendingPathComponent("decompress-\(UUID().uuidString).img").path
        defer { try? fileManager.removeItem(atPath: tempOut) }

        let result = xz_decompress_file(xzPath, tempOut)
        guard result == 0 else {
            throw SetupError.decompressFailed(xzPath)
        }
        try Self.atomicMove(from: tempOut, to: outputPath)
        return outputPath
    }

    // MARK: - Disk image

    /// Ensure the persistent disk is at least the configured size.
    /// Runs on every boot — if the user increased `disk_size` in config,
    /// the disk is extended. Shrinking is not supported.
    ///
    /// The size to compare against is the one the guest sees, which for an
    /// ASIF container is recorded inside it and has nothing to do with the
    /// file's length.
    private func ensureDiskSize() throws {
        let targetSize = config.effectiveDiskSize
        let url = URL(fileURLWithPath: HavmConfig.persistentDiskPath)

        // A container havm cannot read or boot has no size it can act on, so it
        // is refused here rather than through the generic "could not read"
        // path: the file must not be extended. The VM start names the problem
        // and what to do about it; this line only records why no resize
        // happened.
        switch DiskImageSupport.kind(of: url) {
        case .unsupported(let format):
            logger.warning("The disk image is a \(format.displayName) container, which havm cannot boot — skipping the disk size check.")
            return
        case .stacked:
            // A stack cannot be truncated: every layer above the base was built
            // on it as it is (UTM refuses this too). The guest keeps the size
            // it has.
            logger.warning("The disk has UTM snapshot layers beside it, so it cannot be resized — skipping the disk size check.")
            return
        case .raw, .asif:
            break
        }

        guard let info = DiskImageSupport.info(at: url) else {
            logger.warning("Could not read the disk image — skipping the disk size check.")
            return
        }
        guard info.virtualSize < targetSize else { return }
        logger.info("Resizing disk from \(MemorySize(bytes: info.virtualSize)) to \(MemorySize(bytes: targetSize))...")

        switch info.kind {
        case .raw:
            let fh = try FileHandle(forWritingTo: url)
            defer { try? fh.close() }
            // APFS extends files with sparse zero blocks — no actual data written.
            try fh.truncate(atOffset: targetSize)
        case .asif:
            // Extending the file would append zeros and leave the guest on the
            // disk it started with, so the container has to be told instead.
            do {
                try DiskImageSupport.resize(url, to: targetSize)
            } catch {
                // The guest keeps a working disk either way — a smaller one.
                logger.warning("Could not resize the ASIF disk: \(error) — the guest keeps its current size.")
                return
            }
        case .stacked, .unsupported:
            return
        }
        logger.info("Disk resized. HA OS will auto-expand partitions on first boot.")
    }

    // MARK: - Console cmdline patching

    /// Patch the EFI partition `cmdline.txt` to include `console=hvc0` so
    /// kernel messages appear on the virtio serial console. Idempotent.
    ///
    /// A raw image is patched in place. An ASIF container cannot be: its byte
    /// offsets are not the guest's, so it is attached as a block device first
    /// and patched through that instead.
    public static func ensureConsoleCmdline() {
        let logger = Logger(label: "havm.console-patch")
        let diskPath = HavmConfig.persistentDiskPath
        guard FileManager.default.fileExists(atPath: diskPath) else {
            logger.debug("Disk image not found — skipping console cmdline patch")
            return
        }
        let url = URL(fileURLWithPath: diskPath)

        switch DiskImageSupport.kind(of: url) {
        case .raw:
            guard let fh = try? FileHandle(forUpdating: url) else {
                logger.warning("Could not open disk image for console cmdline patch")
                return
            }
            defer { try? fh.close() }
            patchConsoleCmdline(in: fh, logger: logger)
        case .asif:
            do {
                try DiskImageSupport.withBlockDevice(url, readOnly: false) { fh in
                    patchConsoleCmdline(in: fh, logger: logger)
                }
            } catch {
                logger.warning("Console: could not reach the ASIF disk as a block device: \(error) — serial console may not work")
            }
        case .unsupported(let format):
            logger.warning("Console: the disk is a \(format.displayName) container, which havm cannot read — skipping the cmdline patch")
        case .stacked:
            // The base must not be modified while layers are stacked on it:
            // they were built on it as it is.
            logger.warning("Console: the disk has UTM snapshot layers beside it — skipping the cmdline patch")
        }
    }

    private static let maxEFIPartitionBytes: UInt64 = 512 * 1024 * 1024

    /// The GPT/ESP walk and rewrite, run against anything seekable: the image
    /// file itself for a raw disk, or the block device for a container.
    static func patchConsoleCmdline(in fh: FileHandle, logger: Logger) {
        // Read LBA 0 (protective MBR) and LBA 1 (GPT header).
        guard let headerBlock = try? fh.read(upToCount: 1024), headerBlock.count >= 1024 else { return }
        let headerBytes = [UInt8](headerBlock)
        guard String(bytes: headerBytes[512..<520], encoding: .utf8) == "EFI PART" else { return }

        // GPT header: partition entry LBA at byte 72, entry count at byte 80,
        // entry size at byte 84 (all little-endian).
        let entryStartLBA = readLE64(headerBytes, at: 512 + 72)
        let entryCount = Int(readLE32(headerBytes, at: 512 + 80))
        let entrySize  = Int(readLE32(headerBytes, at: 512 + 84))
        guard entryCount > 0, entryCount <= 1024, entrySize >= 128, entrySize <= 4096 else { return }

        // Partition entries as specified by the GPT header (typically LBA 2).
        let (entryBufSize, overflow) = entryCount.multipliedReportingOverflow(by: entrySize)
        guard !overflow else { return }
        let (entryOffset, offsetOverflow) = entryStartLBA.multipliedReportingOverflow(by: 512)
        guard !offsetOverflow else { return }
        do { try fh.seek(toOffset: entryOffset) } catch { return }
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
            let startLBA = readLE64(entryBytes, at: off + 32)
            let endLBA   = readLE64(entryBytes, at: off + 40)
            guard endLBA >= startLBA else { continue }
            let (sectors, secOverflow) = (endLBA - startLBA).addingReportingOverflow(1)
            let (offsetBytes, offOverflow) = startLBA.multipliedReportingOverflow(by: 512)
            let (sizeBytes, sizeOverflow) = sectors.multipliedReportingOverflow(by: 512)
            guard !secOverflow, !offOverflow, !sizeOverflow, sizeBytes <= maxEFIPartitionBytes else {
                continue
            }
            efiOffset = offsetBytes
            efiSize = sizeBytes
            break
        }
        guard efiOffset > 0, efiSize > 0 else {
            logger.debug("EFI partition not found — skipping console cmdline patch")
            return
        }

        // Read the EFI partition.
        do { try fh.seek(toOffset: efiOffset) } catch { return }
        guard let efiData = try? fh.read(upToCount: Int(efiSize)), !efiData.isEmpty else { return }
        var efiBytes = [UInt8](efiData)

        let consolePrefix = Array("console=".utf8)
        let hvc0 = Array("hvc0".utf8)
        let replacement = Array("console=hvc0".utf8)  // 12 bytes, no embedded NUL

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
            while end < efiBytes.count,
                  efiBytes[end] != 0x20, efiBytes[end] != 0x0a, efiBytes[end] != 0x0d, efiBytes[end] != 0x00 {
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
                    while end < efiBytes.count,
                          efiBytes[end] != 0x20, efiBytes[end] != 0x0a, efiBytes[end] != 0x0d, efiBytes[end] != 0x00 {
                        end += 1
                    }
                } else { break }
            }

            // Never overwrite bytes past `end` (would corrupt following kernel args).
            guard end - idx >= replacement.count else {
                logger.debug("console=\(oldStr) is shorter than console=hvc0 — leaving as-is")
                idx = end; continue
            }

            // Write "console=hvc0" and pad remaining old bytes with ASCII spaces
            // (0x20), never NUL (0x00), so subsequent kernel arguments stay intact.
            for (j, byte) in replacement.enumerated() {
                efiBytes[idx + j] = byte
            }
            for j in (idx + replacement.count)..<end {
                efiBytes[j] = 0x20
            }
            patched = true
            idx = end
        }
        guard patched else { return }

        do {
            try fh.seek(toOffset: efiOffset)
            try fh.write(contentsOf: efiBytes)
            try fh.synchronize()
            logger.info("Console: patched EFI cmdline.txt — console=hvc0")
        } catch {
            logger.warning("Console: failed to patch EFI cmdline.txt: \(error) — serial console may not work")
        }
    }

    private static func readLE32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
    }

    private static func readLE64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        bytes[offset..<(offset + 8)].withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
        }
    }

    private func createDirectories() {
        for dir in [HavmConfig.dataDirectory, HavmConfig.cacheDirectory, HavmConfig.vmDirectory] {
            try? fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Download delegate (streaming)

/// URLSessionDownloadDelegate that reports completion exactly once, validates
/// HTTP 2xx status, and streams to disk.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let tempPath: String
    let sourceURL: String
    let logger: Logger
    private let completion = Mutex<((Result<Void, Error>) -> Void)?>(nil)

    init(tempPath: String, sourceURL: String, logger: Logger) {
        self.tempPath = tempPath
        self.sourceURL = sourceURL
        self.logger = logger
    }

    func setCompletion(_ handler: @escaping @Sendable (Result<Void, Error>) -> Void) {
        completion.withLock { $0 = handler }
    }

    private func finish(_ result: Result<Void, Error>) {
        let handler = completion.withLock { current -> ((Result<Void, Error>) -> Void)? in
            let saved = current
            current = nil
            return saved
        }
        handler?(result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            finish(.failure(SetupError.downloadFailed(sourceURL,
                NSError(domain: havmErrorDomain, code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: tempPath))
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(SetupError.downloadFailed(sourceURL, error)))
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
