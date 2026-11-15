import Foundation
import Logging

/// An exclusive lock on a havm data directory, held for as long as the process
/// that took it runs.
///
/// The lock is `flock(2)` on an open descriptor, not the existence of a file.
/// The kernel releases it when the process dies — by crash, `SIGKILL`, or
/// panic — so there is no stale state to recover from and nothing for a user to
/// delete: the next start takes the lock immediately. That is the whole reason
/// this is not a pid file that is created on start and removed on exit.
///
/// The file is deliberately never unlinked. Removing it while holding the lock
/// lets another process create a new file and lock that, and two processes
/// would each believe they hold it. A leftover zero-byte `.lock` costs nothing;
/// a lock that two processes hold costs a disk.
public final class InstanceLock {

    public enum LockError: Error, CustomStringConvertible {
        /// Another process holds the lock. `pid` is the one it wrote, when it
        /// could be read.
        case held(path: String, pid: pid_t?)
        case cannotOpen(path: String, code: Int32)

        public var description: String {
            switch self {
            case .held(let path, let pid):
                let holder = pid.map { " (pid \($0))" } ?? ""
                let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
                    .deletingLastPathComponent().path
                return "Another havm is using \(directory)\(holder). "
                    + "Stop it first, or pass a different --data-dir."
            case .cannotOpen(let path, let code):
                return "Cannot open the instance lock at \(path): \(String(cString: strerror(code)))"
            }
        }
    }

    /// The lock file, for log lines. It stays on disk after the lock is
    /// released.
    public let path: String
    private let fd: Int32

    private init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    deinit {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }

    // MARK: - Taking the lock

    /// Take the lock at `path`, creating the file and its directory if needed.
    ///
    /// Throws ``LockError/held(path:pid:)`` when another process holds it.
    /// A file system that cannot lock at all — a network volume — yields a
    /// lock that holds nothing, with a warning rather than a refusal to start:
    /// this guards against an accident, and a filesystem quirk is not a reason
    /// to keep a guest down.
    public static func acquire(at path: String, logger: Logger) throws -> InstanceLock {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        // O_CLOEXEC: the lock must not be inherited by `ssh` or `diskutil`
        // children, which would otherwise hold it after havm exits.
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LockError.cannotOpen(path: path, code: errno) }

        guard flock(fd, LOCK_EX | LOCK_NB) != 0 else {
            writePID(fd)
            return InstanceLock(fd: fd, path: path)
        }

        let code = errno
        guard code == EWOULDBLOCK else {
            // ENOTSUP / ENOLCK: the file system does not lock.
            let reason = String(cString: strerror(code))
            logger.warning(
                "Instance lock unavailable at \(path) — \(reason). Two havm processes on this data directory could corrupt the disk."
            )
            return InstanceLock(fd: fd, path: path)
        }

        let holder = readPID(fd)
        close(fd)
        throw LockError.held(path: path, pid: holder)
    }

    /// Take the lock and hold it for the rest of the process.
    ///
    /// Static storage, not a local: a local would be released at its last use,
    /// which is not the same as the end of the process.
    public static func holdForProcess(at path: String, logger: Logger) throws {
        processLock = try acquire(at: path, logger: logger)
    }

    nonisolated(unsafe) private static var processLock: InstanceLock?

    // MARK: - The pid in the file

    /// The pid the holder wrote. It is a courtesy for the error message, not
    /// the lock: it is only read after the lock was refused, when the holder
    /// was alive a moment ago.
    private static func readPID(_ fd: Int32) -> pid_t? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0,
              let text = String(bytes: buffer[0..<Int(count)], encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func writePID(_ fd: Int32) {
        _ = ftruncate(fd, 0)
        let text = Array("\(getpid())\n".utf8)
        _ = pwrite(fd, text, text.count, 0)
    }
}
