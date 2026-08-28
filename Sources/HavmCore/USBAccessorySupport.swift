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
        logger.info("USB: Accessory connected — 0x\(String(vid, radix: 16, uppercase: true)):0x\(String(pid, radix: 16, uppercase: true)) (registryID=\(accessory.registryID))")
        vmController?.attachAccessory(accessory)
        accessoryCount += 1
        Gauge(label: "havm_usb_accessories").record(Double(accessoryCount))
    }

    func usbAccessoryDidDisconnect(_ accessory: AAUSBAccessory) {
        let (vid, pid) = accessory.vendorProductID
        logger.info("USB: Accessory disconnected — 0x\(String(vid, radix: 16, uppercase: true)):0x\(String(pid, radix: 16, uppercase: true)) (registryID=\(accessory.registryID))")
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
}
