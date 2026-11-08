import Foundation
import Logging
@_weakLinked import DiskImageKit

// ASIF (Apple Sparse Image Format) is a *container*, not a raw disk: byte
// offsets in the file do not map to offsets on the guest's disk, and the
// file's own length is its allocation rather than the disk's size. macOS 26
// is the first host that knows the format — the Virtualization framework has
// accepted it since, through the same `VZDiskImageStorageDeviceAttachment(url:)`
// havm already uses, despite the header comment that still claims raw only.
//
// havm creates raw images, but it can be handed an ASIF: `import-utm` copies
// a UTM VM's disk verbatim, and a user may drop one in place. Everything here
// degrades to a warning on hosts that cannot read the container, so a raw
// image keeps working everywhere and an ASIF is never silently corrupted.
// A format havm can recognise but not read at all (qcow2, VMDK) is refused by
// its magic at every chokepoint — see `UnsupportedDiskImageFormat`.
//
// DiskImageKit (macOS 27+) is the in-process API for reading and truncating a
// container. macOS 26 has no public equivalent, so `diskutil` answers there —
// a system binary, in the same class as the `/usr/bin/ssh` havm already runs.

/// A disk-image container havm can recognise by its magic but cannot read.
///
/// UTM's Apple Virtualization backend only ever stores raw and ASIF drives —
/// qcow2 and friends belong to its QEMU backend, which `import-utm` refuses
/// before touching a disk. What is left is a file a user copied in by hand:
/// a qcow2 exported from Proxmox or from UTM's QEMU backend, or a VMDK from
/// VMware. Neither is a 1:1 map of the guest's disk, so treating one as raw is
/// how a disk gets silently ruined. The Virtualization framework cannot boot
/// them either, which is why the answer is a refusal, not a conversion.
public enum UnsupportedDiskImageFormat: String, Sendable {
    case qcow2
    case vmdk

    /// The name a user would recognise from the tool that made the file.
    public var displayName: String {
        switch self {
        case .qcow2: "qcow2"
        case .vmdk:  "VMDK"
        }
    }
}

/// The disk image formats havm knows how to handle.
public enum DiskImageKind: Sendable, Equatable {
    /// A file that is a 1:1 map of the guest's disk.
    case raw
    /// Apple Sparse Image Format — a container holding only the blocks in use.
    case asif
    /// A container havm recognises but cannot read. Its byte offsets are not
    /// the guest's and the Virtualization framework cannot boot it, so every
    /// caller must refuse rather than guess.
    case unsupported(UnsupportedDiskImageFormat)
}

/// What an image on disk actually is, as opposed to what its file looks like.
public struct DiskImageInfo: Sendable {
    public let kind: DiskImageKind
    /// The size of the disk the guest sees. For a raw image this is the file's
    /// length; for an ASIF container it is the size recorded inside it, which
    /// the file's length says nothing about.
    public let virtualSize: UInt64
    /// The bytes the image occupies on the host file system.
    public let allocatedSize: UInt64

    public init(kind: DiskImageKind, virtualSize: UInt64, allocatedSize: UInt64) {
        self.kind = kind
        self.virtualSize = virtualSize
        self.allocatedSize = allocatedSize
    }
}

public enum DiskImageError: Error, CustomStringConvertible, Sendable {
    case notAnASIF(URL)
    case resizeUnsupported(URL)
    case resizeFailed(URL, String)
    case attachFailed(URL, String)
    case noDeviceNode(URL)
    case detachFailed(String, String)

    public var description: String {
        switch self {
        case .notAnASIF(let url):
            return "Not an ASIF image: \(url.path)"
        case .resizeUnsupported(let url):
            return "Resizing an ASIF image needs macOS 26 or later: \(url.path)"
        case .resizeFailed(let url, let detail):
            return "Resizing \(url.path) failed: \(detail)"
        case .attachFailed(let url, let detail):
            return "Attaching \(url.path) failed: \(detail)"
        case .noDeviceNode(let url):
            return "Attaching \(url.path) returned no device node"
        case .detachFailed(let device, let detail):
            return "Detaching \(device) failed: \(detail)"
        }
    }
}

