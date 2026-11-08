import Foundation
import Virtualization
@_weakLinked import DiskImageKit

// UTM's Apple Virtualization backend on macOS 27+ keeps snapshots as ASIF
// layers stacked beside the base image: `<image>.<name>.asif`, with the layer
// being written to called `current`. A layer records the identifier of the one
// below it, not its path, so the chain is found by name and ordered by UUID —
// the same rules `UTMAppleDiskImage` uses.
//
// The base alone is the guest as of the first snapshot: attaching it to the
// Virtualization framework succeeds and silently boots a stale disk. Booting
// the stack means handing the framework a DiskImageKit stack instead, through
// `VZDiskImageStorageDeviceAttachment(diskImage:)` (macOS 27+, the API UTM
// itself uses). Below macOS 27 neither that API nor UTM's layer creation
// exists, so a layered image is refused there.

/// A snapshot layer stacked on a disk image.
@available(macOS 27.0, *)
public struct DiskLayer: Sendable, Equatable {
    /// The layer file, beside the base image.
    public let url: URL
    /// The snapshot's name, or `current` for the layer being written to.
    public let name: String
    /// A deleted snapshot whose layer is kept because layers above it need it.
    public let isUnlinked: Bool
    /// This layer's identifier, which the layer above names as its parent.
    public let uuid: UUID
    /// The identifier of the layer below, or nil when it sits on the base.
    public let parentUUID: UUID?

    public var isCurrent: Bool { name == LayeredDisk.currentLayerName }
}

@available(macOS 27.0, *)
public enum LayeredDiskError: Error, CustomStringConvertible, Sendable {
    case notStacked(URL)
    case noCurrentLayer([String])
    case layerMissing(String, below: String)
    case unreadableLayer(String, String)
    case chainLoop(String)
    case importIncomplete(expected: Int, found: Int)

    public var description: String {
        switch self {
        case .notStacked(let url):
            return "\(url.lastPathComponent) has no snapshot layers"
        case .noCurrentLayer(let layers):
            return "The disk has snapshot layers (\(layers.joined(separator: ", "))) but none named " +
                "'\(LayeredDisk.currentLayerName)', so there is no layer to write to. " +
                "Open the VM in UTM to finish the snapshot operation it was interrupted in."
        case .layerMissing(let uuid, let below):
            return "The snapshot layer under '\(below)' is missing (parent \(uuid)). " +
                "The layers above it cannot be used without it."
        case .unreadableLayer(let name, let detail):
            return "Could not read the snapshot layer \(name): \(detail). " +
                "If UTM is running this VM, stop it first."
        case .chainLoop(let name):
            return "The snapshot layers form a loop at \(name) — the chain cannot be ordered."
        case .importIncomplete(let expected, let found):
            return "The imported disk has \(found) of its \(expected) snapshot layers."
        }
    }
}

/// Reads and opens the snapshot layers UTM stacks on an image.
@available(macOS 27.0, *)
public enum LayeredDisk {
    /// The layer UTM writes to, and the name it gives it.
    public static let currentLayerName = "current"

    private static let layerFileExtension = "asif"

