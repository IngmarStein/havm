import Foundation
import Testing
@testable import HavmCore

/// What `/metrics` says about the guest.
///
/// The two properties that matter: readiness is one stable series whatever the
/// guest does, and the address lives on a series of its own that is removed
/// rather than zeroed when the guest moves.
@Suite struct GuestStatusMetricsTests {

    private let urlA = URL(string: "http://homeassistant.local")!
    private let urlB = URL(string: "http://192.168.64.5:8123")!

    @Test func bootingIsNotReady() {
        let registry = SimpleRegistry()
        let metrics = GuestStatusMetrics(registry: registry)

        metrics.record(.booting)
        let output = registry.emit()
        #expect(output.contains("havm_guest_ready 0.0"))
        #expect(!output.contains("havm_guest_info"))
    }

    @Test func answeringIsReadyAndNamesTheAddress() {
        let registry = SimpleRegistry()
        let metrics = GuestStatusMetrics(registry: registry)

        metrics.record(.ready(urlA))
        let output = registry.emit()
        #expect(output.contains("havm_guest_ready 1.0"))
        #expect(output.contains(#"havm_guest_info{url="http://homeassistant.local"} 1.0"#))
    }

    /// A new address ends the old series instead of leaving it behind: a guest
    /// that moves leases would otherwise accumulate one `url` per address.
    @Test func aNewAddressReplacesTheOldOne() {
        let registry = SimpleRegistry()
        let metrics = GuestStatusMetrics(registry: registry)

        metrics.record(.ready(urlA))
        metrics.record(.ready(urlB))
        let output = registry.emit()
        #expect(output.contains("http://192.168.64.5:8123"))
        #expect(!output.contains("http://homeassistant.local"))
        #expect(output.contains("havm_guest_ready 1.0"))
    }

    @Test func givingUpClearsBothMetrics() {
        let registry = SimpleRegistry()
        let metrics = GuestStatusMetrics(registry: registry)

        metrics.record(.ready(urlA))
        metrics.record(.unreachable)
        let output = registry.emit()
        #expect(output.contains("havm_guest_ready 0.0"))
        #expect(!output.contains("havm_guest_info"))
    }

    @Test func theSameStatusRecordedTwiceLeavesOneSeries() {
        let registry = SimpleRegistry()
        let metrics = GuestStatusMetrics(registry: registry)

        metrics.record(.ready(urlA))
        metrics.record(.ready(urlA))
        let samples = registry.emit()
            .split(separator: "\n")
            .filter { $0.hasPrefix("havm_guest_info{") }
        #expect(samples.count == 1)
    }
}
