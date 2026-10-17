import Foundation

// MARK: - CONFIG Disk Builder

/// Builds a minimal MBR + FAT16 disk image with volume label "CONFIG" and an
/// `authorized_keys` file. Home Assistant OS auto-imports SSH keys from
/// any attached disk with an MBR partition labeled "CONFIG" on boot.
enum CONFIGDiskBuilder {

    /// Create an MBR + FAT16 disk image containing an authorized_keys file.
    /// - Parameter keyData: The SSH public key text (one key per line, LF-separated).
    /// - Returns: Raw disk image data (MBR + FAT16 partition, volume label "CONFIG").
    static func build(authorizedKey keyData: Data) -> Data {
        // 2 MB disk size — Data(count: 67108864) crashes the process on
        // macOS 27, so we use a minimal allocation. HA OS only needs a
        // few hundred bytes for authorized_keys, so 2 MB is plenty.
        let diskSize = 2 * 1024 * 1024  // 2 MB
        let sectorSize = 512
        let mbrSectors = 1

        // FAT16 filesystem (occupies all sectors after MBR)
        let fsTotalSectors = diskSize / sectorSize - mbrSectors
        let spc = 4
        let reservedSectors = 1
        let fatCount = 2
        let rootEntries = 512
        let rootDirSectors = (rootEntries * 32 + sectorSize - 1) / sectorSize
        let clusters = (fsTotalSectors - reservedSectors - rootDirSectors) / spc
        let fatSectors = max(1, (clusters * 2 + sectorSize - 1) / sectorSize)
        let sectorsPerFAT = UInt16(fatSectors)

        var data = Data(count: diskSize)
        let fsOffset = mbrSectors * sectorSize  // FAT starts at offset 512

        // --- Sector 0: MBR with one FAT16 LBA partition ---
        writeMBR(&data, fsTotalSectors: UInt16(fsTotalSectors))

        // --- Sector 1: FAT16 Boot Sector ---
        writeBootSector(&data,
            at: fsOffset,
            totalSectors: UInt16(fsTotalSectors),
            spc: UInt8(spc),
            reservedSectors: UInt16(reservedSectors),
            fatCount: UInt8(fatCount),
            rootEntries: UInt16(rootEntries),
            sectorsPerFAT: sectorsPerFAT,
            volumeLabel: "CONFIG")

        // --- FAT tables ---
        let fatOffset = fsOffset + reservedSectors * sectorSize
        writeFAT16Tables(&data, fatOffset: fatOffset, fatCount: fatCount, fatSectors: fatSectors)

        // --- Root directory ---
        let rootDirOffset = fatOffset + Int(fatCount) * Int(fatSectors) * sectorSize

        // Entry 1: Volume label "CONFIG"
        writeVolumeLabelEntry(&data, rootDirOffset, label: "CONFIG")

        // Entry 2+: VFAT LFN + 8.3 for "authorized_keys"
        let longName = "authorized_keys"
        let shortName = "AUTHKE~1"
        let shortExt = "KEY"
        let fileSize = UInt32(keyData.count)
        let utf16 = Array(longName.utf16)
        let lfnSlots = (utf16.count + 12) / 13

        for slot in 0..<lfnSlots {
            let entryOff = rootDirOffset + 32 + (lfnSlots - 1 - slot) * 32
            data[entryOff] = UInt8(slot + 1) | (slot == lfnSlots - 1 ? 0x40 : 0)

            var ci = slot * 13
            let fields: [(offset: Int, count: Int)] = [(1, 5), (14, 6), (28, 2)]
            for (fieldOffset, count) in fields {
                for i in 0..<count {
                    let p = entryOff + fieldOffset + i * 2
                    if ci < utf16.count       { data[p] = UInt8(utf16[ci] & 0xFF); data[p+1] = UInt8((utf16[ci] >> 8) & 0xFF); ci += 1 }
                    else if ci == utf16.count  { data[p] = 0; data[p+1] = 0; ci += 1 }
                    else                       { data[p] = 0xFF; data[p+1] = 0xFF }
                }
            }

            data[entryOff + 11] = 0x0F; data[entryOff + 12] = 0x00
            data[entryOff + 26] = 0x00; data[entryOff + 27] = 0x00

            var cs: UInt8 = 0
            var sn = Array(shortName.utf8) + Array(shortExt.utf8)
            while sn.count < 11 { sn.append(0x20) }
            for b in sn { cs = ((cs & 1) << 7) &+ (cs >> 1) &+ b }
            data[entryOff + 13] = cs
        }

        writeDirectoryEntry(&data, offset: rootDirOffset + 32 + lfnSlots * 32,
                            name: shortName, ext: shortExt,
                            cluster: 2, fileSize: fileSize)

        // --- Data region ---
        let dataRegionOffset = rootDirOffset + rootDirSectors * sectorSize
        let cluster2Offset = dataRegionOffset
        data[cluster2Offset..<(cluster2Offset + keyData.count)] = keyData

        return data
    }

    // MARK: - MBR

