import Foundation
import Testing
@testable import HavmCore

/// Where the SHA-256 a download is checked against comes from.
///
/// HA OS publishes no per-file `.sha256` assets, which is what the setup used
/// to look for: every install logged "No SHA256 checksum found" and went
/// ahead. The digest is GitHub's per-asset field instead, with the release's
/// `SHA256SUMS` file as the fallback.
@Suite struct HAOSChecksumTests {

    private static let hex = "16580d8baad9eae15e6e912a044526bed885cb8037cd0d426946bc03e1c0267b"

    // MARK: - GitHub's per-asset digest

    @Test func readsSHA256FromADigestField() {
        #expect(HAOSChecksums.sha256(fromDigest: "sha256:\(Self.hex)") == Self.hex)
        #expect(HAOSChecksums.sha256(fromDigest: "SHA256:\(Self.hex.uppercased())") == Self.hex)
    }

    @Test(arguments: [
        "sha512:" + String(repeating: "a", count: 128),
        "sha256:\(String(repeating: "a", count: 63))",
        "sha256:\(String(repeating: "g", count: 64))",
        "sha256:",
        HAOSChecksumTests.hex,
        "",
    ])
    func rejectsAnythingThatIsNotASHA256(digest: String) {
        #expect(HAOSChecksums.sha256(fromDigest: digest) == nil)
    }

    // MARK: - SHA256SUMS fallback

    @Test func findsTheEntryForTheFile() {
        let sums = """
        1616dd368542591f7b144fc4b21fae51c8d1d23b4545a5b3904011d11ed724a3  haos_generic-aarch64-18.4.qcow2.xz
        \(Self.hex)  haos_generic-aarch64-18.4.img.xz
        c214d0e0e56a2adf7df3bb817fbd5e76f33f24efb4e3c91bbdcee9e199d839cf  haos_generic-aarch64-18.4.vmdk.zip
        """
        #expect(HAOSChecksums.sha256(fromSumsFile: sums, for: "haos_generic-aarch64-18.4.img.xz") == Self.hex)
        #expect(HAOSChecksums.sha256(fromSumsFile: sums, for: "haos_generic-x86-64-18.4.img.xz") == nil)
    }

    @Test func acceptsBinaryModeEntries() {
        let sums = "\(Self.hex) *haos_generic-aarch64-18.4.img.xz\n"
        #expect(HAOSChecksums.sha256(fromSumsFile: sums, for: "haos_generic-aarch64-18.4.img.xz") == Self.hex)
    }

    @Test func ignoresMalformedLines() {
        let sums = """
        not-a-digest  haos_generic-aarch64-18.4.img.xz
        1234  haos_generic-aarch64-18.4.img.xz
        \(Self.hex)
        """
        #expect(HAOSChecksums.sha256(fromSumsFile: sums, for: "haos_generic-aarch64-18.4.img.xz") == nil)
    }

    // MARK: - Decoding

    @Test func decodesTheDigestFromTheReleaseAPI() throws {
        let json = """
        {
          "tag_name": "18.4",
          "name": "18.4",
          "prerelease": false,
          "assets": [
            {
              "name": "haos_generic-aarch64-18.4.img.xz",
              "browser_download_url": "https://example.invalid/img.xz",
              "size": 343933890,
              "digest": "sha256:\(Self.hex)"
            },
            {
              "name": "SHA256SUMS",
              "browser_download_url": "https://example.invalid/SHA256SUMS",
              "size": 4096,
              "digest": null
            }
          ]
        }
        """
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        #expect(release.assets.first?.digest == "sha256:\(Self.hex)")
        #expect(release.assets.last?.digest == nil, "a null digest is not a checksum")
    }
}
