import Darwin
import Foundation
import Logging
import Synchronization

/// Opening the file `logging.file` names.
///
/// It exists for the launches that have nowhere to put a log: from Finder,
/// `open`, or a login item the system points stdout at `/dev/null`, so every
/// line — boot progress, the guest's address, shutdown failures — is discarded.
/// A terminal, a pipe and launchd's `StandardOutPath` all leave stdout
/// somewhere real and need nothing from this file.
enum LogDestination {
    /// Opens `path` for appending, creating the file and any missing
    /// directories, and rotating a file that has grown past `maxBytes` to
    /// `<path>.1` first.
    ///
    /// Opens with `O_APPEND | O_NOFOLLOW | O_CLOEXEC` and mode `0o600` so
    /// concurrent writes never overwrite one another, symlinks are not
    /// followed, and child processes do not inherit the log descriptor.
    ///
    /// Returns `nil` when the file cannot be opened; the caller then keeps
    /// logging to stdout/stderr rather than failing to start over a log path.
    static func openFile(at path: String, maxBytes: Int = 5 * 1024 * 1024) -> FileHandle? {
        let url = URL(fileURLWithPath: path)
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Only rotate a real regular file (not a symlink).
        if let attributes = try? manager.attributesOfItem(atPath: url.path),
           (attributes[.type] as? FileAttributeType) == .typeRegular,
           let size = attributes[.size] as? Int, size > maxBytes {
            let rotated = url.appendingPathExtension("1")
            if let rotAttrs = try? manager.attributesOfItem(atPath: rotated.path),
               (rotAttrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                return nil
            }
            try? manager.removeItem(at: rotated)
            try? manager.moveItem(at: url, to: rotated)
        }
        let fd = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

/// A thread-safe `TextOutputStream` over an open file, so swift-log's
/// `StreamLogHandler` can write to it from any thread without interleaving.
struct FileLogStream: TextOutputStream, Sendable {
    private static let writeLock = Mutex<Void>(())
    let handle: FileHandle

    mutating func write(_ string: String) {
        let data = Data(string.utf8)
        Self.writeLock.withLock { _ in
            try? handle.write(contentsOf: data)
        }
    }
}
