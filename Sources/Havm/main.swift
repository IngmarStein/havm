import ArgumentParser
import Foundation

/// havm — Home Assistant VM Runner
///
/// Zero-config CLI for running Home Assistant OS on Apple Silicon using
/// Apple's native Virtualization framework. Downloads and sets up HA OS
/// automatically on first run. Designed for headless operation as a
/// launchd service managed via Homebrew.
///
/// Requires macOS 15 or later. USB accessory passthrough requires macOS 27.
struct HavmCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "havm",
        abstract: "Zero-config Home Assistant OS VM runner for Apple Silicon.",
        discussion: """
            Run Home Assistant OS on Apple Silicon using the native \
            Virtualization framework. On first run, automatically downloads \
            the latest HA OS release, decompresses the disk image, and prepares a \
            persistent disk image.

            Designed for headless operation. Use 'havm run' to start the VM \
            in the foreground (ideal for launchd / Homebrew services) or \
            Ctrl+C for graceful shutdown.

            Requires macOS 15 or later with Apple Silicon. USB accessory \
            passthrough requires macOS 27 (Golden Gate) or later.
            """,
        version: HavmVersion.current,
        subcommands: [
            RunCommand.self,
            ImportUTMCommand.self,
            CleanupCommand.self,
            VersionCommand.self,
        ]
    )
}

/// The process entry point, deliberately synchronous.
///
/// ArgumentParser would offer an `async` main that leaves the main thread in
/// `dispatchMain()` once the command suspends. `havm run` cannot use that: it
/// hands the main thread to AppKit's event loop, and a loop entered from inside
/// a main-queue drain never services the main queue again — the dispatch
/// sources the runtime depends on (signals, the boot poll timer, VM state
/// callbacks) would stop firing. Entering the loop from top-level code, before
/// anything has suspended, avoids that.
@main
enum HavmEntry {
    static func main() {
        do {
            var command = try HavmCLI.parseAsRoot(arguments())

            if let run = command as? RunCommand {
                // Never returns: the app loop owns the main thread and the
                // process ends through ServiceRuntime.cleanupAndExit.
                MainActor.assumeIsolated { run.runInApplicationLoop() }
            }

            // `run` is not the only asynchronous command, and a command reached
            // through `any ParsableCommand` would dispatch to the protocol's
            // default *synchronous* `run()`, which only prints help. Route the
            // async ones explicitly.
            if let asyncCommand = command as? any AsyncParsableCommand {
                runAsyncCommand(asyncCommand)
            }

            try command.run()
        } catch {
            HavmCLI.exit(withError: error)
        }
    }

    /// The command line, with one addition: a launch from Finder carries no
    /// arguments at all, and printing help into a console nobody can see would
    /// flash the app in the Dock and exit. Double-clicking `Havm.app` means
    /// "run"; `havm` with no arguments in a terminal still means "show help".
    ///
    /// The two are told apart by the parent process — LaunchServices starts an
    /// app from `launchd` (pid 1), while a terminal run is a child of the shell.
    /// Returns the arguments without the executable path, which is what
    /// `parseAsRoot(_:)` expects when it is handed an array.
    private static func arguments() -> [String] {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.isEmpty, getppid() == 1 else { return arguments }
        return ["run"]
    }

    /// Runs an asynchronous command from the synchronous entry point.
    ///
    /// The command ends the process itself, so `dispatchMain()` only has to
    /// keep the main thread servicing the main queue for the command's
    /// continuations.
    private static func runAsyncCommand(_ command: sending any AsyncParsableCommand) -> Never {
        Task {
            var command = command
            do {
                try await command.run()
                exit(0)
            } catch {
                HavmCLI.exit(withError: error)
            }
        }
        dispatchMain()
    }
}

enum HavmVersion {
    static let current = "1.0.7"
}
