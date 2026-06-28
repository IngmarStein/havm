import XCTest
@testable import HavmCore

final class ConfigTests: XCTestCase {
    func testMemorySizeParsing() throws {
        XCTAssertEqual(try MemorySize.parse("4 GiB"), 4 * 1024 * 1024 * 1024)
        XCTAssertEqual(try MemorySize.parse("2048 MiB"), 2048 * 1024 * 1024)
        XCTAssertEqual(try MemorySize.parse("1 GiB"), 1024 * 1024 * 1024)
        XCTAssertEqual(try MemorySize.parse("256 MiB"), 256 * 1024 * 1024)
        XCTAssertEqual(try MemorySize.parse("1024"), 1024)
    }

    func testMemorySizeDescription() {
        XCTAssertEqual(MemorySize(bytes: 4 * 1024 * 1024 * 1024).description, "4 GiB")
        XCTAssertEqual(MemorySize(bytes: 2048 * 1024 * 1024).description, "2 GiB")
    }

    func testEffectiveDefaults() {
        let config = HavmConfig.defaults
        XCTAssertGreaterThan(config.effectiveCPUCount, 0)
        XCTAssertEqual(config.effectiveMemorySize, 4 * 1024 * 1024 * 1024)
        XCTAssertEqual(config.effectiveDiskSize, 32 * 1024 * 1024 * 1024)
        XCTAssertEqual(config.effectiveNetworkType, .nat)
        XCTAssertEqual(config.effectiveReleaseChannel, .stable)
        XCTAssertEqual(config.effectiveShutdownTimeout, 30)
    }

