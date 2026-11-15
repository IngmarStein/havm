import Foundation
import Logging

/// The pid file external tooling reads to find a running havm.
///
/// It is a record, not a lock: a process that died without cleaning up leaves
/// the file behind, and nothing treats its existence as evidence that havm is
/// running. Anything that needs to know that has to check the process, and
/// anything that needs to keep two instances apart needs a lock.
enum PIDFile {
    /// Write the current pid, creating the directory if needed. A failure is
    /// a warning: the guest runs either way, and only the tooling that reads
    /// the file is affected.
    static func write(at path: String, logger: Logger) {
        do {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try "\(getpid())\n".write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            logger.warning("PID file write failed (\(path)): \(error)")
        }
    }

    static func remove(at path: String, logger: Logger) {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            logger.debug("PID file remove failed: \(error)")
        }
    }
}
