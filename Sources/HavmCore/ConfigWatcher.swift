import Foundation
import Logging

/// Watches the config file for changes, by both routes it can change.
///
/// A file watcher alone misses an atomic save: an editor writes a temp file
/// and renames it over the path, so the descriptor is left pointing at the old
/// inode and never fires again. A directory watcher alone misses an in-place
/// write, which changes no directory entry. Both are armed, and the directory
/// watcher re-arms the file watcher after a rename.
final class ConfigWatcher {
    private let path: String
    private let logger: Logger
    private let onChange: () -> Void

    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?

    /// - Parameters:
    ///   - path: the config file to watch. Its directory is watched too.
    ///   - onChange: called on the main queue when the file changes. One save
    ///     can report more than once — the caller must be idempotent.
    init(path: String, logger: Logger, onChange: @escaping () -> Void) {
        self.path = path
        self.logger = logger
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// Arm both watchers.
    func start() {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path

        let dirFD = open(directory, O_EVTONLY)
        guard dirFD >= 0 else {
            logger.debug("Config watcher: cannot open \(directory)")
            return
        }
        let dirSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD, eventMask: .write, queue: .main
        )
        dirSource.setEventHandler { [weak self] in
            guard let self else { return }
            // A rename can land before the new file exists; the next event
            // catches that case.
            guard FileManager.default.fileExists(atPath: self.path) else { return }
            self.onChange()
            self.restartFileWatcher()  // atomic save → new inode
        }
        // Capture `dirFD` by value so `deinit` cancelling the source closes
        // the descriptor even after `self` is nil.
        dirSource.setCancelHandler { close(dirFD) }
        dirSource.resume()
        directoryWatcher = dirSource

        restartFileWatcher()
    }

    /// Cancel both watchers and close their descriptors.
    func stop() {
        directoryWatcher?.cancel()
        directoryWatcher = nil
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    private func restartFileWatcher() {
        fileWatcher?.cancel()
        fileWatcher = nil
        let fileFD = open(path, O_EVTONLY)
        guard fileFD >= 0 else { return }
        let fileSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileFD, eventMask: [.write, .extend], queue: .main
        )
        fileSource.setEventHandler { [weak self] in
            self?.onChange()
        }
        fileSource.setCancelHandler { close(fileFD) }
        fileSource.resume()
        fileWatcher = fileSource
    }
}
