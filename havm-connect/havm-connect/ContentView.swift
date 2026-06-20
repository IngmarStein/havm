import SwiftUI
import AppKit
import AccessoryAccess
import Observation

// MARK: - Shared paths (must match CLI: USBPath.persistence)

enum USBPath {
    /// ~/Library/Application Support/havm/usb/ — shared with the `havm` CLI.
    static var persistence: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("havm/usb")
            .path
    }
}

// MARK: - Known coordinators

/// Well-known Zigbee and Z-Wave coordinator USB devices.
private struct KnownCoordinator {
    let name: String
    let vendorId: UInt16
    let productId: UInt16
    let protocolType: String  // "zigbee", "z-wave", or "multi"

    static let all: [KnownCoordinator] = [
        // Zigbee
        .init(name: "ConBee II", vendorId: 0x1CF1, productId: 0x0030, protocolType: "zigbee"),
        .init(name: "ConBee III", vendorId: 0x1CF1, productId: 0x0031, protocolType: "zigbee"),
        .init(name: "Home Assistant Connect ZBT-1 / SkyConnect", vendorId: 0x10C4, productId: 0xEA60, protocolType: "zigbee"),
        .init(name: "Home Assistant Connect ZBT-2", vendorId: 0x10C4, productId: 0xEA60, protocolType: "zigbee"),
        .init(name: "Sonoff Zigbee 3.0 Plus (Dongle-E)", vendorId: 0x10C4, productId: 0xEA60, protocolType: "zigbee"),
        .init(name: "Sonoff Zigbee 3.0 Plus (Dongle-P)", vendorId: 0x1A86, productId: 0x7523, protocolType: "zigbee"),
        .init(name: "SMLIGHT SLZB-06", vendorId: 0x10C4, productId: 0xEA60, protocolType: "zigbee"),
        .init(name: "Tube's ZB Gateway", vendorId: 0x1A86, productId: 0x7523, protocolType: "zigbee"),
        .init(name: "ZigStar UZG-01", vendorId: 0x1A86, productId: 0x7523, protocolType: "zigbee"),
        .init(name: "ITead Zigbee 3.0", vendorId: 0x1A86, productId: 0x55D4, protocolType: "zigbee"),
        // Z-Wave
        .init(name: "Aeotec Z-Stick Gen5", vendorId: 0x0658, productId: 0x0200, protocolType: "z-wave"),
        .init(name: "Aeotec Z-Stick Gen7", vendorId: 0x0658, productId: 0x0201, protocolType: "z-wave"),
        .init(name: "Zooz ZST10 / ZST39", vendorId: 0x10C4, productId: 0xEA60, protocolType: "z-wave"),
        .init(name: "Z-Wave.Me Z-Station", vendorId: 0x1A86, productId: 0x55D4, protocolType: "z-wave"),
        // Multi-protocol
        .init(name: "Nortek GoControl HUSBZB-1", vendorId: 0x10C4, productId: 0x8A2A, protocolType: "multi"),
        .init(name: "Home Assistant Yellow", vendorId: 0x10C4, productId: 0x8A2A, protocolType: "multi"),
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
        let listener = OneShotListener()
        AAUSBAccessoryManager.shared.registerListener(
            listener, matchingCriteria: [],
            completionHandler: { [weak self] accessories, error in
                guard let self else { return }
                Task { @MainActor in
                    if let error = error {
                        self.errorMessage = error.localizedDescription
                        return
                    }
                    let savedIDs = Self.loadPersistedIDs()
                    self.devices = accessories.map { acc in
                        let (vid, pid) = Self.parseDescriptor(acc.deviceDescriptorData)
                        return DiscoveredDevice(
                            id: acc.registryID, vendorId: vid, productId: pid,
                            accessory: acc, enabled: savedIDs.contains(acc.registryID)
                        )
                    }
                }
            }
        )
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
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-HUP", "havm"]
        task.standardOutput = Pipe(); task.standardError = Pipe()
        try? task.run()
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

    static func parseDescriptor(_ data: Data) -> (UInt16, UInt16) {
        guard data.count >= 18 else { return (0, 0) }
        let vid = UInt16(data[8]) | (UInt16(data[9]) << 8)
        let pid = UInt16(data[10]) | (UInt16(data[11]) << 8)
        return (vid, pid)
    }
}

private final class OneShotListener: NSObject, AAUSBAccessoryListener, @unchecked Sendable {}

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
                            Text(known.protocolType)
                                .font(.caption).foregroundColor(.blue)
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
                    .listStyle(.inset).frame(minHeight: 200)
            }
            HStack {
                Button("Refresh") { model.refresh() }
                Spacer()
                Button("Cancel") { NSApp.terminate(nil) }.keyboardShortcut(.cancelAction)
                Button("Save & Reload") { model.persist(); NSApp.terminate(nil) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding().frame(minWidth: 480, idealWidth: 480, minHeight: 300)
        .onAppear { model.refresh() }
    }
}
