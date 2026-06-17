/// Well-known Zigbee and Z-Wave coordinator USB devices, auto-detected for passthrough.
public struct KnownCoordinator: Sendable {
    public let name: String
    public let vendorId: UInt16
    public let productId: UInt16
    public let protocolType: ProtocolType

    public enum ProtocolType: String, Sendable {
        case zigbee
        case zwave = "z-wave"
        case multi    // both Zigbee and Z-Wave
    }

    public init(name: String, vendorId: UInt16, productId: UInt16, protocolType: ProtocolType) {
        self.name = name
        self.vendorId = vendorId
        self.productId = productId
        self.protocolType = protocolType
    }

    /// All known coordinators. Matched against connected USB devices.
    public static let all: [KnownCoordinator] = [
        // Zigbee
        KnownCoordinator(name: "ConBee II", vendorId: 0x1CF1, productId: 0x0030, protocolType: .zigbee),
        KnownCoordinator(name: "ConBee III", vendorId: 0x1CF1, productId: 0x0031, protocolType: .zigbee),
        KnownCoordinator(name: "Home Assistant Connect ZBT-1 / SkyConnect", vendorId: 0x10C4, productId: 0xEA60, protocolType: .zigbee),
        // ZBT-2 shares VID/PID with ZBT-1 — both use the same Silicon Labs EFR32MG21 chip.
        KnownCoordinator(name: "Home Assistant Connect ZBT-2", vendorId: 0x10C4, productId: 0xEA60, protocolType: .zigbee),
        KnownCoordinator(name: "Sonoff Zigbee 3.0 Plus (Dongle-E)", vendorId: 0x10C4, productId: 0xEA60, protocolType: .zigbee),
        KnownCoordinator(name: "Sonoff Zigbee 3.0 Plus (Dongle-P)", vendorId: 0x1A86, productId: 0x7523, protocolType: .zigbee),
        KnownCoordinator(name: "SMLIGHT SLZB-06", vendorId: 0x10C4, productId: 0xEA60, protocolType: .zigbee),
        KnownCoordinator(name: "Tube's ZB Gateway", vendorId: 0x1A86, productId: 0x7523, protocolType: .zigbee),
        KnownCoordinator(name: "ZigStar UZG-01", vendorId: 0x1A86, productId: 0x7523, protocolType: .zigbee),
        KnownCoordinator(name: "ITead Zigbee 3.0", vendorId: 0x1A86, productId: 0x55D4, protocolType: .zigbee),

        // Z-Wave
        KnownCoordinator(name: "Aeotec Z-Stick Gen5", vendorId: 0x0658, productId: 0x0200, protocolType: .zwave),
        KnownCoordinator(name: "Aeotec Z-Stick Gen7", vendorId: 0x0658, productId: 0x0201, protocolType: .zwave),
        KnownCoordinator(name: "Zooz ZST10 / ZST39", vendorId: 0x10C4, productId: 0xEA60, protocolType: .zwave),
        KnownCoordinator(name: "Z-Wave.Me Z-Station", vendorId: 0x1A86, productId: 0x55D4, protocolType: .zwave),

        // Multi-protocol
        KnownCoordinator(name: "Nortek GoControl HUSBZB-1", vendorId: 0x10C4, productId: 0x8A2A, protocolType: .multi),
        KnownCoordinator(name: "Home Assistant Yellow", vendorId: 0x10C4, productId: 0x8A2A, protocolType: .multi),
    ]
}
