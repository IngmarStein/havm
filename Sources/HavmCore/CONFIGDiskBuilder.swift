import Foundation

// MARK: - CONFIG Disk Builder

/// Builds a minimal FAT16 disk image with volume label "CONFIG" and an
/// `authorized_keys` file. Home Assistant OS auto-imports SSH keys from
/// any attached disk with a partition/filesystem labeled "CONFIG" on boot.
enum CONFIGDiskBuilder {

    /// Create a minimal FAT16 disk image containing an authorized_keys file.
    /// - Parameter keyData: The SSH public key text (one key per line, LF-separated).
    /// - Returns: Raw disk image data (FAT16, volume label "CONFIG").
    static func build(authorizedKey keyData: Data) -> Data {
        let diskSize = 2 * 1024 * 1024  // 2 MB (plenty for a single key file)
        let sectorSize = 512
        let totalSectors = diskSize / sectorSize
        let spc = 4  // sectors per cluster

        // Compute FAT parameters
        let reservedSectors = 1
        let fatCount = 2
        let rootEntries = 512
        let rootDirSectors = (rootEntries * 32 + sectorSize - 1) / sectorSize  // 32
        // Compute FAT size: each entry is 2 bytes, need entries for all clusters
        let clusters = (totalSectors - reservedSectors - rootDirSectors) / spc
        let fatSectors = max(1, (clusters * 2 + sectorSize - 1) / sectorSize)
        let sectorsPerFAT = UInt16(fatSectors)

        var data = Data(count: diskSize)

        // --- Boot Sector (FAT16 BPB) ---
        writeBootSector(&data,
            totalSectors: UInt16(totalSectors),
            spc: UInt8(spc),
            reservedSectors: UInt16(reservedSectors),
            fatCount: UInt8(fatCount),
            rootEntries: UInt16(rootEntries),
            sectorsPerFAT: sectorsPerFAT,
            volumeLabel: "CONFIG"
        )

        // --- FAT tables (offset: reservedSectors * sectorSize) ---
        let fatOffset = reservedSectors * sectorSize
        writeFAT16Tables(&data, fatOffset: fatOffset, fatCount: fatCount, fatSectors: fatSectors)

        // --- Root directory (offset: fatOffset + fatCount * fatSectors * sectorSize) ---
        let rootDirOffset = fatOffset + Int(fatCount) * Int(fatSectors) * sectorSize

        // Entry 1: Volume label "CONFIG"
        writeVolumeLabelEntry(&data, rootDirOffset, label: "CONFIG")

        // Entry 2: "AUTHORIZED KEYS" file (8.3: AUTHO~1.KEY, but let's use AUTHKEYS.)
        // Actually, "authorized_keys" doesn't fit 8.3. Let's use "AUTHKEYS.KEY"
        let fileSize = UInt32(keyData.count)
        writeDirectoryEntry(&data, offset: rootDirOffset + 32,
                            name: "AUTHKEYS", ext: "KEY",
                            cluster: 2, fileSize: fileSize)

        // --- Data region: cluster 2 = authorized_keys content ---
        let dataRegionOffset = rootDirOffset + rootDirSectors * sectorSize
        let cluster2Offset = dataRegionOffset  // cluster 2 = first data cluster
        data[cluster2Offset..<(cluster2Offset + keyData.count)] = keyData

        return data
    }

    // MARK: - Boot Sector

    private static func writeBootSector(_ data: inout Data,
                                         totalSectors: UInt16,
                                         spc: UInt8,
                                         reservedSectors: UInt16,
                                         fatCount: UInt8,
                                         rootEntries: UInt16,
                                         sectorsPerFAT: UInt16,
                                         volumeLabel: String) {
        // Jump instruction
        data[0] = 0xEB; data[1] = 0x3C; data[2] = 0x90
        // OEM name
        writeString(&data, offset: 3, text: "mkfs.fat", maxLen: 8)
        // BPB
        writeLE16(&data, offset: 11, value: 512)      // bytes per sector
        data[13] = spc                                  // sectors per cluster
        writeLE16(&data, offset: 14, value: reservedSectors)  // reserved sectors
        data[16] = fatCount                             // number of FATs
        writeLE16(&data, offset: 17, value: rootEntries)     // root entries
        writeLE16(&data, offset: 19, value: totalSectors)    // total sectors (16-bit)
        data[21] = 0xF8                                 // media descriptor (hard disk)
        writeLE16(&data, offset: 22, value: sectorsPerFAT)   // sectors per FAT
        writeLE16(&data, offset: 24, value: 32)         // sectors per track
        writeLE16(&data, offset: 26, value: 64)         // number of heads
        writeLE32(&data, offset: 28, value: 0)          // hidden sectors
        writeLE32(&data, offset: 32, value: 0)          // total sectors (32-bit, 0 = use 16-bit)

        // Extended BPB
        data[36] = 0x80                                 // physical drive number
        data[37] = 0x00                                 // reserved
        data[38] = 0x29                                 // extended boot signature
        writeLE32(&data, offset: 39, value: 0x12345678) // volume serial number
        writeString(&data, offset: 43, text: volumeLabel, maxLen: 11, padChar: 0x20)
        writeString(&data, offset: 54, text: "FAT16   ", maxLen: 8)

        // Boot signature
        data[510] = 0x55; data[511] = 0xAA
    }

    // MARK: - FAT Tables

    private static func writeFAT16Tables(_ data: inout Data, fatOffset: Int, fatCount: Int, fatSectors: Int) {
        for fatIdx in 0..<fatCount {
            let offset = fatOffset + fatIdx * fatSectors * 512
            // Entry 0: media descriptor
            data[offset] = 0xF8; data[offset + 1] = 0xFF
            // Entry 1: end-of-chain
            data[offset + 2] = 0xFF; data[offset + 3] = 0xFF
            // Entry 2: end-of-chain (our authorized_keys file uses 1 cluster)
            data[offset + 4] = 0xFF; data[offset + 5] = 0xFF
        }
    }

    // MARK: - Directory Entries

    private static func writeVolumeLabelEntry(_ data: inout Data, _ offset: Int, label: String) {
        writeString(&data, offset: offset, text: label, maxLen: 11, padChar: 0x20)
        data[offset + 11] = 0x08  // volume label attribute
    }

    private static func writeDirectoryEntry(_ data: inout Data, offset: Int,
                                             name: String, ext: String,
                                             cluster: Int, fileSize: UInt32) {
        writeString(&data, offset: offset, text: name, maxLen: 8, padChar: 0x20)
        writeString(&data, offset: offset + 8, text: ext, maxLen: 3, padChar: 0x20)
        data[offset + 11] = 0x00  // no special attributes
        writeLE16(&data, offset: 20, value: 0)           // cluster high (FAT16: always 0)
        writeLE16(&data, offset: 26, value: UInt16(cluster)) // cluster low
        writeLE32(&data, offset: 28, value: fileSize)
    }

    // MARK: - LE Helpers

    private static func writeLE16(_ data: inout Data, offset: Int, value: UInt16) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private static func writeLE32(_ data: inout Data, offset: Int, value: UInt32) {
        for i in 0..<4 {
            data[offset + i] = UInt8((value >> (i * 8)) & 0xFF)
        }
    }

    private static func writeString(_ data: inout Data, offset: Int, text: String, maxLen: Int, padChar: UInt8 = 0x00) {
        let bytes = Array(text.utf8)
        for i in 0..<maxLen {
            data[offset + i] = i < bytes.count ? bytes[i] : padChar
        }
    }
}
