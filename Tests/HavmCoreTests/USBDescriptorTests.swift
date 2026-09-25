import Foundation
import Testing
@testable import HavmCore

/// Tests for the USB descriptor census that makes a passthrough failure
/// diagnosable: `VZUSBPassthroughDevice` rejects devices with isochronous
/// endpoints, and the error alone doesn't say so (issue #13).
@Suite struct USBDescriptorTests {

    /// Builds a configuration descriptor from a list of interfaces, each with
    /// the `bmAttributes` byte of every endpoint it carries.
    private func configuration(_ interfaces: [(classCode: UInt8, endpoints: [UInt8])]) -> Data {
        var body: [UInt8] = []
        for interface in interfaces {
            // Interface descriptor (USB 2.0 §9.6.5): bLength 9, type 4.
            body += [9, 4, 0, 0, UInt8(interface.endpoints.count), interface.classCode, 0, 0, 0]
            for attributes in interface.endpoints {
                // Endpoint descriptor (§9.6.6): bLength 7, type 5.
                body += [7, 5, 0x81, attributes, 0x40, 0x00, 0x01]
            }
        }
        var header: [UInt8] = [9, 2, 0, 0, UInt8(interfaces.count), 1, 0, 0x80, 50]
        let total = UInt16(header.count + body.count)
        header[2] = UInt8(total & 0xFF)
        header[3] = UInt8(total >> 8)
        return Data(header + body)
    }

    @Test("Bluetooth dongle with isochronous SCO endpoints is reported")
    func bluetoothDongle() {
        // Realtek-style HCI: a wireless interface, audio control, and two audio
        // streaming alternate settings carrying the SCO isochronous pairs.
        let descriptor = configuration([
            (0xE0, [0x03, 0x02, 0x02]),  // event, ACL in, ACL out
            (0x01, []),  // audio control
            (0x01, [0x0D, 0x0D]),  // SCO, isochronous
            (0x01, [0x0D, 0x0D]),  // SCO, isochronous
        ])
        #expect(
            USBConfigurationSummary.describe(descriptor)
                == "interfaces [0xE0:3ep, 0x01:0ep, 0x01:2ep, 0x01:2ep], 7 endpoints, 4 isochronous"
        )
    }

    @Test("A mass storage device reports no isochronous endpoints")
    func massStorage() {
        // The control case for issue #13: a flash drive is bulk-only.
        let descriptor = configuration([(0x08, [0x02, 0x02])])
        #expect(
            USBConfigurationSummary.describe(descriptor)
                == "interfaces [0x08:2ep], 2 endpoints, 0 isochronous"
        )
    }

    @Test("An unconfigured or absent descriptor is called out")
    func missingDescriptor() {
        #expect(USBConfigurationSummary.describe(nil) == "configuration descriptor unavailable")
        #expect(USBConfigurationSummary.describe(Data([9, 2])) == "configuration descriptor unavailable")
    }

    @Test("A descriptor that never advances terminates instead of looping")
    func zeroLengthDescriptor() {
        // bLength 0 would leave the cursor where it is; wTotalLength also
        // overruns the buffer.
        var bytes: [UInt8] = [9, 2, 0xFF, 0xFF, 1, 1, 0, 0x80, 50]
        bytes += [0, 4] + [UInt8](repeating: 0, count: 7)
        #expect(
            USBConfigurationSummary.describe(Data(bytes))
                == "interfaces [none], 0 endpoints, 0 isochronous"
        )
    }

    @Test("Bytes past wTotalLength are ignored")
    func trailingBytes() {
        var bytes = [UInt8](configuration([(0x08, [0x02])]))
        bytes += [7, 5, 0x81, 0x01, 0x40, 0x00, 0x01]  // isochronous, outside the configuration
        #expect(
            USBConfigurationSummary.describe(Data(bytes))
                == "interfaces [0x08:1ep], 1 endpoint, 0 isochronous"
        )
    }
}
