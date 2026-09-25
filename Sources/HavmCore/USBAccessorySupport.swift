import Foundation
import AppKit
@_weakLinked import AccessoryAccess
import Logging
import Metrics

// USB accessory passthrough is only available on macOS 27 (Golden Gate):
// it depends on the AccessoryAccess framework (`AAUSBAccessoryManager`,
// `AAUSBAccessoryListener`) and `VZUSBPassthroughDevice`. Everything in
// this file is annotated `@available(macOS 27.0, *)` so the rest of havm
// builds and runs on macOS 15+. On older hosts, `ServiceRuntime` skips
// USB discovery with a log message and the VM runs normally.

/// Owns the USB accessory discovery UI and hot-attach wiring. macOS shows
/// a menu bar item where the user selects which USB accessories to attach;
/// on connect, the accessory is hot-attached to the running VM via
/// ``VMController/attachAccessory(_:)``.
@available(macOS 27.0, *)
final class USBAccessoryCoordinator: NSObject, AAUSBAccessoryListener, @unchecked Sendable {
    private weak var vmController: VMController?
    private let logger: Logger
    private var accessoryCount = 0

    init(vmController: VMController, logger: Logger) {
        self.vmController = vmController
        self.logger = logger
        super.init()
        // Initialize the gauge so it appears in /metrics even before
        // any accessory connects (zero is a meaningful initial value).
        Gauge(label: "havm_usb_accessories").record(0)
    }

    /// Register with `AAUSBAccessoryManager`. Must run on the main queue.
    func start() {
        // AAUSBAccessoryManager needs a running NSApplication.
        // Called from main queue via DispatchQueue.main.async, but NSApplication
        // is @MainActor — use MainActor.assumeIsolated to satisfy the compiler.
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.accessory)
        } as Void

        AAUSBAccessoryManager.shared.registerListener(
            self, matchingCriteria: [],
            completionHandler: { [weak self] accessories, error in
                guard let self else { return }
                if let error {
                    self.logger.info("USB: Listener not available (restricted entitlement missing): \(error.localizedDescription)")
                    return
                }
                self.logger.info("USB: Listener registered — \(accessories.count) already connected")
                for acc in accessories {
                    self.vmController?.attachAccessory(acc)
                }
            }
        )
    }

    // MARK: - AAUSBAccessoryListener

    func usbAccessoryDidConnect(_ accessory: AAUSBAccessory) {
        let (vid, pid) = accessory.vendorProductID
        logger.info("USB: Accessory connected — 0x\(String(vid, radix: 16, uppercase: true)):0x\(String(pid, radix: 16, uppercase: true)) (registryID=\(accessory.registryIDHex))")
        vmController?.attachAccessory(accessory)
        accessoryCount += 1
        Gauge(label: "havm_usb_accessories").record(Double(accessoryCount))
    }

    func usbAccessoryDidDisconnect(_ accessory: AAUSBAccessory) {
        let (vid, pid) = accessory.vendorProductID
        logger.info("USB: Accessory disconnected — 0x\(String(vid, radix: 16, uppercase: true)):0x\(String(pid, radix: 16, uppercase: true)) (registryID=\(accessory.registryIDHex))")
        accessoryCount = max(0, accessoryCount - 1)
        Gauge(label: "havm_usb_accessories").record(Double(accessoryCount))
    }
}

// MARK: - AAUSBAccessory convenience

@available(macOS 27.0, *)
extension AAUSBAccessory {
    /// Extract vendor and product ID from the USB device descriptor.
    /// USB device descriptor layout (USB 2.0 spec §9.6.1):
    ///   offset 8-9:  idVendor  (little-endian)
    ///   offset 10-11: idProduct (little-endian)
    var vendorProductID: (UInt16, UInt16) {
        let data = deviceDescriptorData
        guard data.count >= 12 else { return (0, 0) }
        let vid = UInt16(data[8]) | (UInt16(data[9]) << 8)
        let pid = UInt16(data[10]) | (UInt16(data[11]) << 8)
        return (vid, pid)
    }

    /// IOKit registry entry ID in the lowercase hex `ioreg` prints it as, so a
    /// log line can be matched to the device's registry entry:
    ///
    ///     ioreg -l -w 0 | grep 0x100102d73
    ///
    /// This is the one identifier that distinguishes two identical accessories,
    /// and the only route from a havm log line to the device's descriptors in
    /// the IOKit registry. Printed in decimal (1.0.2 and earlier) it matched no
    /// tool's output and had to be converted by hand.
    var registryIDHex: String { "0x" + String(registryID, radix: 16) }
}

// MARK: - Descriptor inspection

/// Summarizes the interfaces and endpoints of a USB configuration descriptor.
///
/// `VZUSBPassthroughDevice(configuration:)` refuses a device whose endpoints are
/// isochronous, and the message it returns for that is one of several
/// near-identical USB passthrough errors. Logging the endpoint census next to the
/// error is what separates an unsupported device from a denied or malformed one
/// (issue #13).
enum USBConfigurationSummary {

    /// One-line census of a configuration descriptor — the bytes behind
    /// ``AAUSBAccessory/configurationDescriptorData``: each interface's class and
    /// endpoint count, the total number of endpoints, and how many of those are
    /// isochronous. ISO 0 dates from the accessory being unconfigured.
    ///
    /// Layouts are from USB 2.0 spec §9.6.3 (configuration, 9 bytes), §9.6.5
    /// (interface, 9 bytes), and §9.6.6 (endpoint, 7 bytes).
    static func describe(_ data: Data?) -> String {
        guard let data, data.count >= 9 else { return "configuration descriptor unavailable" }
        let bytes = [UInt8](data)

        // wTotalLength bounds the configuration. A truncated or hostile
        // descriptor must not walk past the end of the buffer.
        let totalLength = min(Int(bytes[2]) | (Int(bytes[3]) << 8), bytes.count)
        var interfaces: [String] = []
        var endpoints = 0
        var isochronous = 0
        var offset = Int(bytes[0])  // skip the configuration descriptor itself
        while offset + 2 <= totalLength {
            let length = Int(bytes[offset])
            // bLength 0 or 1 would never advance the cursor.
            guard length >= 2, offset + length <= totalLength else { break }
            switch bytes[offset + 1] {  // bDescriptorType
            case 4 where length >= 9:  // INTERFACE
                let classCode = bytes[offset + 5]   // bInterfaceClass
                let endpointCount = Int(bytes[offset + 4])  // bNumEndpoints
                interfaces.append("\(String(format: "0x%02X", classCode)):\(endpointCount)ep")
            case 5 where length >= 7:  // ENDPOINT
                endpoints += 1
                // bmAttributes bits 0-1 hold the transfer type; 1 is isochronous.
                if (bytes[offset + 3] & 0x03) == 0x01 { isochronous += 1 }
            default:
                break
            }
            offset += length
        }

        let list = interfaces.isEmpty ? "none" : interfaces.joined(separator: ", ")
        return "interfaces [\(list)], \(endpoints) endpoint\(endpoints == 1 ? "" : "s"), \(isochronous) isochronous"
    }
}
