import ArgumentParser
import Foundation
import HavmCore

struct CleanupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Remove cache files and optionally VM data."
    )

    @Flag(name: [.long, .customShort("a")],
          help: "Remove all VM data (disk images, NVRAM, machine ID) in addition to caches.")
    var all: Bool = false

    @Option(name: [.customShort("c"), .long],
            help: "Path to the config file (default: ~/.config/havm/config.yml).")
    var config: String?

    @Option(name: [.customShort("d"), .long],
            help: "Data directory holding persistent VM data (default: ~/Library/Application Support/havm/).")
    var dataDir: String?

    func run() throws {
        let fileManager = FileManager.default

        // Set before anything reads a path: the cache is shared, but the VM
        // data lives wherever this run was pointed.
        if let dataDir {
            HavmConfig.dataDirectoryOverride = dataDir
        }

        // Always remove the cache directory.
        let cacheDir = HavmConfig.cacheDirectory
        if fileManager.fileExists(atPath: cacheDir) {
            try fileManager.removeItem(atPath: cacheDir)
            print("Removed \(cacheDir)")
        } else {
            print("No cache directory at \(cacheDir)")
        }

        // With --all, also remove persistent VM data.
        if all {
            let dataDir = HavmConfig.dataDirectory
            let configPath = config.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                ?? HavmConfig.defaultConfigPath

            print("")
            print("The following will be removed:")
            if fileManager.fileExists(atPath: dataDir) {
                print("  \(dataDir)")
            }
            if fileManager.fileExists(atPath: configPath) {
                print("  \(configPath)")
            }
            print("")

            if !confirm("Remove all havm data? This cannot be undone.") {
                print("Cancelled.")
                return
            }

            if fileManager.fileExists(atPath: dataDir) {
                try fileManager.removeItem(atPath: dataDir)
                print("Removed \(dataDir)")
            }
            if fileManager.fileExists(atPath: configPath) {
                try fileManager.removeItem(atPath: configPath)
                print("Removed \(configPath)")
            }
            print("All havm data removed.")
        }
    }

    private func confirm(_ prompt: String) -> Bool {
        print("\(prompt) [y/N] ", terminator: "")
        guard let response = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return false
        }
        return response == "y" || response == "yes"
    }
}
