import Foundation

/// Publishes the guest's readiness for the metrics endpoint.
///
/// Two metrics rather than one labelled one:
///
/// - `havm_guest_ready` is 0 or 1 with no labels — the series a dashboard or an
///   alert watches. It is one series for the life of the process, whatever the
///   guest does.
/// - `havm_guest_info{url="…"}` is 1 while Home Assistant answers, carrying the
///   address in a label of its own. Putting the address on the ready gauge
///   instead would make every new DHCP lease end one time series and start
///   another, which is the churn alerts trip over.
///
/// The previous address's info series is removed when the address changes: a
/// lease that moved would otherwise leave a series behind for every address the
/// guest ever had. Removal, not a zero — a series that is gone is what
/// Prometheus reports as stale, where a zero would say the address is current
/// and the guest is not ready there.
///
/// Written from `ServiceRuntime.applyGuestStatus`, which runs on the main
/// thread; `infoURL` relies on that.
final class GuestStatusMetrics {
    private let registry: SimpleRegistry
    /// The address the info series currently carries, if any.
    private var infoURL: String?

    init(registry: SimpleRegistry) {
        self.registry = registry
    }

    func record(_ status: GuestStatus) {
        registry.record(name: "havm_guest_ready", labels: [], value: status.isReady ? 1 : 0)

        let url = status.readyURL?.absoluteString
        if let previous = infoURL, previous != url {
            registry.remove(name: "havm_guest_info", labels: [("url", previous)])
            infoURL = nil
        }
        guard let url else { return }
        registry.record(name: "havm_guest_info", labels: [("url", url)], value: 1)
        infoURL = url
    }
}
