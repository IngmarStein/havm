import Foundation

/// Reading the address the guest was given out of macOS's DHCP lease file.
///
/// In NAT mode macOS `vmnet` is the DHCP server, so `/var/db/dhcpd_leases` is
/// the only place the guest's address exists — there is no name to resolve.
/// The file is a sequence of stanzas:
///
///     {
///     ip_address=192.168.64.5
///     hw_address=1,0:1:2:3:4:5
///     identifier=1,0:1:2:3:4:5
///     lease=0x...
///     }
///
/// The lease is found by MAC because that is the only part havm controls: the
/// address is the guest's to ask for.
enum DHCPLeases {

    /// The path macOS keeps leases at.
    static let path = "/var/db/dhcpd_leases"

    /// The address `mac` holds in `text`, or `nil` when there is no stanza for
    /// it — a lease not yet granted, or one for a different guest.
    static func address(forMAC mac: [UInt8], in text: String) -> String? {
        guard !mac.isEmpty else { return nil }
        for stanza in text.components(separatedBy: "}\n") {
            var stanzaMAC: [UInt8] = []
            var stanzaIP: String?
            for line in stanza.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(hwAddressPrefix) {
                    stanzaMAC = bytes(ofMAC: String(trimmed.dropFirst(hwAddressPrefix.count))) ?? []
                } else if trimmed.hasPrefix(ipAddressPrefix) {
                    stanzaIP = String(trimmed.dropFirst(ipAddressPrefix.count))
                }
            }
            if stanzaMAC == mac, let ip = stanzaIP, !ip.isEmpty {
                return ip
            }
        }
        return nil
    }

    /// A colon-separated MAC address as six bytes, or `nil` when it is not
    /// one. The lease file writes each octet without leading zeros, so a part
    /// is one or two digits.
    static func bytes(ofMAC mac: String) -> [UInt8]? {
        let parts = mac.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty, part.count <= 2, let byte = UInt8(part, radix: 16) else {
                return nil
            }
            bytes.append(byte)
        }
        return bytes
    }

    /// `hw_address` carries the ARP hardware type before the address — `1` is
    /// Ethernet, the only kind a VM's virtual NIC is.
    private static let hwAddressPrefix = "hw_address=1,"
    private static let ipAddressPrefix = "ip_address="
}
