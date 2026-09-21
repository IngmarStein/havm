import Foundation
import Testing
import Virtualization
@testable import HavmCore

/// Regression tests for the CONFIG disk wiring.
///
/// The disk can only reach the guest as a child of an XHCI controller, so
/// gating the controller on `usb.enabled` silently dropped it and killed SSH
/// on port 22222 (issue #12). `usb.enabled` governs accessory passthrough.
@Suite struct VMControllerTests {

    /// A real CONFIG disk image on disk, handed to `body` as a file path.
    private func withConfigDisk<T>(_ body: (String) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("havm-config-\(UUID().uuidString).img")
        let disk = CONFIGDiskBuilder.build(
            authorizedKey: Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA test\n".utf8)
        )
        try disk.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url.path)
    }

    /// A path that exists only long enough to name a file that isn't there.
    private func missingConfigDiskPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("havm-absent-\(UUID().uuidString).img")
            .path
    }

    @Test("CONFIG disk is attached when USB passthrough is disabled")
    func configDiskSurvivesUSBDisabled() throws {
        try withConfigDisk { path in
            let controller = try VMController.makeUSBController(
                configDiskPath: path,
                usbEnabled: false
            )
            let usbDevices = try #require(
                controller?.usbDevices,
                "CONFIG disk must create the controller that carries it"
            )
            #expect(usbDevices.contains { $0 is VZUSBMassStorageDeviceConfiguration })
        }
    }

    @Test("Controller is provisioned for hot-attach when USB is enabled")
    func controllerExistsForPassthrough() throws {
        let controller = try VMController.makeUSBController(
            configDiskPath: missingConfigDiskPath(),
            usbEnabled: true
        )
        #expect(controller?.usbDevices.isEmpty == true,
                "No devices at boot, but accessories need a controller to attach to")
    }

    @Test("No controller without a CONFIG disk or passthrough")
    func noControllerWithoutDevicesOrPassthrough() throws {
        let controller = try VMController.makeUSBController(
            configDiskPath: missingConfigDiskPath(),
            usbEnabled: false
        )
        #expect(controller == nil)
    }
}
