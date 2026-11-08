import Foundation
import Testing
@_weakLinked import DiskImageKit
@testable import HavmCore

/// Snapshot layers, as UTM's Apple backend stacks them on macOS 27+.
@Suite struct LayeredDiskTests {

    /// Run `body` with a unique temporary directory, removed afterwards.
    private func withTempRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("havm-layer-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    /// A 64 MiB base image with a snapshot layer `s1` and a `current` layer
    /// above it, built the way UTM builds one.
    @available(macOS 27.0, *)
    private func makeStack(in root: URL) throws -> (base: URL, s1: URL, current: URL) {
        let base = root.appendingPathComponent("disk.asif")
        let s1 = root.appendingPathComponent("disk.asif.s1.asif")
        let current = root.appendingPathComponent("disk.asif.current.asif")

        _ = try DiskImageKit.DiskImage(
            creating: .asif(url: base, blockCount: 1 << 17, blockSize: .bytes512)
        )
        // Freeze everything written so far into a snapshot layer.
        _ = try DiskImageKit.DiskImage(opening: .open(url: base, mode: .readOnly))
            .appending(ASIFCreationConfiguration.layer(url: s1, type: .overlay))
        // Writes go to a new layer above it.
        _ = try DiskImageKit.DiskImage(opening: .open(url: base, mode: .readOnly))
            .appending(DiskImageKit.DiskImage(opening: .open(url: s1, mode: .readOnly)))
            .appending(ASIFCreationConfiguration.layer(url: current, type: .overlay))
        return (base, s1, current)
    }

    @Test @available(macOS 27.0, *)
    func chainRunsFromTheBaseToTheLayerBeingWritten() throws {
        try withTempRoot { root in
            let stack = try makeStack(in: root)

            #expect(DiskImageSupport.kind(of: stack.base) == .stacked)

            let chain = try LayeredDisk.chain(of: stack.base)
            #expect(chain.map(\.name) == ["s1", "current"])
            #expect(chain.last?.isCurrent == true)
            #expect(chain.first?.parentUUID == nil, "a layer on the base has no layer below it")
            #expect(chain.last?.parentUUID == chain.first?.uuid)

            // The attachment is what the framework boots: the whole stack, not
            // the base alone.
            _ = try LayeredDisk.attachment(for: stack.base)
        }
    }

    @Test @available(macOS 27.0, *)
    func aLayeredDiskReportsTheSizeTheGuestSees() throws {
        try withTempRoot { root in
            let stack = try makeStack(in: root)
            let info = try #require(DiskImageSupport.info(at: stack.base))
            #expect(info.kind == .stacked)
            #expect(info.virtualSize == 64 * 1024 * 1024)
            // The layers are host bytes, so they count as allocation.
            #expect(info.allocatedSize > info.virtualSize - 64 * 1024 * 1024)
        }
    }

    @Test @available(macOS 27.0, *)
    func aMissingLayerBreaksTheChain() throws {
        try withTempRoot { root in
            let stack = try makeStack(in: root)
            try FileManager.default.removeItem(at: stack.s1)

            #expect(throws: LayeredDiskError.self) {
                _ = try LayeredDisk.chain(of: stack.base)
            }
        }
    }

    @Test @available(macOS 27.0, *)
    func layersWithoutACurrentOneAreRefused() throws {
        try withTempRoot { root in
            let stack = try makeStack(in: root)
            try FileManager.default.removeItem(at: stack.current)

            #expect(throws: LayeredDiskError.self) {
                _ = try LayeredDisk.chain(of: stack.base)
            }
        }
    }

    @Test @available(macOS 27.0, *)
    func importedLayersAreRenamedWithTheirDisk() throws {
        try withTempRoot { root in
            let stack = try makeStack(in: root)
            let chain = try LayeredDisk.chain(of: stack.base)
            let destination = root.appendingPathComponent("haos.img")

            let names = chain.compactMap {
                LayeredDisk.importedURL(for: $0, base: stack.base, destination: destination)?
                    .lastPathComponent
            }
            #expect(names == ["haos.img.s1.asif", "haos.img.current.asif"])
        }
    }
}
