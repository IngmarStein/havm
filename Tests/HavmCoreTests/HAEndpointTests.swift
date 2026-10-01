import Foundation
import Testing
@testable import HavmCore

@Suite struct HAEndpointTests {

    @Test("Port-less form carries no port")
    func portlessForm() {
        #expect(HAEndpoint.baseURL(host: "homeassistant.local", port: nil) == "http://homeassistant.local")
    }

    @Test("Explicit port is appended")
    func explicitPort() {
        #expect(HAEndpoint.baseURL(host: "homeassistant.local", port: 8123) == "http://homeassistant.local:8123")
        #expect(HAEndpoint.baseURL(host: "192.168.1.50", port: 8123) == "http://192.168.1.50:8123")
    }

    @Test("IPv6 literals are bracketed")
    func ipv6Bracketing() {
        #expect(HAEndpoint.baseURL(host: "fd00::1", port: nil) == "http://[fd00::1]")
        #expect(HAEndpoint.baseURL(host: "fd00::1", port: 8123) == "http://[fd00::1]:8123")
    }

    /// A bare IPv6 literal in a URL authority parses as host-and-port rather
    /// than failing outright, so compare through the parser instead of strings.
    @Test("Every candidate parses to the host and port it was built from",
          arguments: HAEndpoint.probePorts)
    func candidatesParse(port: Int?) {
        let url = URL(string: HAEndpoint.baseURL(host: "fd00::1", port: port))
        #expect(url?.host() == "fd00::1")
        #expect(url?.port ?? 80 == port ?? 80)
    }

    /// HAOS 2026.8 gave new installs the port-less address and left existing
    /// ones on 8123. New installs are what `havm run` produces from here on,
    /// so they are probed first — and a wrong guess costs one refused
    /// connection, which returns immediately.
    @Test("The port-less default is probed before the pre-2026.8 port")
    func probeOrder() {
        #expect(HAEndpoint.probePorts == [nil, 8123])
    }
}
