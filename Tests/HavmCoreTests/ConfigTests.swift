import Foundation
import Testing
@testable import HavmCore

@Suite struct ConfigTests {

    @Test("Memory size parsing", arguments: [
        ("4 GiB", 4_294_967_296 as UInt64),
        ("2048 MiB", 2_147_483_648 as UInt64),
        ("1 GiB", 1_073_741_824 as UInt64),
        ("256 MiB", 268_435_456 as UInt64),
        ("1024", 1_024 as UInt64),
    ])
    func memorySizeParsing(input: String, expected: UInt64) throws {
        #expect(try MemorySize.parse(input) == expected)
    }

    @Test("Memory size description")
    func memorySizeDescription() {
        #expect(MemorySize(bytes: 4 * 1024 * 1024 * 1024).description == "4 GiB")
        #expect(MemorySize(bytes: 2048 * 1024 * 1024).description == "2 GiB")
    }

    @Test("Effective defaults")
    func effectiveDefaults() {
        let config = HavmConfig.defaults
        #expect(config.effectiveCPUCount > 0)
        #expect(config.effectiveMemorySize == 4 * 1024 * 1024 * 1024)
        #expect(config.effectiveDiskSize == 32 * 1024 * 1024 * 1024)
        #expect(config.effectiveNetworkType == .bridge)
        #expect(config.effectiveReleaseChannel == .stable)
        #expect(config.effectiveShutdownTimeout == 30)
    }

    @Test("CONFIG disk builder produces valid MBR + FAT structure")
    func configDiskBuilder() throws {
        let key = Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA test".utf8)
        let disk = CONFIGDiskBuilder.build(authorizedKey: key)
        #expect(disk.count > 1024)
        // MBR signature at sector 0
        #expect(disk[510] == 0x55)
        #expect(disk[511] == 0xAA)
        // FAT boot sector signature at sector 1 (offset 512)
        #expect(disk[512 + 510] == 0x55)
        #expect(disk[512 + 511] == 0xAA)
        // Volume label "CONFIG" in FAT boot sector at offset 512 + 43
        let label = String(bytes: disk[512 + 43..<512 + 54], encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces)
        #expect(label == "CONFIG")
    }

    @Test("CONFIG disk authorized_keys LFN entry")
    func configDiskAuthorizedKeys() throws {
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

        #expect(foundLFN, "VFAT LFN entry not found")
        #expect(foundShort, "8.3 entry not found")
        #expect(lfnName.trimmingCharacters(in: CharacterSet(["\0", "\u{FFFF}"])) == "authorized_keys")
    }

    @Test("CONFIG disk key content at cluster 2")
    func configDiskKeyContent() throws {
        let keyContent = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA test-key\n"
        let keyData = Data(keyContent.utf8)
        let disk = CONFIGDiskBuilder.build(authorizedKey: keyData)

        // Data region: MBR(512) + FAT(512) + 2*4*512(FATs) + 32*512(root dir) = 21504
        let dataRegionOffset = 512 + 512 + 2 * 4 * 512 + 32 * 512
        let cluster2 = disk[dataRegionOffset..<(dataRegionOffset + keyData.count)]
        #expect(String(data: cluster2, encoding: .utf8) == keyContent,
                "Key content at cluster 2 should match")
    }

    @Test("Metrics config defaults")
    func metricsConfigDefaults() throws {
        let config = HavmConfig.defaults
        #expect(!config.effectiveMetricsEnabled, "Metrics should be disabled by default")
        #expect(config.effectiveMetricsType == .prometheus)
        #expect(config.effectivePrometheusPort == 9210)
        #expect(config.effectivePrometheusHosts == ["127.0.0.1", "::1"])
    }

    @Test("Metrics config explicit values")
    func metricsConfigExplicitValues() throws {
        let metrics = HavmConfig.MetricsConfig(
            enabled: true,
            type: .prometheus,
            prometheus: HavmConfig.MetricsConfig.PrometheusConfig(port: 9876, hosts: ["0.0.0.0"])
        )
        let config = HavmConfig(metrics: metrics)
        #expect(config.effectiveMetricsEnabled)
        #expect(config.effectiveMetricsType == .prometheus)
        #expect(config.effectivePrometheusPort == 9876)
        #expect(config.effectivePrometheusHosts == ["0.0.0.0"])
    }

    @Test("Metrics config partial defaults")
    func metricsConfigPartialDefaults() throws {
        let metrics = HavmConfig.MetricsConfig(enabled: true)
        let config = HavmConfig(metrics: metrics)
        #expect(config.effectiveMetricsEnabled)
        #expect(config.effectiveMetricsType == .prometheus)
        #expect(config.effectivePrometheusPort == 9210)
        #expect(config.effectivePrometheusHosts == ["127.0.0.1", "::1"])
    }

    @Test("CONFIG disk raw directory structure")
    func configDiskRawDirectory() throws {
        let keyData = Data("ssh-ed25519 test\n".utf8)
        let disk = CONFIGDiskBuilder.build(authorizedKey: keyData)
        // Root directory at MBR(512) + FAT(512) + 2*4*512(FATs) = 5120
        let rootDir = 5120

        // Entry 0 should be volume "CONFIG"
        let volName = String(bytes: disk[rootDir..<rootDir+11], encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        #expect(volName == "CONFIG", "Volume label")

        // Entry 1 should be LFN (attr 0x0F)
        #expect(disk[rootDir + 32 + 11] == 0x0F, "Entry 1 should be LFN")

        // Entry 3 should be 8.3 (attr 0x00 or 0x20)
        let shortAttr = disk[rootDir + 96 + 11]
        #expect(shortAttr == 0x00 || shortAttr == 0x20,
                "Entry 3 should be 8.3 file")
    }
}