/// Reads, resizes and exposes ASIF containers, falling back to `diskutil`
/// where DiskImageKit is unavailable.
public enum DiskImageSupport {
    /// Every ASIF container begins with this magic.
    private static let asifMagic: [UInt8] = [0x73, 0x68, 0x64, 0x77]  // "shdw"

    /// The path to `diskutil`. Fixed: it ships in the OS.
    private static let diskutilPath = "/usr/sbin/diskutil"

    // MARK: - Inspection

    /// The format of the image at `url`, decided by its contents rather than
    /// its extension — an ASIF is still an ASIF when it is called `haos.img`,
    /// and a qcow2 is still a qcow2 when it is called `haos.img` too.
    public static func kind(of url: URL) -> DiskImageKind {
        guard let head = header(at: url) else { return .raw }
        if head.starts(with: asifMagic) { return .asif }
        if let format = foreignFormat(in: head) { return .unsupported(format) }
        return .raw
    }

    /// The first `count` bytes of the file, or nil if it cannot be read.
    private static func header(at url: URL, count: Int = 32) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: count) else { return nil }
        return Array(head)
    }

    /// The container format `head` starts with, if it is one havm cannot read.
    ///
    /// Every magic here is checked against the *contents*: a raw HA OS disk
    /// begins with zeros and a GPT header, so neither can collide with it.
    private static func foreignFormat(in head: [UInt8]) -> UnsupportedDiskImageFormat? {
        func matches(_ magic: [UInt8]) -> Bool {
            head.starts(with: magic)
        }

        // "QFI\xfb" — QCOW versions 1 through 3 all share it.
        if matches([0x51, 0x46, 0x49, 0xfb]) { return .qcow2 }
        if matches(Array("KDMV".utf8)) { return .vmdk }  // VMDK sparse extent
        return nil
    }

    /// Inspect the image at `url`.
    ///
    /// Returns `nil` when the file cannot be read, when it is an ASIF whose
    /// size cannot be determined on this host, or when it is a container havm
    /// cannot read at all — callers must not guess, since a wrong size is how
    /// an image gets truncated.
    public static func info(at url: URL) -> DiskImageInfo? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey]) else {
            return nil
        }
        let fileSize = UInt64(values.fileSize ?? 0)
        let allocated = UInt64(values.fileAllocatedSize ?? values.fileSize ?? 0)

        switch kind(of: url) {
        case .raw:
            return DiskImageInfo(kind: .raw, virtualSize: fileSize, allocatedSize: allocated)
        case .asif:
            guard let virtualSize = asifVirtualSize(at: url) else { return nil }
            return DiskImageInfo(kind: .asif, virtualSize: virtualSize, allocatedSize: allocated)
        case .unsupported:
            return nil
        }
    }

    /// The size recorded inside an ASIF container.
    private static func asifVirtualSize(at url: URL) -> UInt64? {
        if #available(macOS 27.0, *) {
            if let image = try? DiskImageKit.DiskImage(opening: .open(url: url, mode: .readOnly)) {
                return UInt64(image.size)
            }
        }
        return asifInfoPlist(at: url).flatMap { sizeInfo in
            (sizeInfo["Total Bytes"] as? NSNumber)?.uint64Value
        }
    }

    // MARK: - Resize

    /// Grow (or shrink) an ASIF container to `bytes`, leaving the partitions
    /// inside it alone — the guest's own expansion is what fills the disk, the
    /// same contract the `ftruncate` path has for a raw image.
    ///
    /// The image must not be attached or in use.
    public static func resize(_ url: URL, to bytes: UInt64) throws {
        guard kind(of: url) == .asif else { throw DiskImageError.notAnASIF(url) }

        if #available(macOS 27.0, *) {
            do {
                let image = try DiskImageKit.DiskImage(opening: .open(url: url, mode: .readWrite))
                let blockSize = UInt64(image.blockSize.rawValue)
                guard blockSize > 0 else { throw DiskImageError.resizeFailed(url, "unknown block size") }
                try image.truncate(blockCount: Int(bytes / blockSize))
                return
            } catch let error as DiskImageError {
                throw error
            } catch {
                throw DiskImageError.resizeFailed(url, String(describing: error))
            }
        }

        // macOS 26 has no DiskImageKit. `--image-only` keeps diskutil to the
        // container: without it, diskutil also grows the last partition's file
        // system, which is the guest's job.
        guard #available(macOS 26.0, *) else { throw DiskImageError.resizeUnsupported(url) }
        let result = runDiskutil(["image", "resize", "--image-only", "--size", String(bytes), url.path])
        guard result.status == 0 else {
            throw DiskImageError.resizeFailed(url, result.message)
        }
    }

    // MARK: - Block device access

    /// Run `body` against the raw block device for `url`, attaching it first
    /// and detaching it afterwards.
    ///
    /// ASIF containers cannot be patched by seeking in the file, so the one
    /// caller that writes to the guest's disk — the console cmdline patch —
    /// goes through the device instead. The device node belongs to the user
    /// who attached it, so this needs no privileges.
    public static func withBlockDevice(
        _ url: URL,
        readOnly: Bool,
        _ body: (FileHandle) throws -> Void
    ) throws {
        var arguments = ["image", "attach", "--plist", "--noMount"]
        if readOnly { arguments.append("--readOnly") }
        arguments.append(url.path)

        let attach = runDiskutil(arguments)
        guard attach.status == 0 else {
            throw DiskImageError.attachFailed(url, attach.message)
        }
        guard let device = deviceNode(in: attach.stdout) else {
            throw DiskImageError.noDeviceNode(url)
        }

        defer {
            let detach = runDiskutil(["eject", device])
            if detach.status != 0 {
                // Nothing to do but say so: the image stays attached and the
                // next attach will find it busy.
                FileHandle.standardError.write(
                    Data("warning: \(DiskImageError.detachFailed(device, detach.message))\n".utf8)
                )
            }
        }

        let node = URL(fileURLWithPath: "/dev/r\(device)")
        let handle = readOnly ? try FileHandle(forReadingFrom: node) : try FileHandle(forUpdating: node)
        defer { try? handle.close() }
        try body(handle)
    }

    /// The whole-disk `dev-entry` from `diskutil image attach --plist`.
    /// Partition entries (`disk6s1`) are not what we want.
    private static func deviceNode(in plistData: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil
        ) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]] else {
            return nil
        }
        for entity in entities {
            guard let entry = entity["dev-entry"] as? String else { continue }
            // "disk6" yes, "disk6s1" no.
            if entry.hasPrefix("disk"), !entry.dropFirst(4).contains("s") {
                return entry
            }
        }
        return nil
    }

    // MARK: - diskutil

    private struct DiskutilResult {
        let status: Int32
        let stdout: Data
        /// Whatever diskutil said on failure, in one line.
        let message: String
    }

    private static func runDiskutil(_ arguments: [String]) -> DiskutilResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: diskutilPath)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return DiskutilResult(status: -1, stdout: Data(), message: "could not run diskutil: \(error)")
        }
        // Read before waiting: a pipe that fills up would otherwise deadlock.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let message = (String(bytes: errData, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .last
            .map(String.init) ?? "exit status \(process.terminationStatus)"
        return DiskutilResult(status: process.terminationStatus, stdout: outData, message: message)
    }

    /// `diskutil image info --plist`, parsed. Keys are stable identifiers —
    /// diskutil localises its human-readable output but not these.
    private static func asifInfoPlist(at url: URL) -> [String: Any]? {
        guard #available(macOS 26.0, *) else { return nil }
        let result = runDiskutil(["image", "info", "--plist", url.path])
        guard result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(
                from: result.stdout, options: [], format: nil
              ) as? [String: Any] else {
            return nil
        }
        return plist["Size Info"] as? [String: Any]
    }
}
