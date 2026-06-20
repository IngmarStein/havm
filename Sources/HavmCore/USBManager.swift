import Foundation
import Virtualization
import AccessoryAccess
import Logging

// MARK: - USB Manager

/// Reads persisted USB accessory files (written by havm-connect) and creates
/// VZUSBPassthroughDeviceConfiguration objects for the VM.
///
/// USB passthrough requires the havm-connect app:
///   1. havm-connect  — discovers devices via AAUSBAccessoryManager (needs
///                     Dock app), persists AAUSBAccessory objects to
///                     ~/Library/Application Support/havm/usb/
///   2. havm run     — reads persisted files, creates passthrough configs
///                     for the VM via VZUSBPassthroughDeviceConfiguration
///
/// AAUSBAccessory conforms to NSSecureCoding and is designed for cross-process
/// transfer (it also supports XPC transport). The CLI links AccessoryAccess
/// for the type, but AAUSBAccessoryManager (device discovery) requires a Dock app.
///
/// USB passthrough requires the `com.apple.developer.accessory-access.usb`
/// entitlement (paid Apple Developer account + provisioning profile).
public final class USBManager: @unchecked Sendable {
    private let logger: Logger
    private let config: HavmConfig

    public init(config: HavmConfig, logger: Logger = Logger(label: "havm.usb")) {
        self.config = config
        self.logger = logger
    }

    // MARK: - Persisted accessory listing

    /// List persisted accessories from havm-connect.
    public static func listPersistedAccessories() -> [(registryID: UInt64, vendorId: UInt16, productId: UInt16)] {
        let accessories = loadPersistedAccessories()
        return accessories.map { acc in
            let (vid, pid) = parseUSBDescriptor(acc.deviceDescriptorData)
            return (acc.registryID, vid, pid)
        }
    }

    // MARK: - Passthrough configuration for VM

    /// Create passthrough configurations from persisted accessory files.
    /// Each persisted AAUSBAccessory is wrapped in a VZUSBPassthroughDeviceConfiguration.
    public func buildPassthroughConfigurations() -> [any VZUSBDeviceConfiguration] {
        guard config.effectiveUSBEnabled else { return [] }

        let accessories = Self.loadPersistedAccessories()
        guard !accessories.isEmpty else { return [] }

        logger.info("USB: Attaching \(accessories.count) paired device(s)")
        return accessories.map { acc in
            VZUSBPassthroughDeviceConfiguration(device: acc)
        }
    }

    // MARK: - Persistence

    /// Load persisted AAUSBAccessory objects from disk.
    /// AAUSBAccessory conforms to NSSecureCoding, making it safe for
    /// cross-process persistence via NSKeyedArchiver/NSKeyedUnarchiver.
    private static func loadPersistedAccessories() -> [AAUSBAccessory] {
        var result: [AAUSBAccessory] = []
        let usbDir = HavmConfig.usbPersistenceDirectory

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: usbDir) else {
            return result
        }

        for file in files where file.hasSuffix(".accessory") {
            let path = (usbDir as NSString).appendingPathComponent(file)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let acc = try? NSKeyedUnarchiver.unarchivedObject(
                    ofClass: AAUSBAccessory.self, from: data
                  ) else { continue }
            result.append(acc)
        }
        return result
    }

    // MARK: - USB descriptor parsing

    /// Extract vendor and product IDs from a USB device descriptor.
    /// Descriptor format: VID at bytes 8-9, PID at bytes 10-11 (little-endian).
    private static func parseUSBDescriptor(_ data: Data) -> (UInt16, UInt16) {
        guard data.count >= 18 else { return (0, 0) }
        let vid = UInt16(data[8]) | (UInt16(data[9]) << 8)
        let pid = UInt16(data[10]) | (UInt16(data[11]) << 8)
        return (vid, pid)
    }
}
