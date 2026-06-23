import ArgumentParser
import Foundation
import HavmCore

struct ListUSBCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-usb",
        abstract: "List USB devices paired with the VM."
    )

    func run() throws {
        let devices = USBManager.listPersistedAccessories()

        if devices.isEmpty {
            print("No paired USB devices.")
            print("")
            print("Run 'havm run' and use the menu bar item to select which")
            print("to attach to the VM.")
            return
        }

        print("Paired devices:")
        for device in devices {
            let id = String(format: "0x%04X:0x%04X", device.vendorId, device.productId)
            print("  registryID \(device.registryID)  \(id)")
        }
    }
}
