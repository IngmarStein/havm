import ArgumentParser
import Foundation
import HavmCore

struct ListUSBCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-usb",
        abstract: "List USB devices persisted for passthrough by havm-helper."
    )

    func run() async throws {
        let devices = USBManager.listPersistedAccessories()

        if devices.isEmpty {
            print("No persisted USB devices found.")
            print("")
            print("Use the havm-helper app to discover and select USB devices")
            print("for passthrough to the VM:")
            print("")
            print("  havm-helper")
            return
        }

        print("Persisted USB devices (from havm-helper):")
        for device in devices {
            let id = String(format: "0x%04X:0x%04X", device.vendorId, device.productId)
            print("  registryID \(device.registryID)  \(id)")
        }
    }
}
