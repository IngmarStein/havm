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

    // MARK: - Foreign containers

    /// A file whose first bytes are `magic`, padded out to a plausible size.
    private func makeContainer(at url: URL, magic: [UInt8], size: Int = 4096) throws {
        var bytes = [UInt8](repeating: 0, count: size)
        for (i, byte) in magic.enumerated() {
            bytes[i] = byte
        }
        try Data(bytes).write(to: url)
    }

    @Test(arguments: [
        (UnsupportedDiskImageFormat.qcow2, Array([0x51, 0x46, 0x49, 0xfb])),
        (.vmdk, Array("KDMV".utf8)),
    ])
    func recognisesUnreadableContainersByMagic(
        format: UnsupportedDiskImageFormat, magic: [UInt8]
    ) throws {
        try withTempRoot { root in
            let url = root.appendingPathComponent("haos.img")
            try makeContainer(at: url, magic: magic)
            #expect(DiskImageSupport.kind(of: url) == .unsupported(format))
        }
    }

    @Test func unreadableContainerHasNoSize() throws {
        try withTempRoot { root in
            let url = root.appendingPathComponent("haos.img")
            try makeContainer(at: url, magic: [0x51, 0x46, 0x49, 0xfb])
            // Reporting the file's length as the disk size is how a qcow2 gets
            // "resized" by appending zeros to a container the guest never sees.
            #expect(DiskImageSupport.info(at: url) == nil)
        }
    }

    // MARK: - UTM snapshot layers

    /// An ASIF base with UTM's snapshot layer naming beside it.
    private func makeLayeredImage(at url: URL) throws {
        try makeContainer(at: url, magic: Array("shdw".utf8))
        try Data().write(to: url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".current.asif"))
    }

    @Test func asifWithSnapshotLayersIsStacked() throws {
        try withTempRoot { root in
            let url = root.appendingPathComponent("haos.img")
            try makeLayeredImage(at: url)
            #expect(DiskImageSupport.kind(of: url) == .stacked)
            #expect(DiskImageSupport.layerFiles(for: url).map(\.lastPathComponent)
                == ["haos.img.current.asif"])
        }
    }

    @Test func asifWithoutLayersIsNotStacked() throws {
        try withTempRoot { root in
            let url = root.appendingPathComponent("haos.img")
            try makeContainer(at: url, magic: Array("shdw".utf8))
            // Neither an unrelated image nor a same-prefix file of another
            // type is a layer UTM would stack.
            try Data().write(to: root.appendingPathComponent("other.asif"))
            try Data().write(to: root.appendingPathComponent("haos.img.backup.bin"))
            #expect(DiskImageSupport.kind(of: url) == .asif)
            #expect(DiskImageSupport.layerFiles(for: url).isEmpty)
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