    private static func writeMBR(_ data: inout Data, fsTotalSectors: UInt16) {
        // MBR partition table starts at offset 446 (partition entry 1 at 446)
        let partOffset = 446
        // Boot indicator: 0x00 = not bootable
        data[partOffset] = 0x00
        // Starting CHS (ignored by modern OS, set to standard values)
        data[partOffset + 1] = 0x01  // head
        data[partOffset + 2] = 0x01  // sector (bits 0-5) + cylinder high (bits 6-7)
        data[partOffset + 3] = 0x00  // cylinder low
        // Partition type: 0x0E = FAT16 LBA
        data[partOffset + 4] = 0x0E
        // Ending CHS
        data[partOffset + 5] = 0xFE  // head
        data[partOffset + 6] = 0xFF  // sector + cylinder high
        data[partOffset + 7] = 0xFF  // cylinder low
        // Starting LBA: 1 (FAT starts right after MBR)
        writeLE32(&data, offset: partOffset + 8, value: 1)
        // Partition size in sectors
        writeLE32(&data, offset: partOffset + 12, value: UInt32(fsTotalSectors))
        // Boot signature
        data[510] = 0x55; data[511] = 0xAA
    }

    // MARK: - Boot Sector

    private static func writeBootSector(_ data: inout Data,
                                         at offset: Int,
                                         totalSectors: UInt16,
                                         spc: UInt8,
                                         reservedSectors: UInt16,
                                         fatCount: UInt8,
                                         rootEntries: UInt16,
                                         sectorsPerFAT: UInt16,
                                         volumeLabel: String) {
        data[offset] = 0xEB; data[offset + 1] = 0x3C; data[offset + 2] = 0x90
        writeString(&data, offset: offset + 3, text: "mkfs.fat", maxLen: 8)
        writeLE16(&data, offset: offset + 11, value: 512)
        data[offset + 13] = spc
        writeLE16(&data, offset: offset + 14, value: reservedSectors)
        data[offset + 16] = fatCount
        writeLE16(&data, offset: offset + 17, value: rootEntries)
        writeLE16(&data, offset: offset + 19, value: totalSectors)
        data[offset + 21] = 0xF8
        writeLE16(&data, offset: offset + 22, value: sectorsPerFAT)
        writeLE16(&data, offset: offset + 24, value: 32)    // sectors per track
        writeLE16(&data, offset: offset + 26, value: 64)    // heads
        writeLE32(&data, offset: offset + 28, value: 1)     // hidden sectors (partition starts at LBA 1)
        writeLE32(&data, offset: offset + 32, value: 0)
        data[offset + 36] = 0x80
        data[offset + 37] = 0x00
        data[offset + 38] = 0x29
        writeLE32(&data, offset: offset + 39, value: 0x12345678)  // serial
        writeString(&data, offset: offset + 43, text: volumeLabel, maxLen: 11, padChar: 0x20)
        writeString(&data, offset: offset + 54, text: "FAT16   ", maxLen: 8)
        data[offset + 510] = 0x55; data[offset + 511] = 0xAA
    }

    // MARK: - FAT Tables

    private static func writeFAT16Tables(_ data: inout Data, fatOffset: Int, fatCount: Int, fatSectors: Int) {
        for fatIdx in 0..<fatCount {
            let offset = fatOffset + fatIdx * fatSectors * 512
            data[offset] = 0xF8; data[offset + 1] = 0xFF
            data[offset + 2] = 0xFF; data[offset + 3] = 0xFF
            data[offset + 4] = 0xFF; data[offset + 5] = 0xFF
        }
    }

    // MARK: - Directory Entries

    private static func writeVolumeLabelEntry(_ data: inout Data, _ offset: Int, label: String) {
        writeString(&data, offset: offset, text: label, maxLen: 11, padChar: 0x20)
        data[offset + 11] = 0x08
    }

    private static func writeDirectoryEntry(_ data: inout Data, offset: Int,
                                             name: String, ext: String,
                                             cluster: Int, fileSize: UInt32) {
        writeString(&data, offset: offset, text: name, maxLen: 8, padChar: 0x20)
        writeString(&data, offset: offset + 8, text: ext, maxLen: 3, padChar: 0x20)
        data[offset + 11] = 0x00
        data[offset + 12] = 0x00                          // reserved
        writeLE16(&data, offset: offset + 20, value: 0)   // cluster high (FAT16: always 0)
        writeLE16(&data, offset: offset + 26, value: UInt16(cluster))
        writeLE32(&data, offset: offset + 28, value: fileSize)
    }

    // MARK: - LE Helpers

    private static func writeLE16(_ data: inout Data, offset: Int, value: UInt16) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private static func writeLE32(_ data: inout Data, offset: Int, value: UInt32) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private static func writeString(_ data: inout Data, offset: Int, text: String, maxLen: Int, padChar: UInt8 = 0x20) {
        let bytes = Array(text.utf8).prefix(maxLen)
        for i in 0..<maxLen {
            data[offset + i] = i < bytes.count ? bytes[i] : padChar
        }
    }
}
