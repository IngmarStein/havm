import Foundation
import Virtualization
import Logging

// MARK: - USB Manager

/// Reads persisted USB accessory files (written by havm-helper) and creates
/// VZUSBPassthroughDeviceConfiguration objects for the VM.
///
/// USB passthrough requires the havm-helper app:
///   1. havm-helper  — discovers devices, persists accessories to
///                     ~/Library/Application Support/havm/usb/
///   2. havm run     — reads persisted files, attaches to VM
///
/// Currently returns empty — USB passthrough requires the
/// `com.apple.developer.accessory-access.usb` entitlement (paid Apple
/// Developer account + provisioning profile) and the AccessoryAccess
/// framework (only available from a Dock application).
public final class USBManager: @unchecked Sendable {
    private let logger: Logger
    private let config: HavmConfig

    public init(config: HavmConfig, logger: Logger = Logger(label: "havm.usb")) {
        self.config = config
        self.logger = logger
    }

    // MARK: - Persisted accessory listing

    /// List persisted accessories from havm-helper.
    public static func listPersistedAccessories() -> [(registryID: UInt64, vendorId: UInt16, productId: UInt16)] {
        var result: [(UInt64, UInt16, UInt16)] = []
        let usbDir = HavmConfig.usbPersistenceDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: usbDir) else { return result }

        for file in files where file.hasSuffix(".accessory") {
            let path = (usbDir as NSString).appendingPathComponent(file)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            guard let acc = try? NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSObject.self], from: data
            ) as? NSObject else { continue }
            let registryID = (acc.value(forKey: "registryID") as? NSNumber)?.uint64Value ?? 0
            if let descData = acc.value(forKey: "deviceDescriptorData") as? Data, descData.count >= 18 {
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
    public func buildPassthroughConfigurations() -> [any VZUSBDeviceConfiguration] {
        return []
    }
}
