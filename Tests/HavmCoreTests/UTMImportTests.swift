import Foundation
import Testing
@testable import HavmCore

@Suite struct UTMImportTests {

    // MARK: - Fixtures

    /// Run `body` with a unique temporary directory, removed afterwards.
    private func withTempRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("havm-utm-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    /// Minimal `config.plist` for an Apple/aarch64 UEFI bundle.
    private func plist(drives: [[String: Any]], efiPath: String? = nil) -> [String: Any] {
        var boot: [String: Any] = ["UEFIBoot": true]
        if let efiPath { boot["EfiVariableStoragePath"] = efiPath }
        return [
            "Backend": "Apple",
            "System": [
                "Architecture": "aarch64",
                "Boot": boot,
                "CPUCount": 2,
                "MemorySize": 2048,
            ],
            "Drive": drives,
        ]
    }

    /// Write a bundle directory (with an empty `Data/`) at `url`.
    private func writeBundle(at url: URL, plist: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Data"), withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: url.appendingPathComponent("config.plist"))
    }

    /// The error thrown by `UTMBundle(path:)`, if any.
    private func parseError(at path: String) -> UTMImportError? {
        #expect(throws: UTMImportError.self) {
            _ = try UTMBundle(path: path)
        }
    }

    // MARK: - Path validation

    @Test("Unsafe relative paths are rejected", arguments: [
        "..",
        "../secret",
        "a/../../b",
        "/etc/passwd",
        "",
    ])
    func rejectsUnsafePaths(path: String) {
        #expect(!UTMBundle.isSafeBundleRelativePath(path))
    }

    @Test("Ordinary relative paths are accepted", arguments: [
        "disk.img",
        "sub/dir/disk.img",
        "..hidden",
    ])
    func acceptsSafePaths(path: String) {
        #expect(UTMBundle.isSafeBundleRelativePath(path))
    }

    // MARK: - config.plist path containment

    @Test("A drive image path cannot climb out of the bundle")
    func rejectsDrivePathTraversal() throws {
        try withTempRoot { root in
            let bundle = root.appendingPathComponent("Evil.utm")
            try writeBundle(at: bundle, plist: plist(drives: [
                ["Identifier": "d1", "ImageName": "../../../../../../etc/passwd"],
            ]))

            let error = parseError(at: bundle.path)
            guard case .unsafePath = error else {
                Issue.record("Expected .unsafePath, got \(String(describing: error))")
                return
            }
        }
    }

    @Test("The EFI variable store path cannot climb out of the bundle")
    func rejectsEFIPathTraversal() throws {
        try withTempRoot { root in
            let bundle = root.appendingPathComponent("Evil.utm")
            try writeBundle(at: bundle, plist: plist(
                drives: [["Identifier": "d1", "ImageName": "disk.img"]],
                efiPath: "../../secret.fd"
            ))

            let error = parseError(at: bundle.path)
            guard case .unsafePath = error else {
                Issue.record("Expected .unsafePath, got \(String(describing: error))")
                return
            }
        }
    }

    @Test("An absolute drive image path is rejected")
    func rejectsAbsoluteDrivePath() throws {
        try withTempRoot { root in
            let bundle = root.appendingPathComponent("Evil.utm")
            try writeBundle(at: bundle, plist: plist(drives: [
                ["Identifier": "d1", "ImageName": "/etc/passwd"],
            ]))

            let error = parseError(at: bundle.path)
            guard case .unsafePath = error else {
                Issue.record("Expected .unsafePath, got \(String(describing: error))")
                return
            }
        }
    }

    @Test("resolveURL refuses traversal even when parsing is bypassed")
    func resolveURLRejectsTraversal() throws {
        try withTempRoot { root in
            let bundle = root.appendingPathComponent("Good.utm")
            try writeBundle(at: bundle, plist: plist(drives: [
                ["Identifier": "main", "ImageName": "disk.img"],
            ]))
            let parsed = try UTMBundle(path: bundle.path)

            // Parsing rejects these, but resolveURL is the chokepoint every
            // caller goes through — it must not rely on that.
            #expect(parsed.resolveURL("../../../../etc/passwd") == nil)
            #expect(parsed.resolveURL("/etc/passwd") == nil)
            #expect(parsed.resolveURL("") == nil)
        }
    }

    // MARK: - Symlinks (an extracted bundle can carry them)

    @Test("A symlinked disk image cannot point outside the bundle")
    func rejectsSymlinkEscape() throws {
        try withTempRoot { root in
            let bundle = root.appendingPathComponent("Evil.utm")
            try writeBundle(at: bundle, plist: plist(drives: [
                ["Identifier": "d1", "ImageName": "disk.img"],
            ]))
            // The plist path is lexically fine — the symlink is what escapes.
            try FileManager.default.createSymbolicLink(
                at: bundle.appendingPathComponent("Data/disk.img"),
                withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
            )

            let parsed = try UTMBundle(path: bundle.path)
            #expect(parsed.resolveURL("disk.img") == nil)
            // Parsing succeeds; refusing the copy is the command's job.
            #expect(parsed.mainDisk?.identifier == "d1")
        }
    }

    @Test("A symlinked Data directory cannot redirect reads off the bundle")
    func rejectsSymlinkedDataDirectory() throws {
        try withTempRoot { root in
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try "secret".write(
                to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8
            )

            // Built by hand: Data/ is a symlink, so `writeBundle` would fail.
            let bundle = root.appendingPathComponent("Evil.utm")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist(drives: [["Identifier": "d1", "ImageName": "secret.txt"]]),
                format: .xml, options: 0
            )
            try data.write(to: bundle.appendingPathComponent("config.plist"))
            try FileManager.default.createSymbolicLink(
                at: bundle.appendingPathComponent("Data"), withDestinationURL: outside
            )

            let parsed = try UTMBundle(path: bundle.path)
            #expect(parsed.resolveURL("secret.txt") == nil)
            #expect(parsed.efiVarsURL == nil)
        }
    }

    // MARK: - Normal bundles keep working

    @Test("A well-formed bundle resolves everything inside its own Data directory")
    func resolvesNormalPaths() throws {
        try withTempRoot { root in
            let bundle = root.appendingPathComponent("Good.utm")
            try writeBundle(at: bundle, plist: plist(
                drives: [
                    ["Identifier": "main", "ImageName": "disk.img"],
                    ["Identifier": "aux", "ImageName": "aux.img", "ReadOnly": true],
                ],
                efiPath: "efi-vars.fd"
            ))
            try Data("disk".utf8).write(to: bundle.appendingPathComponent("Data/disk.img"))
            try Data("efi".utf8).write(to: bundle.appendingPathComponent("Data/efi-vars.fd"))

            let parsed = try UTMBundle(path: bundle.path)

            let disk = try #require(parsed.resolveURL("disk.img"))
            #expect(disk.path.hasSuffix("/Data/disk.img"))
            #expect(parsed.mainDisk?.identifier == "main")
            #expect(parsed.auxiliaryDisks.map(\.identifier) == ["aux"])
            #expect(parsed.efiVarsURL?.path.hasSuffix("/Data/efi-vars.fd") == true)
        }
    }
}
