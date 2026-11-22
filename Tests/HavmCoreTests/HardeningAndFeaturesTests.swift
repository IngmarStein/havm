import CXZ
import Foundation
import Logging
import Security
import Testing
@testable import HavmCore

@Suite struct HardeningAndFeaturesTests {

    private static let sampleCertPEM = """
    -----BEGIN CERTIFICATE-----
    MIICpDCCAYwCCQCtMnltNK9UJjANBgkqhkiG9w0BAQsFADAUMRIwEAYDVQQDDAlo
    YXZtLnRlc3QwHhcNMjYxMTIxMTkzMTMyWhcNMjYxMTIyMTkzMTMyWjAUMRIwEAYD
    VQQDDAloYXZtLnRlc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDw
    z7d205g1QTCAADBMgJC8oim9ph0109XKgTSn0IRtctB6HO85Wsnm3dBj52thsJ1J
    K0SdSnjPkR/dH2TACKhukmGODxhen5dMHufMkQW0luZ12vd055ANvyublol8FA0s
    baHXMBNchP8IrADtze6Mkn9RMssAU7uqNHM3CagxVJDLLqCArWEcl61nC3eUlRh1
    YfRTuEDrejpd3Ps6gH4Va/ZplGfPV5I3SAoVt+RkpmUpEIkKyMY0a8OrXWuZ3mzw
    9xNEpPalfvrPx3LA3eh+vjzcD8Y8V7VyGD6911Jpi7ugT5XkFV3Z/JZsJSdpFtFO
    B+wwJXCKPAgpB47LG8wpAgMBAAEwDQYJKoZIhvcNAQELBQADggEBAOZMZb1GD2WM
    DY8894+ynnScEmZARDm5/22Hc63QfITEtFqfArp32xHXz7MBUbMpiB0Lz7TkE6Te
    WiqWTYHJqslkyFLhGEKvWXL8BhZ5xMqGqcS89WkrJ9YkMFEd0Z7dCv/OHkNkKsDv
    xdzZP7KixbSiwKToXavsZdE1GA4Vcm5gqMxZwR8t2dJv8mxSpA8n0ttIrwceJ4R7
    4rf5o48I0pTZQZwiIF7UeQV9rXaSVt/KTFot3UA8wAtGn9tzzWe2kdHOwa0gKdiV
    XrsXhJ/+Y3JOQ9ikVG3f1t9M6kaEQkBASGMKM59RZlE+n2WqUxP4LrrUY8xClrXy
    X33hm4pCRAc=
    -----END CERTIFICATE-----
    """

    // MARK: - Certificate loader (Custom CA support)

    @Test("HACertificateLoader parses single PEM, multi-cert PEM bundle, and DER")
    func loadsPEMAndDERCertificates() throws {
        let pemData = Data(Self.sampleCertPEM.utf8)
        let single = HACertificateLoader.loadCertificates(from: pemData)
        #expect(single.count == 1)

        // Multi-cert bundle
        let bundleData = Data((Self.sampleCertPEM + "\n" + Self.sampleCertPEM).utf8)
        let bundle = HACertificateLoader.loadCertificates(from: bundleData)
        #expect(bundle.count == 2)

        // Raw DER round-trip
        let der = SecCertificateCopyData(single[0]) as Data
        let fromDER = HACertificateLoader.loadCertificates(from: der)
        #expect(fromDER.count == 1)

        // Garbage returns empty array
        #expect(HACertificateLoader.loadCertificates(from: Data("not a cert".utf8)).isEmpty)
    }

    // MARK: - SSH shutdown hardening

