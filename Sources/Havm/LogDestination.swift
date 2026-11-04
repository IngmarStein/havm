import Foundation
import Logging

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
    /// Returns `nil` when the file cannot be opened; the caller then keeps
    /// logging to stdout rather than failing to start over a log path.
    static func openFile(at path: String, maxBytes: Int = 5 * 1024 * 1024) -> FileHandle? {
        let url = URL(fileURLWithPath: path)
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let attributes = try? manager.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int, size > maxBytes {
            let rotated = url.appendingPathExtension("1")
            try? manager.removeItem(at: rotated)
            try? manager.moveItem(at: url, to: rotated)
        }
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }
}

/// A `TextOutputStream` over an open file, so swift-log's `StreamLogHandler`
/// can write to it.
struct FileLogStream: TextOutputStream, Sendable {
    let handle: FileHandle

    mutating func write(_ string: String) {
        try? handle.write(contentsOf: Data(string.utf8))
    }
}
