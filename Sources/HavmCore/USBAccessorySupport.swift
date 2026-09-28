import Foundation
import AppKit
import IOUSBHost
@_weakLinked import AccessoryAccess
import Logging

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

    init(vmController: VMController, logger: Logger) {
        self.vmController = vmController
        self.logger = logger
        super.init()
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
        logger.info("USB: Accessory connected — \(accessory.vendorProductIDHex) (registryID=\(accessory.registryIDHex))")
        vmController?.attachAccessory(accessory)
    }

    func usbAccessoryDidDisconnect(_ accessory: AAUSBAccessory) {
        logger.info("USB: Accessory disconnected — \(accessory.vendorProductIDHex) (registryID=\(accessory.registryIDHex))")
    }
}

// MARK: - Identifier formatting

/// Formats USB vendor and product IDs the way every other tool prints them —
/// lowercase hex, zero-padded to four digits, so `0x0bda:0xa725` can be pasted
/// into a search for the device's datasheet or an `lsusb` line. Not tied to
/// AccessoryAccess, so it is unit-testable on any host.
enum USBIdentifiers {

    /// Renders a vendor/product pair, e.g. `0x18d1:0x5026`.
    static func hex(vendorID: UInt16, productID: UInt16) -> String {
        String(format: "0x%04x:0x%04x", vendorID, productID)
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

    /// ``vendorProductID`` rendered as `0x18d1:0x5026` — see ``USBIdentifiers``.
    var vendorProductIDHex: String {
        let (vid, pid) = vendorProductID
        return USBIdentifiers.hex(vendorID: vid, productID: pid)
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

// MARK: - Error formatting

/// Renders an error the way a passthrough failure needs it: domain, code, and
/// message.
///
/// Virtualization's USB errors are near-identical in wording ("Failed to create
/// USB Passthrough Device."), and the errors it passes up from lower-level
/// components carry no wording at all — `VZErrorDomain -6` in issue #13 is not
/// one of its documented codes. The domain and code are what tell one failure
/// from another.
enum USBErrorReport {
    static func describe(_ error: any Error) -> String {
        let reason = error as NSError
        return "\(reason.domain) \(reason.code): \(reason.localizedDescription)"
    }
}

// MARK: - Descriptor inspection

/// Summarizes the interfaces and endpoints of a USB configuration descriptor.
///
/// The framework's USB passthrough errors are near-identical to one another, so
/// logging what the device actually declares — its interfaces and endpoints —
/// next to the error is what lets a reader tell an unsupported device from a
/// denied or malformed one (issue #13).
///
/// This describes the device, not the framework. havm does not decide from it
/// whether passthrough will work: what a device attaches as is the framework's
/// verdict to give, and a rule of havm's own invention would outlive its truth.
/// The one rule stated here — ``Census/isochronousNote`` — is the framework's
/// own, quoted.
enum USBConfigurationSummary {

    /// What a configuration descriptor says: each interface's class and endpoint
    /// count, the total number of endpoints, and how many of those are
    /// isochronous.
    ///
    /// Layouts are from USB 2.0 spec §9.6.3 (configuration, 9 bytes), §9.6.5
    /// (interface, 9 bytes), and §9.6.6 (endpoint, 7 bytes).
    struct Census: Equatable {
        var interfaces: [String] = []
        var endpoints = 0
        var isochronous = 0

        /// The census as one log line.
        var description: String {
            let list = interfaces.isEmpty ? "none" : interfaces.joined(separator: ", ")
            return "interfaces [\(list)], \(endpoints) endpoint\(endpoints == 1 ? "" : "s"), \(isochronous) isochronous"
        }

        /// What this census's isochronous endpoints mean for passthrough, or
        /// `nil` when it has none.
        ///
        /// The rule stated is the framework's, not havm's: "A USB passthrough
        /// device with isochronous endpoints is not supported." is one of its own
        /// messages. It says that for a device it got far enough to inspect — an
        /// accessory macOS never configured is refused before that, with no
        /// message at all, which leaves this census the only place its endpoints
        /// are visible (issue #13).
        var isochronousNote: String? {
            guard isochronous > 0 else { return nil }
            return "\(isochronous) of \(endpoints) endpoints are isochronous — Virtualization does not support passthrough for such devices"
        }
    }

    /// Parses a configuration descriptor, or returns `nil` when there are no
    /// bytes to parse or too few to hold a configuration descriptor.
    static func census(of data: Data?) -> Census? {
        guard let data, data.count >= 9 else { return nil }
        let bytes = [UInt8](data)

        // wTotalLength bounds the configuration. A truncated or hostile
        // descriptor must not walk past the end of the buffer.
        let totalLength = min(Int(bytes[2]) | (Int(bytes[3]) << 8), bytes.count)
        var census = Census()
        var offset = Int(bytes[0])  // skip the configuration descriptor itself
        while offset + 2 <= totalLength {
            let length = Int(bytes[offset])
            // bLength 0 or 1 would never advance the cursor.
            guard length >= 2, offset + length <= totalLength else { break }
            switch bytes[offset + 1] {  // bDescriptorType
            case 4 where length >= 9:  // INTERFACE
                let classCode = bytes[offset + 5]   // bInterfaceClass
                let endpointCount = Int(bytes[offset + 4])  // bNumEndpoints
                census.interfaces.append("\(String(format: "0x%02X", classCode)):\(endpointCount)ep")
            case 5 where length >= 7:  // ENDPOINT
                census.endpoints += 1
                // bmAttributes bits 0-1 hold the transfer type; 1 is isochronous.
                if (bytes[offset + 3] & 0x03) == 0x01 { census.isochronous += 1 }
            default:
                break
            }
            offset += length
        }
        return census
    }

    /// One-line census of a configuration descriptor — the bytes behind
    /// ``AAUSBAccessory/configurationDescriptorData``.
    ///
    /// A `nil` descriptor is not an absent descriptor but an unconfigured
    /// accessory, and reporting it as though a census had been taken would bury
    /// the one fact that makes the failure actionable.
    static func describe(_ data: Data?) -> String {
        guard let data else { return "no configuration selected" }
        guard let census = census(of: data) else {
            // The byte count is the diagnosis. A short descriptor is either
            // AccessoryAccess reporting an unconfigured accessory as an empty
            // `NSData` where it documents `nil`, or a truncated read — and the
            // count is what tells them apart in a log we have to ask for
            // (issue #13).
            return "malformed configuration descriptor (\(data.count) bytes)"
        }
        return census.description
    }
}

// MARK: - Unconfigured accessories

/// Reads the configuration descriptor of an accessory macOS has not configured.
///
/// `VZUSBPassthroughDevice(configuration:)` builds its device from the
/// accessory's *selected* configuration, and an accessory macOS never sent
/// SET_CONFIGURATION to has none: no interfaces, no endpoints, and no
/// ``AAUSBAccessory/configurationDescriptorData``. The framework reports that as
/// `VZErrorDomain -6`, which is not one of its documented USB error codes and
/// arrives with no message of its own (issue #13) — so a census of the device is
/// the only thing that says what the failure was about.
///
/// AccessoryAccess hands havm the accessory's `IOUSBHostDevice`, which reads the
/// descriptor out of the device whether or not a configuration is selected.
/// Reading is all havm does with it. Selecting that configuration — the obvious
/// next step, and what this type used to do — is not attempted, for three
/// reasons:
///
/// - The request is one the stack has already made and lost. An accessory
///   arrives here unconfigured because SET_CONFIGURATION failed upstream, and
///   issue #13's device answers the retry with
///   `IOUSBHostErrorDomain -536870184` (`kIOReturnNotReady`), "Unable to set
///   configuration."
/// - It would be havm's only write to host USB state: a private
///   (`NS_REFINED_FOR_SWIFT`) call on a device macOS owns, changing a state
///   macOS chose, on the chance that an undocumented framework error improves.
/// - It cannot help the devices this exists to explain. The endpoints the census
///   counts are the ones the framework refuses: its own shipped message is "A
///   USB passthrough device with isochronous endpoints is not supported."
///
/// Every device seen to attach — mass storage, Z-Wave, ZigBee — did so without
/// it, on a build that predates it.
@available(macOS 27.0, *)
enum USBAccessoryDescriptor {

    /// The accessory's configuration descriptor, read from the device itself.
    ///
    /// - Returns: the descriptor bytes, or `nil` when the accessory cannot be
    ///   opened or the device has none to offer — each already logged.
    static func read(_ accessory: AAUSBAccessory, logger: Logger) async -> Data? {
        let box: DeviceBox
        do {
            box = try await open(accessory)
        } catch {
            logger.warning("USB: Cannot open \(accessory.registryIDHex) to read its configuration descriptor — \(USBErrorReport.describe(error))")
            return nil
        }
        let data = descriptor(of: box.device, accessory: accessory, logger: logger)
        await close(accessory, logger: logger)
        return data
    }

    /// Reads the configuration descriptor straight from the device.
    private static func descriptor(
        of device: IOUSBHostDevice, accessory: AAUSBAccessory, logger: Logger
    ) -> Data? {
        do {
            // Unlike the cached `configurationDescriptor`, this reads the
            // descriptor out of the device, so it works while unconfigured.
            let descriptor = try device.configurationDescriptor(with: 0)
            return Data(bytes: descriptor, count: Int(descriptor.pointee.wTotalLength))
        } catch {
            logger.warning("USB: Cannot read a configuration descriptor from \(accessory.registryIDHex) — \(USBErrorReport.describe(error))")
            return nil
        }
    }

    /// Carries the device AccessoryAccess hands back out of its completion
    /// handler. The handler is `NS_SWIFT_SENDABLE` and `IOUSBHostDevice` is not,
    /// so the hand-off needs a box; the device never leaves the task that opened
    /// the accessory.
    private struct DeviceBox: @unchecked Sendable {
        let device: IOUSBHostDevice
    }

    private static func open(_ accessory: AAUSBAccessory) async throws -> DeviceBox {
        try await withCheckedThrowingContinuation { continuation in
            accessory.open(serviceQueue: nil) { device, error in
                // The header annotates the device `_Nullable_on_error`, a macro
                // Swift doesn't know, so the importer hands it over as
                // non-optional and the error is what says whether it is usable.
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: DeviceBox(device: device))
            }
        }
    }

    /// Releases the exclusive access ``open(_:)`` took, which the framework —
    /// opening the device itself — needs back.
    private static func close(_ accessory: AAUSBAccessory, logger: Logger) async {
        await withCheckedContinuation { continuation in
            // Not `-[IOUSBHostDevice destroy]`: that call blocks, and deadlocks
            // when it runs from a completion handler (AAUSBAccessory.h).
            accessory.close { error in
                if let error {
                    logger.warning("USB: Cannot release \(accessory.registryIDHex) — \(USBErrorReport.describe(error))")
                }
                continuation.resume()
            }
        }
    }
}