    @Test("SSH shutdown arguments disable forwarding/local commands and terminate options")
    func sshArgumentsAreHardened() {
        let args = ServiceRuntime.sshShutdownArguments(
            host: "homeassistant.local",
            port: 22222,
            command: "shutdown -h now",
            timeout: 90
        )
        #expect(args.contains("ForwardAgent=no"))
        #expect(args.contains("ClearAllForwardings=yes"))
        #expect(args.contains("PermitLocalCommand=no"))
        #expect(args.contains("RequestTTY=no"))
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("ConnectTimeout=5"))
        // `--` must precede `root@host`
        let sepIndex = args.firstIndex(of: "--")
        let hostIndex = args.firstIndex(of: "root@homeassistant.local")
        #expect(sepIndex != nil && hostIndex != nil && sepIndex! < hostIndex!)
    }

    // MARK: - HTTPS download URL validation

    @Test("Download URL validator requires HTTPS with a host")
    func downloadURLValidation() {
        #expect(HAOSSetupManager.validatedHTTPSURL("https://github.com/home-assistant/file.img.xz") != nil)
        #expect(HAOSSetupManager.validatedHTTPSURL("http://github.com/file.img.xz") == nil)
        #expect(HAOSSetupManager.validatedHTTPSURL("file:///etc/passwd") == nil)
        #expect(HAOSSetupManager.validatedHTTPSURL("https://") == nil)
        #expect(HAOSSetupManager.validatedHTTPSURL("") == nil)
    }

    // MARK: - Console cmdline patching

    /// Build a minimal GPT disk image with an EFI System Partition containing `espContents`.
    private func makeGPTDisk(espContents: String) -> Data {
        let espStartLBA: UInt64 = 34
        let espSectors: UInt64 = 4
        let totalSectors = Int(espStartLBA + espSectors)
        var bytes = [UInt8](repeating: 0, count: totalSectors * 512)

        // GPT header at LBA 1 (offset 512)
        for (i, b) in Array("EFI PART".utf8).enumerated() { bytes[512 + i] = b }
        writeLE64(&bytes, at: 512 + 72, value: 2)   // entryStartLBA
        writeLE32(&bytes, at: 512 + 80, value: 4)   // entryCount
        writeLE32(&bytes, at: 512 + 84, value: 128) // entrySize

        // Partition entry 0 at LBA 2 (offset 1024): EFI System Partition GUID
        let espGUID: [UInt8] = [0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
                                0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B]
        for (i, b) in espGUID.enumerated() { bytes[1024 + i] = b }
        writeLE64(&bytes, at: 1024 + 32, value: espStartLBA)
        writeLE64(&bytes, at: 1024 + 40, value: espStartLBA + espSectors - 1)

        // Write cmdline content inside ESP
        let espOffset = Int(espStartLBA) * 512
        for (i, b) in Array(espContents.utf8).enumerated() {
            bytes[espOffset + i] = b
        }
        return Data(bytes)
    }

    private func writeLE32(_ bytes: inout [UInt8], at offset: Int, value: UInt32) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (i * 8)) & 0xFF) }
    }

    private func writeLE64(_ bytes: inout [UInt8], at offset: Int, value: UInt64) {
        for i in 0..<8 { bytes[offset + i] = UInt8((value >> (i * 8)) & 0xFF) }
    }

    @Test("patchConsoleCmdline pads with spaces, never NULs, preserving trailing kernel args")
    func patchConsoleCmdlinePreservesTrailingArgs() throws {
        let original = "console=ttyAMA0,115200 console=tty0 root=PARTUUID=1234 ro\n"
        let disk = makeGPTDisk(espContents: original)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("havm-cmdline-\(UUID().uuidString).img")
        try disk.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let fh = try FileHandle(forUpdating: url)
        defer { try? fh.close() }
        HAOSSetupManager.patchConsoleCmdline(in: fh, logger: Logger(label: "test"))

        let updated = try Data(contentsOf: url)
        let espOffset = 34 * 512
        let slice = updated[espOffset..<(espOffset + original.utf8.count)]
        let text = try #require(String(data: slice, encoding: .utf8))

        #expect(text.hasPrefix("console=hvc0 "))
        #expect(text.contains("root=PARTUUID=1234 ro\n"))
        #expect(!slice.contains(0x00), "Must pad with spaces (0x20), never NUL bytes")
    }

    @Test("patchConsoleCmdline does not overwrite trailing bytes when console= token is shorter than 12 bytes")
    func patchConsoleCmdlineDoesNotCorruptShortToken() throws {
        let original = "console=tty root=PARTUUID=1234\n"
        let disk = makeGPTDisk(espContents: original)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("havm-cmdline-short-\(UUID().uuidString).img")
        try disk.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let fh = try FileHandle(forUpdating: url)
        defer { try? fh.close() }
        HAOSSetupManager.patchConsoleCmdline(in: fh, logger: Logger(label: "test"))

        let updated = try Data(contentsOf: url)
        let espOffset = 34 * 512
        let slice = updated[espOffset..<(espOffset + original.utf8.count)]
        #expect(String(data: slice, encoding: .utf8) == original)
    }

    // MARK: - JSONLogHandler

    @Test("JSONLogHandler merges handler metadata and protects core schema fields")
    func jsonLogHandlerMergesAndProtectsCoreFields() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("havm-jsonlog-\(UUID().uuidString).ndjson")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        let fh = try FileHandle(forWritingTo: url)
        var handler = JSONLogHandler(label: "havm.test", stream: fh, level: .info)
        handler[metadataKey: "component"] = "vm"
        handler[metadataKey: "level"] = "injected-level"

        handler.log(event: .init(
            level: .warning,
            message: "hello",
            metadata: ["extra": "42", "message": "injected-message"],
            source: "test",
            file: #file,
            function: #function,
            line: #line
        ))
        try fh.close()

        let data = try Data(contentsOf: url)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(obj["component"] as? String == "vm")
        #expect(obj["extra"] as? String == "42")
        #expect(obj["level"] as? String == "warning")
        #expect(obj["message"] as? String == "hello")
        #expect(obj["label"] as? String == "havm.test")
    }

    // MARK: - CXZ decompression

    @Test("xz_decompress_file decodes single and concatenated XZ streams")
    func xzDecompressConcatenatedStreams() throws {
        // Valid XZ stream for "hello\n" (compressed with xz)
        let helloXZ: [UInt8] = [
            0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00, 0x00, 0x04,
            0xe6, 0xd6, 0xb4, 0x46, 0x02, 0x00, 0x21, 0x01,
            0x16, 0x00, 0x00, 0x00, 0x74, 0x2f, 0xe5, 0xa3,
            0x01, 0x00, 0x05, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
            0x0a, 0x00, 0x00, 0x00, 0xa5, 0x60, 0x97, 0xf1,
            0x94, 0xf6, 0xfd, 0xe0, 0x00, 0x01, 0x1e, 0x06,
            0xc1, 0x2f, 0xa4, 0x1d, 0x1f, 0xb6, 0xf3, 0x7d,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x59, 0x5a,
        ]
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("havm-xz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let inFile = dir.appendingPathComponent("concat.xz")
        let outFile = dir.appendingPathComponent("out.txt")
        // Concatenate two independent XZ streams
        try Data(helloXZ + helloXZ).write(to: inFile)

        let rc = xz_decompress_file(inFile.path, outFile.path)
        #expect(rc == 0)
        let output = try String(contentsOf: outFile, encoding: .utf8)
        #expect(output == "hello\nhello\n")
    }
}
