import Foundation
import Testing
@testable import HavmCore

@Suite struct HAOSReleaseSelectionTests {

    // MARK: - Fixtures

    private func aarch64Asset(_ version: String) -> GitHubAsset {
        GitHubAsset(name: "haos_generic-aarch64-\(version).img.xz",
                    browserDownloadURL: "https://example.invalid/aarch64-\(version).img.xz",
                    size: 1)
    }

    /// The asset set of a board-specific release: HA OS 18.5 shipped images for
    /// Raspberry Pi and Yellow only, with no `haos_generic-aarch64` among them.
    private var boardOnlyAssets: [GitHubAsset] {
        [
            GitHubAsset(name: "haos_ova-18.5.ova", browserDownloadURL: "https://example.invalid/ova", size: 1),
            GitHubAsset(name: "haos_rpi5-64-18.5.img.xz", browserDownloadURL: "https://example.invalid/rpi5", size: 1),
            GitHubAsset(name: "haos_yellow-18.5.img.xz", browserDownloadURL: "https://example.invalid/yellow", size: 1),
        ]
    }

    private var boardOnlyRelease: GitHubRelease {
        GitHubRelease(tagName: "18.5", assets: boardOnlyAssets)
    }

    private func release(_ tag: String, prerelease: Bool = false,
                         draft: Bool = false, aarch64: Bool = true) -> GitHubRelease {
        GitHubRelease(tagName: tag, prerelease: prerelease, draft: draft,
                      assets: aarch64 ? [aarch64Asset(tag)] : boardOnlyAssets)
    }

    // MARK: - Image predicate

    @Test("Only the generic aarch64 disk image counts")
    func imageNamePredicate() {
        #expect(HAOSReleaseSelection.isAArch64ImageName("haos_generic-aarch64-18.4.img.xz"))
        #expect(!HAOSReleaseSelection.isAArch64ImageName("haos_generic-aarch64-18.4.img.xz.sha256"))
        #expect(!HAOSReleaseSelection.isAArch64ImageName("haos_generic-aarch64-18.4.raucb"))
        #expect(!HAOSReleaseSelection.isAArch64ImageName("haos_rpi5-64-18.4.img.xz"))
        #expect(!HAOSReleaseSelection.isAArch64ImageName("haos_ova-18.4.qcow2.xz"))
    }

    // MARK: - Selection

    /// Issue #31: 18.5 was published for Raspberry Pi and Yellow only, so
    /// `/releases/latest` — which knows nothing about assets — returned a
    /// release havm cannot install.
    @Test("A newest release with no aarch64 image is passed over")
    func skipsBoardOnlyNewest() throws {
        let result = try HAOSReleaseSelection.select(
            from: [boardOnlyRelease, release("18.4"), release("18.3")],
            channel: .stable)

        #expect(result.release.tagName == "18.4")
        #expect(result.skipped.map(\.tagName) == ["18.5"])
    }

    /// The fallback must not land on an RC: when the newest stable is
    /// board-only, the next *stable* release wins, not the newest build with an
    /// aarch64 image.
    @Test("The stable channel never falls back onto a prerelease")
    func stableSkipsPrereleases() throws {
        let result = try HAOSReleaseSelection.select(
            from: [boardOnlyRelease, release("18.5.rc1", prerelease: true), release("18.4")],
            channel: .stable)

        #expect(result.release.tagName == "18.4")
        // Filtered out before selection, so it is not reported as skipped —
        // that list exists to explain a gap against the HA release notes.
        #expect(result.skipped.map(\.tagName) == ["18.5"])
    }

    @Test("The pre-release channel takes the newest installable build, RC or not")
    func preReleaseChannel() throws {
        let result = try HAOSReleaseSelection.select(
            from: [boardOnlyRelease, release("18.5.rc1", prerelease: true), release("18.4")],
            channel: .preRelease)

        #expect(result.release.tagName == "18.5.rc1")
        #expect(result.skipped.map(\.tagName) == ["18.5"])
    }

    @Test("A stable channel with no board-only releases takes the newest")
    func plainNewest() throws {
        let result = try HAOSReleaseSelection.select(
            from: [release("18.4"), release("18.3")], channel: .stable)

        #expect(result.release.tagName == "18.4")
        #expect(result.skipped.isEmpty)
    }

    @Test("Drafts are ignored on both channels")
    func draftsIgnored() throws {
        let drafts = [release("18.6", draft: true), release("18.6.rc1", prerelease: true, draft: true)]
        for channel in [HavmConfig.HAOSOverrides.ReleaseChannel.stable, .preRelease] {
            let result = try HAOSReleaseSelection.select(
                from: drafts + [release("18.5")], channel: channel)
            #expect(result.release.tagName == "18.5")
            #expect(result.skipped.isEmpty)
        }
    }

    @Test("Nothing installable is an error naming the scope")
    func nothingInstallable() {
        let error = #expect(throws: SetupError.self) {
            try HAOSReleaseSelection.select(
                from: [boardOnlyRelease, release("18.4", aarch64: false)], channel: .stable)
        }
        let message = error?.description ?? ""
        #expect(message.contains("2 most recent"))
        #expect(message.contains("18.5"))
    }

    // MARK: - Decoding

    /// The selection reads `prerelease` and `draft`; a payload without them
    /// (an older fixture, or a field GitHub drops) must decode as a plain
    /// stable release rather than failing the whole fetch.
    @Test("Absent prerelease and draft fields decode as stable")
    func decodingDefaults() throws {
        let json = """
        [{"tag_name": "18.4",
          "assets": [{"name": "haos_generic-aarch64-18.4.img.xz",
                      "browser_download_url": "https://example.invalid/i",
                      "size": 1}]}]
        """
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: Data(json.utf8))
        #expect(releases.count == 1)
        #expect(releases[0].prerelease == false)
        #expect(releases[0].draft == false)
        #expect(HAOSReleaseSelection.hasAArch64Image(releases[0]))
    }
}
