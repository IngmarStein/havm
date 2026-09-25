import Testing
@testable import HavmCore

/// The VID/PID pair a log line prints has to be copy-pasteable into a search
/// for the device, which means the same shape every tool uses: lowercase hex,
/// zero-padded to four digits.
@Suite struct USBIdentifierTests {

    @Test("A VID/PID pair is lowercase and zero-padded to four digits")
    func padding() {
        // 0x1:0x2 un-padded and 0x18D1:0x5026 upper-cased are both unsearchable.
        #expect(USBIdentifiers.hex(vendorID: 0x1, productID: 0x2) == "0x0001:0x0002")
        #expect(USBIdentifiers.hex(vendorID: 0x18D1, productID: 0x5026) == "0x18d1:0x5026")
    }

    @Test("Real device IDs keep their leading zeros")
    func realWorldIDs() {
        // The Bluetooth dongle from issue #13, and the value that has no
        // padding to lose.
        #expect(USBIdentifiers.hex(vendorID: 0x0BDA, productID: 0xA725) == "0x0bda:0xa725")
        #expect(USBIdentifiers.hex(vendorID: 0xFFFF, productID: 0x0000) == "0xffff:0x0000")
    }
}