    func testCONFIGDiskBuilder() throws {
        let key = Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA test".utf8)
        let disk = CONFIGDiskBuilder.build(authorizedKey: key)
        XCTAssertGreaterThan(disk.count, 1024)
        // MBR signature at sector 0
        XCTAssertEqual(disk[510], 0x55)
        XCTAssertEqual(disk[511], 0xAA)
        // FAT boot sector signature at sector 1 (offset 512)
        XCTAssertEqual(disk[512 + 510], 0x55)
        XCTAssertEqual(disk[512 + 511], 0xAA)
        // Volume label "CONFIG" in FAT boot sector at offset 512 + 43
        let label = String(bytes: disk[512 + 43..<512 + 54], encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(label, "CONFIG")
    }

    func testCONFIGDiskAuthorizedKeys() throws {
        let key = Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA test".utf8)
        let disk = CONFIGDiskBuilder.build(authorizedKey: key)

        // Root directory: MBR(512) + FAT(512) + 2*4*512(FATs) = 5120
        let rootDirOffset = 512 + 512 + 2 * 4 * 512

        var foundLFN = false
        var foundShort = false
        var lfnName = ""
        for slot in 0..<32 {
            let off = rootDirOffset + slot * 32
            let attr = disk[off + 11]
            if attr == 0x0F {
                foundLFN = true
                let positions = [(1, 5), (14, 6), (28, 2)]
                var chars: [UInt16] = []
                for (pos, count) in positions {
                    for i in 0..<count {
                        let p = off + pos + i * 2
                        let w = UInt16(disk[p]) | (UInt16(disk[p + 1]) << 8)
                        if w != 0 && w != 0xFFFF { chars.append(w) }
                    }
                }
                if !chars.isEmpty {
                    let name = chars.withUnsafeBufferPointer {
                        String(utf16CodeUnits: $0.baseAddress!, count: $0.count)
                    }
                    lfnName = name + lfnName
                }
            } else if attr & 0x08 != 0 {
                continue
            } else if disk[off] == 0x00 {
                break
            } else if disk[off] != 0xE5 {
                foundShort = true
            }
        }

        XCTAssertTrue(foundLFN, "VFAT LFN entry not found")
        XCTAssertTrue(foundShort, "8.3 entry not found")
        XCTAssertEqual(lfnName.trimmingCharacters(in: CharacterSet(["\0", "\u{FFFF}"])), "authorized_keys")
    }

    func testCONFIGDiskKeyContent() throws {
        // Build a disk with known key data and verify the key is at cluster 2
        let keyContent = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA test-key\n"
        let keyData = Data(keyContent.utf8)
        let disk = CONFIGDiskBuilder.build(authorizedKey: keyData)

        // Data region: MBR(512) + FAT(512) + 2*4*512(FATs) + 32*512(root dir) = 5120 + 16384 = 21504
        let dataRegionOffset = 512 + 512 + 2 * 4 * 512 + 32 * 512
        let cluster2 = disk[dataRegionOffset..<(dataRegionOffset + keyData.count)]
        XCTAssertEqual(String(data: cluster2, encoding: .utf8), keyContent, "Key content at cluster 2 should match")
    }

    func testMetricsConfigDefaults() throws {
        let config = HavmConfig.defaults
        XCTAssertFalse(config.effectiveMetricsEnabled, "Metrics should be disabled by default")
        XCTAssertEqual(config.effectiveMetricsType, .prometheus)
        XCTAssertEqual(config.effectivePrometheusPort, 9210)
        XCTAssertEqual(config.effectivePrometheusHost, "127.0.0.1")
    }

    func testMetricsConfigExplicitValues() throws {
        let metrics = HavmConfig.MetricsConfig(
            enabled: true,
            type: .prometheus,
            prometheus: HavmConfig.MetricsConfig.PrometheusConfig(port: 9876, host: "0.0.0.0")
        )
        let config = HavmConfig(metrics: metrics)
        XCTAssertTrue(config.effectiveMetricsEnabled)
        XCTAssertEqual(config.effectiveMetricsType, .prometheus)
        XCTAssertEqual(config.effectivePrometheusPort, 9876)
        XCTAssertEqual(config.effectivePrometheusHost, "0.0.0.0")
    }

    func testMetricsConfigPartialDefaults() throws {
        let metrics = HavmConfig.MetricsConfig(enabled: true)
        let config = HavmConfig(metrics: metrics)
        XCTAssertTrue(config.effectiveMetricsEnabled)
        XCTAssertEqual(config.effectiveMetricsType, .prometheus)  // default type
        XCTAssertEqual(config.effectivePrometheusPort, 9210)      // default port
        XCTAssertEqual(config.effectivePrometheusHost, "127.0.0.1") // default host
    }

    func testCONFIGDiskRawDirectory() throws {
        let keyData = Data("ssh-ed25519 test\n".utf8)
        let disk = CONFIGDiskBuilder.build(authorizedKey: keyData)
        // Root directory at MBR(512) + FAT(512) + 2*4*512(FATs) = 5120
        let rootDir = 5120

        // Dump first 4 directory entries (32 bytes each)
        let entries = (0..<4).map { i in
            Array(disk[rootDir + i * 32..<rootDir + (i + 1) * 32])
                .map { String(format: "%02x", $0) }.joined(separator: " ")
        }
        print("\n--- Root directory entries ---")
        for (i, e) in entries.enumerated() {
            let attr = disk[rootDir + i * 32 + 11]
            let type = attr == 0x08 ? "VOLUME" : attr == 0x0F ? "LFN" : attr == 0x00 ? "FILE" : String(format: "0x%02x", attr)
            print("Entry \(i) [\(type)]: \(e)")
        }

        // Entry 0 should be volume "CONFIG"
        let volName = String(bytes: disk[rootDir..<rootDir+11], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
        XCTAssertEqual(volName, "CONFIG", "Volume label")

        // Entry 1 should be LFN (attr 0x0F)
        XCTAssertEqual(disk[rootDir + 32 + 11], 0x0F, "Entry 1 should be LFN")

        // Entry 3 should be 8.3 (attr 0x00 or 0x20)
        let shortAttr = disk[rootDir + 96 + 11]
        XCTAssertTrue(shortAttr == 0x00 || shortAttr == 0x20, "Entry 3 should be 8.3 file, got 0x\(String(shortAttr, radix: 16))")

        // Read short name from entry 3
        let shortName = String(bytes: disk[rootDir+96..<rootDir+96+8], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
        let shortExt = String(bytes: disk[rootDir+96+8..<rootDir+96+11], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
        print("Short name: '\(shortName).\(shortExt)'")
    }
}
