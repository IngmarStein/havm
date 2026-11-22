import Foundation
import Testing
@testable import HavmCore

/// Reading the guest's address out of the NAT lease file.
///
/// The file holds a stanza per lease, written by macOS's own DHCP server, so
/// the parse has to survive other guests' stanzas — and must not confuse one
/// guest's address with another's.
@Suite struct DHCPLeasesTests {

    private static let leases = """
        {
        ip_address=192.168.64.2
        hw_address=1,0:1:2:3:4:5
        identifier=1,0:1:2:3:4:5
        lease=0x68e1a2b3
        }
        {
        ip_address=192.168.64.5
        hw_address=1,2:0:0:0:0:1
        identifier=1,2:0:0:0:0:1
        lease=0x68e1a2c4
        }
        """

    private static let guestMAC: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x01]

    @Test func findsTheStanzaForTheMAC() {
        #expect(DHCPLeases.address(forMAC: Self.guestMAC, in: Self.leases) == "192.168.64.5")
    }

    @Test func anotherGuestIsNotTheGuest() {
        let other: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x02]
        #expect(DHCPLeases.address(forMAC: other, in: Self.leases) == nil)
    }

    @Test func anEmptyFileHasNoLease() {
        #expect(DHCPLeases.address(forMAC: Self.guestMAC, in: "") == nil)
    }

    @Test func aMACWithNoBytesNeverMatches() {
        #expect(DHCPLeases.address(forMAC: [], in: Self.leases) == nil)
    }

    /// The lease file writes each octet without leading zeros, and a stanza
    /// without an address is not an answer.
    @Test func parsesMACsInTheFilesOwnSpelling() {
        #expect(DHCPLeases.bytes(ofMAC: "2:0:0:0:0:1") == Self.guestMAC)
        #expect(DHCPLeases.bytes(ofMAC: "02:00:00:00:00:01") == Self.guestMAC)
        #expect(DHCPLeases.bytes(ofMAC: "2:0:0:0:0") == nil)
        #expect(DHCPLeases.bytes(ofMAC: "") == nil)
        #expect(DHCPLeases.bytes(ofMAC: "zz:00:00:00:00:01") == nil)
        #expect(DHCPLeases.bytes(ofMAC: "02:00:00:00:00:01:02:03:04") == nil)
    }

    @Test func aStanzaWithoutAnAddressIsIgnored() {
        let text = """
            {
            hw_address=1,2:0:0:0:0:1
            lease=0x68e1a2c4
            }
            """
        #expect(DHCPLeases.address(forMAC: Self.guestMAC, in: text) == nil)
    }

    @Test func prefersTheLeaseWithTheLatestExpiryTimestamp() {
        let text = """
            {
            ip_address=192.168.64.2
            hw_address=1,2:0:0:0:0:1
            lease=0x68e10000
            }
            {
            ip_address=192.168.64.9
            hw_address=1,2:0:0:0:0:1
            lease=0x68e2ffff
            }
            {
            ip_address=192.168.64.3
            hw_address=1,2:0:0:0:0:1
            lease=0x68e10001
            }
            """
        #expect(DHCPLeases.address(forMAC: Self.guestMAC, in: text) == "192.168.64.9")
    }
}
