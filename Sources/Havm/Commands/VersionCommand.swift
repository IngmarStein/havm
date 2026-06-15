import ArgumentParser
import Foundation

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print version information."
    )

    func run() throws {
        print("havm \(HavmVersion.current)")
        print("  macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }
}
