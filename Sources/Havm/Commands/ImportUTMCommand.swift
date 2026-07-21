import ArgumentParser
import Foundation
import HavmCore

struct ImportUTMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-utm",
        abstract: "Import a Home Assistant VM from UTM into havm."
    )

    @Argument(help: "Path to the .utm bundle directory.")
    var path: String

    @Flag(name: [.long, .customShort("f")],
          help: "Overwrite existing VM data if present.")
    var force: Bool = false

    @Option(name: [.customShort("d"), .long],
            help: "Data directory for persistent VM data (default: ~/Library/Application Support/havm/).")
    var dataDir: String?

    func run() async throws {
        // 0. Set data directory override before anything touches the file system.
        if let dir = dataDir {
            HavmConfig.dataDirectoryOverride = dir
        }

        // 1. Parse the UTM bundle
        print("==> Parsing UTM bundle at \(path)...")
        let bundle: UTMBundle
        do {
            bundle = try UTMBundle(path: path)
        } catch {
            fputs("Error: \(error)\n", stderr)
            throw ExitCode.failure
        }

        print("    Name:           \(bundle.name)")
        print("    CPU:            \(bundle.cpuCount)")
        print("    Memory:         \(bundle.memorySizeMB) MB")
        print("    Drives:         \(bundle.drives.count)")
        for drive in bundle.drives {
            let flags = [
                drive.isNVMe ? "NVMe" : nil,
                drive.isReadOnly ? "read-only" : nil
            ].compactMap { $0 }.joined(separator: ", ")
            print("      - \(drive.imageName)\(flags.isEmpty ? "" : " (\(flags))")")
        }

        // 2. Identify the main disk
        guard let mainDisk = bundle.mainDisk else {
            fputs("Error: \(UTMImportError.noSuitableDisk)\n", stderr)
            throw ExitCode.failure
        }
        print("    Main disk:      \(mainDisk.imageName)")

        // 3. Safety checks
        print("")
        print("==> Checking prerequisites...")

        let fileManager = FileManager.default
        let vmDir = HavmConfig.vmDirectory
        try fileManager.createDirectory(atPath: vmDir, withIntermediateDirectories: true)

        let targetDiskPath = HavmConfig.persistentDiskPath
        if fileManager.fileExists(atPath: targetDiskPath) {
            guard force else {
                fputs("Error: \(UTMImportError.existingVMData(vmDir))\n", stderr)
                throw ExitCode.failure
            }
            print("    ⚠️  Overwriting existing VM data (--force)")
        }

        // Warn about auxiliary disks
        let auxDisks = bundle.auxiliaryDisks
        if !auxDisks.isEmpty {
            print("")
            print("    ⚠️  Additional disks found that will NOT be imported:")
            for disk in auxDisks {
                print("       - \(disk.imageName)")
            }
            print("    These may contain Home Assistant data or configuration.")
            print("    If you need their contents, copy them manually after import.")
        }

        // 4. Copy main disk
        print("")
        print("==> Copying main disk image...")
        let sourceDiskURL = bundle.resolveURL(mainDisk.imageName)
        try copyFile(from: sourceDiskURL, to: URL(fileURLWithPath: targetDiskPath), description: "Disk image")

        // 5. Copy EFI variable store
        if let efiURL = bundle.efiVarsURL {
            print("==> Importing EFI variable store...")
            let nvramPath = HavmConfig.nvramPath
            // Remove existing NVRAM if force
            if fileManager.fileExists(atPath: nvramPath) {
                try fileManager.removeItem(atPath: nvramPath)
            }
            try copyFile(from: efiURL, to: URL(fileURLWithPath: nvramPath), description: "NVRAM")
        } else {
            print("==> No EFI variable store found — a fresh one will be created on first boot.")
        }

        // 6. Write machine identifier
        if let machineID = bundle.machineIdentifierData {
            print("==> Importing machine identifier...")
            try machineID.write(to: URL(fileURLWithPath: HavmConfig.machineIdentifierPath))
        } else {
            print("==> No machine identifier found — a new one will be generated on first boot.")
        }

        // 7. Write MAC address
        if let firstNet = bundle.networks.first, let mac = firstNet.macAddress {
            print("==> Importing MAC address...")
            try mac.write(toFile: HavmConfig.macAddressPath, atomically: true, encoding: .utf8)
        }

        // 8. Generate config
        print("")
        print("==> Generating havm config...")
        try generateConfig(from: bundle)

        // 9. Summary
        print("")
        print("✅ Import complete.")
        print("")
        print("  VM data:  \(vmDir)")
        print("  Config:   \(HavmConfig.defaultConfigPath)")
        print("")
        print("  Run 'havm run' to start the VM.")
        print("")
        if !auxDisks.isEmpty {
            print("  ⚠️  Reminder: auxiliary disks were not imported:")
            for disk in auxDisks {
                print("     \(bundle.resolveURL(disk.imageName).path)")
            }
            print("")
        }
        print("  💡 If you had SSH keys configured in UTM, add them to havm config:")
        print("       ssh:")
        print("         authorized_keys: ~/.ssh/id_ed25519.pub")
        print("")
    }

    // MARK: - Helpers

    /// Copy a file, preserving APFS sparseness. Uses `clonefile(2)` for
    /// same-volume instant clones; falls back to a sparse-aware copy that
    /// skips zero-filled blocks so holes aren't materialized.
    private func copyFile(from source: URL, to destination: URL, description: String) throws {
        let fileManager = FileManager.default

        // Remove existing if present
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(atPath: destination.path)
        }

        let sourceSize = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

        // Ensure destination directory exists
        let dir = destination.deletingLastPathComponent().path
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Try clonefile first — instant on same APFS volume, preserves sparseness.
        if clonefile(source.path, destination.path, 0) == 0 {
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(sourceSize), countStyle: .file)
            print("    Cloned \(description) (\(sizeStr), sparse)")
            return
        }

        // Fall back to sparse-aware copy for cross-volume scenarios.
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(sourceSize), countStyle: .file)
        print("    Copying \(description) (\(sizeStr), sparse-aware)...")

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        // Pre-allocate the destination to the full logical size.
        // APFS will hole-punch regions we never write to.
        fileManager.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.seek(toOffset: UInt64(sourceSize - 1))
        try output.write(contentsOf: Data([0]))

        let chunkSize = 1_048_576
        var offset: UInt64 = 0
        var totalRead = 0
        var lastProgress = 0
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            // Only write non-zero chunks to preserve sparseness
            if !chunk.allSatisfy({ $0 == 0 }) {
                try output.seek(toOffset: offset)
                try output.write(contentsOf: chunk)
            }
            offset += UInt64(chunk.count)
            totalRead += chunk.count
            let pct = totalRead * 100 / sourceSize
            if pct - lastProgress >= 5 {
                print("    Progress: \(pct)%")
                lastProgress = pct
            }
        }
        try output.synchronize()
    }

    /// Generate a havm config file reflecting the imported VM's settings.
    /// If a config already exists, prints the recommended settings instead of overwriting.
    private func generateConfig(from bundle: UTMBundle) throws {
        let configPath = HavmConfig.defaultConfigPath
        let configDir = URL(fileURLWithPath: configPath).deletingLastPathComponent().path

        // Build the config content
        var lines: [String] = [
            "# Generated by 'havm import-utm' from \(bundle.name)",
            "",
            "vm:",
            "  cpu_count: \(bundle.cpuCount)",
            "  memory_size: \"\(bundle.memorySizeMB) MiB\"",
            "",
        ]

        if let firstNet = bundle.networks.first {
            let networkType = networkType(from: firstNet.mode)
            lines.append("network:")
            lines.append("  type: \(networkType)")
            if let iface = firstNet.bridgeInterface, networkType == "bridge" {
                lines.append("  interface: \(iface)")
            }
            if let mac = firstNet.macAddress {
                lines.append("  mac: \"\(mac)\"")
            }
            lines.append("")
        }

        let configContent = lines.joined(separator: "\n")

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: configPath) {
            print("    ⚠️  Existing config found — add these settings manually if needed:")
            print("    ---")
            for line in lines {
                print("    \(line)")
            }
            print("    ---")
        } else {
            try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            try configContent.write(toFile: configPath, atomically: true, encoding: .utf8)
            print("    Wrote \(configPath)")
        }
    }

    private func networkType(from utmMode: String) -> String {
        switch utmMode.lowercased() {
        case "bridged": return "bridge"
        case "shared":  return "nat"
        default:        return "nat"
        }
    }
}
