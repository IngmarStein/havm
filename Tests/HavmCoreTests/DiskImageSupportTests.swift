import Foundation
import Testing
@testable import HavmCore

@Suite struct DiskImageSupportTests {

    // MARK: - Fixtures

    /// Run `body` with a unique temporary directory, removed afterwards.
    private func withTempRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("havm-disk-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    /// A raw image of `size` bytes with a plausible GPT header.
    private func makeRawImage(at url: URL, size: Int) throws {
        var bytes = [UInt8](repeating: 0, count: size)
        if size >= 520 {
            // "EFI PART" at LBA 1, as a real disk has.
            let signature: [UInt8] = Array("EFI PART".utf8)
            for (i, byte) in signature.enumerated() {
                bytes[512 + i] = byte
            }
        }
        try Data(bytes).write(to: url)
    }

    // MARK: - Format detection

    @Test func recognisesASIFByMagic() throws {
        try withTempRoot { root in
            let url = root.appendingPathComponent("disk.img")
            var bytes = [UInt8]("shdw".utf8)
            bytes += [UInt8](repeating: 0, count: 1020)
            try Data(bytes).write(to: url)
            #expect(DiskImageSupport.kind(of: url) == .asif)
        }
    }

    @Test func treatsGPTImageAsRaw() throws {
        try withTempRoot { root in
            let url = root.appendingPathComponent("haos.img")
            try makeRawImage(at: url, size: 4096)
            #expect(DiskImageSupport.kind(of: url) == .raw)
        }
    }

    @Test func treatsShortFileAsRaw() throws {
        try withTempRoot { root in
            let url = root.appendingPathComponent("tiny.img")
            try Data([0x73, 0x68]).write(to: url)
            #expect(DiskImageSupport.kind(of: url) == .raw)
        }
    }

    @Test func treatsMissingFileAsRaw() throws {
        try withTempRoot { root in
            #expect(DiskImageSupport.kind(of: root.appendingPathComponent("absent.img")) == .raw)
        }
    }

    // MARK: - Inspection

    @Test func rawVirtualSizeIsTheFileSize() throws {
        try withTempRoot { root in
            let url = root.appendingPathComponent("haos.img")
            try makeRawImage(at: url, size: 1 << 20)
            let info = try #require(DiskImageSupport.info(at: url))
            #expect(info.kind == .raw)
            #expect(info.virtualSize == 1 << 20)
            #expect(info.allocatedSize > 0)
        }
    }

    @Test func missingImageHasNoInfo() throws {
        try withTempRoot { root in
            #expect(DiskImageSupport.info(at: root.appendingPathComponent("absent.img")) == nil)
        }
    }

    // MARK: - Resize

    @Test func resizeRefusesRawImages() throws {
        try withTempRoot { root in
            let url = root.appendingPathComponent("haos.img")
            try makeRawImage(at: url, size: 4096)
            #expect(throws: DiskImageError.self) {
                try DiskImageSupport.resize(url, to: 1 << 20)
            }
        }
    }

    // MARK: - Real containers
    //
    // These need `diskutil` and the ASIF format, which arrived in macOS 26.

    @Test @available(macOS 26.0, *)
    func inspectsAndResizesARealContainer() throws {
        try withTempRoot { root in
            let url = root.appendingPathComponent("test.asif")
            let create = Process()
            create.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            create.arguments = ["image", "create", "blank", "--format", "ASIF",
                                "--size", "64m", "--fs", "None", url.path]
            create.standardOutput = FileHandle.nullDevice
            create.standardError = FileHandle.nullDevice
            try create.run()
            create.waitUntilExit()
            try #require(create.terminationStatus == 0, "could not create a test container")

            #expect(DiskImageSupport.kind(of: url) == .asif)

            let before = try #require(DiskImageSupport.info(at: url))
            #expect(before.kind == .asif)
            #expect(before.virtualSize == 64 * 1000 * 1000)
            // The container is the disk, not its file length.
            #expect(before.allocatedSize < before.virtualSize)

            try DiskImageSupport.resize(url, to: 128 * 1000 * 1000)
            let after = try #require(DiskImageSupport.info(at: url))
            #expect(after.virtualSize > before.virtualSize)
        }
    }
}
