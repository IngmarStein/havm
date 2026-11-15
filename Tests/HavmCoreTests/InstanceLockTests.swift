import Foundation
import Logging
import Testing
@testable import HavmCore

/// The lock that keeps two havm processes off one data directory.
///
/// The property worth testing is the one a lockfile cannot have: when the
/// holder goes away without cleaning up — which is every crash — the lock is
/// free again. `flock` gives that for nothing, because the kernel drops it with
/// the process; these tests pin it so a future implementation cannot quietly
/// go back to "the file exists, so someone is running".
@Suite struct InstanceLockTests {

    private static let logger = Logger(label: "havm.tests.lock")

    private func makePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("havm-lock-\(UUID().uuidString)")
            .appendingPathComponent("vm/.lock")
            .path
    }

    @Test func aSecondHolderIsRefused() throws {
        let path = makePath()
        let first = try InstanceLock.acquire(at: path, logger: Self.logger)
        defer { _ = first }

        #expect(throws: InstanceLock.LockError.self) {
            _ = try InstanceLock.acquire(at: path, logger: Self.logger)
        }
    }

    /// The refusal names the holder, which is what turns "already running" into
    /// something the user can act on.
    @Test func theRefusalNamesTheHolderPID() throws {
        let path = makePath()
        let first = try InstanceLock.acquire(at: path, logger: Self.logger)
        defer { _ = first }

        do {
            _ = try InstanceLock.acquire(at: path, logger: Self.logger)
            Issue.record("the second acquire should have been refused")
        } catch let InstanceLock.LockError.held(_, pid) {
            #expect(pid == getpid())
        }
    }

    /// Releasing is dropping the holder — no `unlock` call, no file removal,
    /// which is what makes a crash equivalent to a clean exit here.
    @Test func theLockIsFreeOnceTheHolderIsGone() throws {
        let path = makePath()
        var first: InstanceLock? = try InstanceLock.acquire(at: path, logger: Self.logger)
        #expect(throws: InstanceLock.LockError.self) {
            _ = try InstanceLock.acquire(at: path, logger: Self.logger)
        }

        first = nil
        let second = try InstanceLock.acquire(at: path, logger: Self.logger)
        #expect(second.path == path)
        _ = second
    }

    /// The file outlives the lock on purpose: unlinking it would let a third
    /// process create a new inode and lock that, and two holders would each
    /// think they had it.
    @Test func theFileIsLeftBehind() throws {
        let path = makePath()
        do {
            let lock = try InstanceLock.acquire(at: path, logger: Self.logger)
            #expect(FileManager.default.fileExists(atPath: lock.path))
        }
        #expect(FileManager.default.fileExists(atPath: path), "the lock file must survive the holder")
    }

    @Test func createsTheDirectoryItLivesIn() throws {
        let path = makePath()
        let lock = try InstanceLock.acquire(at: path, logger: Self.logger)
        #expect(FileManager.default.fileExists(atPath: path))
        _ = lock
    }
}
