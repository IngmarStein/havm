import SwiftUI
import AppKit
import AccessoryAccess
import Observation
import os

// MARK: - Shared paths (must match CLI: USBPath.persistence)

enum USBPath {
    /// Shared app group container — HA VM Connect (sandboxed) and havm CLI
    /// both access this path via the ch.ingmar.havm group.
    static var persistence: String {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "ch.ingmar.havm"
        )!
            .appendingPathComponent("usb")
            .path
    }
}

// MARK: - Known coordinators

/// Well-known coordinator USB devices.
private struct KnownCoordinator {
    let name: String
    let vendorId: UInt16
    let productId: UInt16

    static let all: [KnownCoordinator] = [
        .init(name: "ConBee II", vendorId: 0x1CF1, productId: 0x0030),
        .init(name: "ConBee III", vendorId: 0x1CF1, productId: 0x0031),
        .init(name: "Home Assistant Connect ZBT-1 / SkyConnect", vendorId: 0x10C4, productId: 0xEA60),
        .init(name: "Home Assistant Connect ZBT-2", vendorId: 0x10C4, productId: 0xEA60),
        .init(name: "Sonoff Zigbee 3.0 Plus (Dongle-E)", vendorId: 0x10C4, productId: 0xEA60),
        .init(name: "Sonoff Zigbee 3.0 Plus (Dongle-P)", vendorId: 0x1A86, productId: 0x7523),
        .init(name: "SMLIGHT SLZB-06", vendorId: 0x10C4, productId: 0xEA60),
        .init(name: "Tube's ZB Gateway", vendorId: 0x1A86, productId: 0x7523),
        .init(name: "ZigStar UZG-01", vendorId: 0x1A86, productId: 0x7523),
        .init(name: "ITead Zigbee 3.0", vendorId: 0x1A86, productId: 0x55D4),
        .init(name: "Aeotec Z-Stick Gen5", vendorId: 0x0658, productId: 0x0200),
        .init(name: "Aeotec Z-Stick Gen7", vendorId: 0x0658, productId: 0x0201),
        .init(name: "Zooz ZST10 / ZST39", vendorId: 0x10C4, productId: 0xEA60),
        .init(name: "Z-Wave.Me Z-Station", vendorId: 0x1A86, productId: 0x55D4),
        .init(name: "Nortek GoControl HUSBZB-1", vendorId: 0x10C4, productId: 0x8A2A),
        .init(name: "Home Assistant Yellow", vendorId: 0x10C4, productId: 0x8A2A),
    ]
}

// MARK: - App Entry

@main
struct HavmConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {}
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

// MARK: - Helpers

/// Extract vendor and product IDs from a USB device descriptor.
/// Descriptor format: VID at bytes 8-9, PID at bytes 10-11 (little-endian).
func parseDescriptor(_ data: Data) -> (UInt16, UInt16) {
    guard data.count >= 18 else { return (0, 0) }
    let vid = UInt16(data[8]) | (UInt16(data[9]) << 8)
    let pid = UInt16(data[10]) | (UInt16(data[11]) << 8)
    return (vid, pid)
}

// MARK: - Model

@MainActor
@Observable
final class USBDeviceModel {
    var devices: [DiscoveredDevice] = []
    var errorMessage: String?

    struct DiscoveredDevice: Identifiable {
        let id: UInt64
        let vendorId: UInt16
        let productId: UInt16
        let accessory: AAUSBAccessory
        var enabled: Bool
    }

    func refresh() {
        errorMessage = nil
        Self.registerOnce(model: self)
    }

    private static var listenerRegistered = false
    private static let accessoryListener = AccessoryListener()

    private static func registerOnce(model: USBDeviceModel) {
        guard !listenerRegistered else { return }
        listenerRegistered = true

        os_log("registering AAUSBAccessoryListener with matchingCriteria: []")

        accessoryListener.onConnect = { [weak model] acc in
            model?.addDevice(acc)
        }
        accessoryListener.onDisconnect = { [weak model] acc in
            model?.removeDevice(acc)
        }

        AAUSBAccessoryManager.shared.registerListener(
            accessoryListener, matchingCriteria: [],
            completionHandler: { accessories, error in
                Task { @MainActor in
                    if let error = error {
                        os_log("AAUSBAccessoryManager registration error: \(error)")
                        model.errorMessage = error.localizedDescription
                        return
                    }
                    os_log("AAUSBAccessoryManager registered — \(accessories.count) currently connected")
                    for (i, acc) in accessories.enumerated() {
                        let (vid, pid) = parseDescriptor(acc.deviceDescriptorData)
                        os_log("  [\(i)] registryID=\(acc.registryID) vid=0x\(String(vid, radix: 16)) pid=0x\(String(pid, radix: 16))")
                        model.addDevice(acc)
                    }
                }
            }
        )
    }

