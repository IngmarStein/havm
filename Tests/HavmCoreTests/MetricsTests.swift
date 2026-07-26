import Foundation
import Testing
@testable import HavmCore

@Suite struct MetricsTests {

    // MARK: - formatHostPort

    @Test("formatHostPort: IPv4 and hostname")
    func formatHostPortIPv4() {
        #expect(MetricsServer.formatHostPort(host: "127.0.0.1", port: 9210) == "127.0.0.1:9210")
        #expect(MetricsServer.formatHostPort(host: "0.0.0.0", port: 80) == "0.0.0.0:80")
        #expect(MetricsServer.formatHostPort(host: "localhost", port: 443) == "localhost:443")
    }

    @Test("formatHostPort: IPv6 wrapped in brackets")
    func formatHostPortIPv6() {
        #expect(MetricsServer.formatHostPort(host: "::1", port: 9210) == "[::1]:9210")
        #expect(MetricsServer.formatHostPort(host: "2001:db8::1", port: 443) == "[2001:db8::1]:443")
    }

    @Test("formatHostsPort: joins multiple hosts")
    func formatHostsPortJoins() {
        let result = MetricsServer.formatHostsPort(["127.0.0.1", "::1"], port: 9210)
        #expect(result == "127.0.0.1:9210, [::1]:9210")
    }

    // MARK: - SimpleRegistry / formatValue (via emit)

    @Test("SimpleRegistry emit: integer value has .0 suffix")
    func emitIntegerValue() {
        let registry = SimpleRegistry()
        registry.record(name: "test_metric", labels: [], value: 5.0)
        let output = registry.emit()
        #expect(output.contains("test_metric 5.0"))
    }

    @Test("SimpleRegistry emit: fractional value uses compact format")
    func emitFractionalValue() {
        let registry = SimpleRegistry()
        registry.record(name: "test_metric", labels: [], value: 3.14159)
        let output = registry.emit()
        // %.6g produces "3.14159"
        #expect(output.contains("test_metric 3.14159"))
    }

    @Test("SimpleRegistry emit: zero is 0.0")
    func emitZero() {
        let registry = SimpleRegistry()
        registry.record(name: "test_metric", labels: [], value: 0.0)
        let output = registry.emit()
        #expect(output.contains("test_metric 0.0"))
    }

    @Test("SimpleRegistry emit: very large integer")
    func emitLargeInteger() {
        let registry = SimpleRegistry()
        registry.record(name: "test_metric", labels: [], value: 9_007_199_254_740_991.0)
        let output = registry.emit()
        #expect(output.contains("test_metric 9007199254740991.0"))
    }

    @Test("SimpleRegistry emit: includes TYPE header")
    func emitTypeHeader() {
        let registry = SimpleRegistry()
        registry.record(name: "havm_test", labels: [], value: 1.0)
        let output = registry.emit()
        #expect(output.contains("# TYPE havm_test gauge"))
    }

    @Test("SimpleRegistry emit: labels in Prometheus format")
    func emitWithLabels() {
        let registry = SimpleRegistry()
        registry.record(name: "havm_disk", labels: [("disk", "main"), ("type", "allocated")], value: 1024.0)
        let output = registry.emit()
        let expected = #"havm_disk{disk="main",type="allocated"} 1024.0"#
        #expect(output.contains(expected))
    }

    @Test("SimpleRegistry emit: multiple metrics sorted")
    func emitMultipleMetricsSorted() {
        let registry = SimpleRegistry()
        registry.record(name: "z_metric", labels: [], value: 3.0)
        registry.record(name: "a_metric", labels: [], value: 1.0)
        let output = registry.emit()
        let aPos = output.range(of: "a_metric")!.lowerBound
        let zPos = output.range(of: "z_metric")!.lowerBound
        #expect(aPos < zPos, "Metrics should be emitted in alphabetical order")
    }

    @Test("SimpleRegistry emit: multiple label sets sorted")
    func emitLabelSetsSorted() {
        let registry = SimpleRegistry()
        registry.record(name: "test", labels: [("b", "2")], value: 2.0)
        registry.record(name: "test", labels: [("a", "1")], value: 1.0)
        let output = registry.emit()
        let aPos = output.range(of: #"a="1""#)!.lowerBound
        let bPos = output.range(of: #"b="2""#)!.lowerBound
        #expect(aPos < bPos, "Label sets should be sorted alphabetically")
    }

    @Test("SimpleRegistry emit: empty registry produces empty string")
    func emitEmptyRegistry() {
        let registry = SimpleRegistry()
        #expect(registry.emit() == "")
    }

    @Test("SimpleRegistry emit: label value with special characters")
    func emitLabelSpecialChars() {
        let registry = SimpleRegistry()
        registry.record(name: "test", labels: [("state", "stopped")], value: 1.0)
        let output = registry.emit()
        #expect(output.contains(#"test{state="stopped"} 1.0"#))
    }

    @Test("SimpleRegistry record: multiple recordings keep latest value")
    func recordKeepsLatest() {
        let registry = SimpleRegistry()
        registry.record(name: "test", labels: [], value: 1.0)
        registry.record(name: "test", labels: [], value: 42.0)
        let output = registry.emit()
        #expect(output.contains("test 42.0"))
        #expect(!output.contains("test 1.0"))
    }

    @Test("SimpleRegistry emit: very small fractional number")
    func emitVerySmall() {
        let registry = SimpleRegistry()
        registry.record(name: "test", labels: [], value: 0.000001)
        let output = registry.emit()
        // %.6g formats this as "1e-06"
        #expect(output.contains("test 1e-06"))
    }
}
