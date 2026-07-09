import ArgumentParser

/// havm — Home Assistant VM Runner
///
/// Zero-config CLI for running Home Assistant OS on Apple Silicon using
/// Apple's native Virtualization framework. Downloads and sets up HA OS
/// automatically on first run. Designed for headless operation as a
/// launchd service managed via Homebrew.
///
/// Requires macOS 27 (Golden Gate) or later.
@main
struct HavmCLI: AsyncParsableCommand {
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

            Requires macOS 27 (Golden Gate) or later with Apple Silicon.
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

enum HavmVersion {
    static let current = "0.2.2"
}
