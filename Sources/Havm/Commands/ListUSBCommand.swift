import ArgumentParser
import Foundation
import HavmCore

struct ListUSBCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-usb",
        abstract: "List USB devices paired with the VM."
    )

    func run() async throws {
        let devices = USBManager.listPersistedAccessories()

        if devices.isEmpty {
            print("No paired USB devices.")
            print("")
            print("Open HAVM Connect to select which USB accessories")
            print("to attach to the VM:")
            print("")
            print("  HAVM Connect.app")
            return
        }

        print("Paired devices:")
        for device in devices {
            let id = String(format: "0x%04X:0x%04X", device.vendorId, device.productId)
            print("  registryID \(device.registryID)  \(id)")
        }
    }
}