    private func addDevice(_ acc: AAUSBAccessory) {
        let (vid, pid) = parseDescriptor(acc.deviceDescriptorData)
        let savedIDs = Self.loadPersistedIDs()
        if !devices.contains(where: { $0.id == acc.registryID }) {
            devices.append(DiscoveredDevice(
                id: acc.registryID, vendorId: vid, productId: pid,
                accessory: acc, enabled: savedIDs.contains(acc.registryID)
            ))
        }
    }

    private func removeDevice(_ acc: AAUSBAccessory) {
        devices.removeAll { $0.id == acc.registryID }
    }

    func toggle(_ device: DiscoveredDevice) {
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            devices[idx].enabled.toggle()
        }
    }

    func persist() {
        let usbDir = USBPath.persistence
        try? FileManager.default.createDirectory(atPath: usbDir, withIntermediateDirectories: true)
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: usbDir) {
            for file in existing where file.hasSuffix(".accessory") {
                try? FileManager.default.removeItem(atPath: (usbDir as NSString).appendingPathComponent(file))
            }
        }
        for device in devices where device.enabled {
            let path = (usbDir as NSString).appendingPathComponent("\(device.id).accessory")
            if let data = try? NSKeyedArchiver.archivedData(
                withRootObject: device.accessory, requiringSecureCoding: true
            ) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        signalCLI()
    }

    private func signalCLI() {
        // Read the PID file written by havm to send SIGHUP directly.
        let pidPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/havm/vm/havm.pid")
        guard let pidString = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = pid_t(pidString.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return }
        kill(pid, SIGHUP)
    }

    static func loadPersistedIDs() -> Set<UInt64> {
        guard let files = try? FileManager.default.contentsOfDirectory(
            atPath: USBPath.persistence
        ) else { return [] }
        var ids = Set<UInt64>()
        for file in files where file.hasSuffix(".accessory") {
            if let id = UInt64(file.replacingOccurrences(of: ".accessory", with: "")) {
                ids.insert(id)
            }
        }
        return ids
    }

}

private final class AccessoryListener: NSObject, AAUSBAccessoryListener, @unchecked Sendable {
    var onConnect: ((AAUSBAccessory) -> Void)?
    var onDisconnect: ((AAUSBAccessory) -> Void)?

    func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        let (vid, pid) = parseDescriptor(usbAccessory.deviceDescriptorData)
        os_log("usbAccessoryDidConnect registryID=\(usbAccessory.registryID) vid=0x\(String(vid, radix: 16)) pid=0x\(String(pid, radix: 16))")
        Task { @MainActor in
            onConnect?(usbAccessory)
        }
    }

    func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        os_log("usbAccessoryDidDisconnect registryID=\(usbAccessory.registryID)")
        Task { @MainActor in
            onDisconnect?(usbAccessory)
        }
    }
}

// MARK: - Views

struct DeviceRow: View {
    let model: USBDeviceModel
    let device: USBDeviceModel.DiscoveredDevice

    var body: some View {
        HStack {
            Toggle(isOn: Binding(get: { device.enabled }, set: { _ in model.toggle(device) })) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(String(format: "0x%04X:0x%04X", device.vendorId, device.productId))
                            .font(.system(.body, design: .monospaced))
                        if let known = KnownCoordinator.all.first(where: {
                            $0.vendorId == device.vendorId && $0.productId == device.productId
                        }) {
                            Text("→ \(known.name)").foregroundColor(.secondary)
                        }
                    }
                }
            }
        }.padding(.vertical, 2)
    }
}

struct ContentView: View {
    @State private var model = USBDeviceModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HAVM Connect").font(.title2).bold()
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow).font(.callout)
            }
            if model.devices.isEmpty {
                Text("No USB devices found.").foregroundColor(.secondary).padding(.vertical)
            } else {
                List { ForEach(model.devices) { DeviceRow(model: model, device: $0) } }
                    .listStyle(.inset)
            }
            Spacer()
            HStack {
                Button("Refresh") { model.refresh() }
                Spacer()
                Button("Cancel") { NSApp.terminate(nil) }.keyboardShortcut(.cancelAction)
                Button("Save") { model.persist(); NSApp.terminate(nil) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding().frame(minWidth: 480, idealWidth: 480, minHeight: 300)
        .onAppear { model.refresh() }
    }
}
