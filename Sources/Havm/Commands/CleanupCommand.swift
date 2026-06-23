import ArgumentParser
import Foundation
import HavmCore

struct CleanupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Clear cached HA OS downloads from ~/Library/Caches/havm/."
    )

    func run() throws {
        let cacheDir = HavmConfig.cacheDirectory
        guard FileManager.default.fileExists(atPath: cacheDir) else {
            print("No cache directory found at \(cacheDir)")
            return
        }
        do {
            try FileManager.default.removeItem(atPath: cacheDir)
            print("Removed \(cacheDir)")
        } catch {
            print("Failed to remove cache: \(error.localizedDescription)")
            throw error
        }
    }
}
