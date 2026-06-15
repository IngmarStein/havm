import ArgumentParser
import Foundation
import HavmCore

struct ListUSBCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-usb",
        abstract: "List USB devices available for passthrough."
    )

    func run() async throws {
        let devices = USBManager.listPersistedAccessories()

        if !devices.isEmpty {
            print("Persisted USB devices (from havm-helper):")
            for device in devices {
                let id = String(format: "0x%04X:0x%04X", device.vendorId, device.productId)
                let known = USBManager.matchKnownCoordinator(
                    vendorId: device.vendorId, productId: device.productId
                )
                let label = known.map { " → \($0.name) (\($0.protocolType.rawValue))" } ?? ""
                print("  \(id)\(label)")
            }
            return
        }

        print("No persisted USB devices found.")
        print("")
        print("USB passthrough requires the havm-helper app (runs once to discover")
        print("and persist devices). Run it first:")
        print("")
        print("  havm-helper")
        print("")
        print("Known coordinators that will be auto-detected:")
        for coordinator in KnownCoordinator.all {
            let id = String(format: "0x%04X:0x%04X", coordinator.vendorId, coordinator.productId)
            print("  \(id)  \(coordinator.name) (\(coordinator.protocolType.rawValue))")
        }
    }
}
