import Foundation
import Virtualization
import Logging

// MARK: - USB Manager

/// Reads persisted USB accessory files (written by havm-helper) and creates
/// VZUSBPassthroughDeviceConfiguration objects for the VM.
///
/// USB passthrough requires the havm-helper app to run first:
///   havm-helper           # discovers devices, persists to ~/Library/Application Support/havm/usb/
///   havm run              # reads persisted files, attaches to VM
///
/// Note: This module intentionally does NOT import AccessoryAccess.
/// Importing that framework appears to cause hangs on macOS 27 beta when
/// the entitlement is missing. The NSKeyedUnarchiver calls use NSObject
/// to avoid needing the AAUSBAccessory type at compile time.
public final class USBManager: @unchecked Sendable {
    private let logger: Logger
    private let config: HavmConfig

    public init(config: HavmConfig, logger: Logger = Logger(label: "havm.usb")) {
        self.config = config
        self.logger = logger
    }

    // MARK: - Known coordinator detection

    public static func matchKnownCoordinator(vendorId: UInt16, productId: UInt16) -> KnownCoordinator? {
        KnownCoordinator.all.first { $0.vendorId == vendorId && $0.productId == productId }
    }

    // MARK: - Persisted accessory listing

    /// List persisted accessories with their vendor/product IDs.
    /// Uses generic NSKeyedUnarchiver — no AccessoryAccess import needed.
    public static func listPersistedAccessories() -> [(registryID: UInt64, vendorId: UInt16, productId: UInt16)] {
        var result: [(UInt64, UInt16, UInt16)] = []
        let usbDir = HavmConfig.usbPersistenceDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: usbDir) else { return result }

        for file in files where file.hasSuffix(".accessory") {
            let path = (usbDir as NSString).appendingPathComponent(file)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            // Use NSObject base class — the actual class is AAUSBAccessory but
            // we can't reference it without importing AccessoryAccess
            guard let acc = try? NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSObject.self], from: data
            ) as? NSObject else { continue }
            // Read registryID via KVC, device descriptor via KVC
            let registryID = (acc.value(forKey: "registryID") as? NSNumber)?.uint64Value ?? 0
            // Read deviceDescriptorData and parse vendor/product
            if let descData = acc.value(forKey: "deviceDescriptorData") as? Data,
               descData.count >= 18 {
                let (vid, pid) = parseUSBDescriptor(descData)
                result.append((registryID, vid, pid))
            }
        }
        return result
    }

    private static func parseUSBDescriptor(_ data: Data) -> (UInt16, UInt16) {
        return data.withUnsafeBytes { ptr in
            let raw = ptr.bindMemory(to: UInt8.self)
            return (UInt16(raw[8]) | (UInt16(raw[9]) << 8),
                    UInt16(raw[10]) | (UInt16(raw[11]) << 8))
        }
    }

    // MARK: - Passthrough configuration for VM

    /// Create passthrough configurations from persisted accessory files.
    /// Returns empty array when AccessoryAccess is not importable (always, from CLI).
    /// The havm-helper app handles the actual passthrough configuration when
    /// the entitlement is available.
    public func buildPassthroughConfigurations() -> [any VZUSBDeviceConfiguration] {
        // USB passthrough requires AccessoryAccess framework which can only
        // be imported from a Dock application (havm-helper), not the CLI.
        // The persisted files are handled by the helper app.
        return []
    }
}