    /// Every layer stacked on `baseURL`, in no particular order.
    ///
    /// A layer whose parent is the base image is given a nil `parentUUID`,
    /// which is how the chain knows where to stop: the base has an identifier
    /// of its own, and a layer on top of it names it.
    public static func layers(of baseURL: URL) throws -> [DiskLayer] {
        let files = DiskImageSupport.layerFiles(for: baseURL)
        guard !files.isEmpty else { return [] }

        let baseUUID: UUID?
        do {
            baseUUID = try DiskImageKit.DiskImage(
                opening: .open(url: baseURL, mode: .readOnly)
            ).layerUUID
        } catch {
            throw LayeredDiskError.unreadableLayer(baseURL.lastPathComponent, String(describing: error))
        }

        let prefix = baseURL.lastPathComponent + "."
        return try files.map { url in
            var name = url.lastPathComponent.dropFirst(prefix.count)
            name = name.dropLast(".\(layerFileExtension)".count)
            let isUnlinked = name.hasSuffix(".unlinked")
            if isUnlinked { name = name.dropLast(".unlinked".count) }

            let image: DiskImageKit.DiskImage
            do {
                image = try DiskImageKit.DiskImage(opening: .open(url: url, mode: .readOnly))
            } catch {
                throw LayeredDiskError.unreadableLayer(url.lastPathComponent, String(describing: error))
            }
            guard let uuid = image.layerUUID else {
                throw LayeredDiskError.unreadableLayer(
                    url.lastPathComponent, "the file carries no layer identifier"
                )
            }
            let parent = image.parentUUID == baseUUID ? nil : image.parentUUID
            return DiskLayer(
                url: url,
                name: String(name),
                isUnlinked: isUnlinked,
                uuid: uuid,
                parentUUID: parent
            )
        }
    }

    /// The layers of `baseURL` from the base up to the layer being written to.
    ///
    /// Throws rather than returning a shorter chain: a missing layer holds data
    /// the ones above it were built on, so a chain with a hole is not a disk.
    public static func chain(of baseURL: URL) throws -> [DiskLayer] {
        let layers = try layers(of: baseURL)
        guard !layers.isEmpty else { throw LayeredDiskError.notStacked(baseURL) }
        guard let top = layers.first(where: \.isCurrent) else {
            throw LayeredDiskError.noCurrentLayer(layers.map(\.url.lastPathComponent))
        }

        var chain: [DiskLayer] = []
        var seen = Set<UUID>()
        var next: DiskLayer? = top
        while let layer = next {
            guard seen.insert(layer.uuid).inserted else {
                throw LayeredDiskError.chainLoop(layer.url.lastPathComponent)
            }
            chain.insert(layer, at: 0)
            guard let parentUUID = layer.parentUUID else { break }
            guard let parent = layers.first(where: { $0.uuid == parentUUID }) else {
                throw LayeredDiskError.layerMissing(parentUUID.uuidString, below: layer.name)
            }
            next = parent
        }
        return chain
    }

    /// Open the base and the given chain as one image, everything read-only
    /// except the top layer — the only one the guest writes to.
    public static func open(baseURL: URL, chain: [DiskLayer]) throws -> DiskImageKit.DiskImage {
        var image = try DiskImageKit.DiskImage(
            opening: .open(url: baseURL, mode: chain.isEmpty ? .readWrite : .readOnly)
        )
        for (index, layer) in chain.enumerated() {
            let writable = index == chain.count - 1
            let layerImage = try DiskImageKit.DiskImage(
                opening: .open(url: layer.url, mode: writable ? .readWrite : .readOnly)
            )
            image = try image.appending(layerImage)
        }
        return image
    }

    /// The attachment the framework boots: the whole stack, with the guest's
    /// writes landing in the top layer.
    public static func attachment(for baseURL: URL) throws -> VZDiskImageStorageDeviceAttachment {
        let stack = try open(baseURL: baseURL, chain: try chain(of: baseURL))
        return try VZDiskImageStorageDeviceAttachment(diskImage: stack)
    }

    /// Where a layer of `baseURL` goes when its disk is imported as `destination`.
    ///
    /// The base is renamed on import, and a layer is only found by the name of
    /// the image it sits on, so the layers have to be renamed with it.
    public static func importedURL(
        for layer: DiskLayer, base: URL, destination: URL
    ) -> URL? {
        let prefix = base.lastPathComponent + "."
        let fileName = layer.url.lastPathComponent
        guard fileName.hasPrefix(prefix) else { return nil }
        // "disk.asif.current.asif" becomes "haos.img.current.asif".
        let suffix = fileName.dropFirst(prefix.count)
        return destination.deletingLastPathComponent()
            .appendingPathComponent("\(destination.lastPathComponent).\(suffix)")
    }
}
