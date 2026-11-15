import Foundation
import Testing
@testable import HavmCore

/// The startup warning for a config file other users can reach.
///
/// `ha.api_token` is a bearer token, so a world-readable config hands the REST
/// API to every account on the Mac. havm does not own the file's mode and must
/// not change it, so the warning is the whole remedy.
@Suite struct ConfigFilePermissionsTests {

    @Test(arguments: [
        UInt16(0o600),  // owner only
        UInt16(0o400),  // read-only, owner only
        UInt16(0o000),  // nothing, which is not a leak
    ])
    func ownerOnlyIsFine(mode: UInt16) {
        #expect(ConfigFilePermissions.warning(path: "/tmp/config.yml", mode: mode) == nil)
    }

    @Test(arguments: [UInt16(0o644), UInt16(0o640), UInt16(0o604), UInt16(0o620), UInt16(0o660), UInt16(0o777)])
    func anyGroupOrOtherBitIsReported(mode: UInt16) {
        let warning = ConfigFilePermissions.warning(path: "/tmp/config.yml", mode: mode)
        #expect(warning?.contains("chmod 600 /tmp/config.yml") == true)
        #expect(warning?.contains(String(mode, radix: 8)) == true)
    }

    /// A config with no token has nothing worth protecting, and warning about
    /// it would teach people to ignore the warning.
    @Test func noTokenMeansNoWarning() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("havm-perm-\(UUID().uuidString).yml")
        try? "ha:\n  url: http://homeassistant.local\n".write(toFile: path.path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        defer { try? FileManager.default.removeItem(at: path) }

        #expect(ConfigFilePermissions.warning(path: path.path, hasAPIToken: false) == nil)
        #expect(ConfigFilePermissions.warning(path: path.path, hasAPIToken: true) != nil)
    }

    @Test func aMissingFileIsNotAWarning() {
        #expect(ConfigFilePermissions.warning(
            path: "/nonexistent/havm/config.yml", hasAPIToken: true) == nil)
    }
}
