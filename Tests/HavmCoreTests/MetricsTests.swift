import Foundation
import Logging
import Testing
@testable import HavmCore

@Suite struct MetricsTests {

    private var logger: Logger { Logger(label: "havm.tests.metrics") }

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

    // MARK: - formatEndpoints

    @Test("formatEndpoints: TCP addresses and socket paths")
    func formatEndpointsJoins() {
        let result = MetricsServer.formatEndpoints(
            hosts: ["127.0.0.1", "::1"], port: 9210, sockets: ["/tmp/havm.sock"]
        )
        #expect(result == "127.0.0.1:9210, [::1]:9210, unix:/tmp/havm.sock")
    }

    @Test("formatEndpoints: socket-only has no TCP address")
    func formatEndpointsSocketOnly() {
        let result = MetricsServer.formatEndpoints(hosts: [], port: 9210, sockets: ["/tmp/havm.sock"])
        #expect(result == "unix:/tmp/havm.sock")
    }

    // MARK: - Unix domain socket listeners

    @Test("A socket-only server serves metrics over the socket")
    func socketOnlyServesMetrics() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("havm.sock").path

        let registry = SimpleRegistry()
        registry.record(name: "havm_test", labels: [], value: 1.0)
        let server = MetricsServer(
            registry: registry, hosts: [], sockets: [socketPath], port: 9210, logger: logger
        )
        try server.start()
        defer { server.stop() }

        let metrics = try unixSocketRequest(path: socketPath, "GET /metrics HTTP/1.1\r\n\r\n")
        #expect(metrics.contains("200 OK"))
        #expect(metrics.contains("havm_test 1.0"))

        let health = try unixSocketRequest(path: socketPath, "GET /health HTTP/1.1\r\n\r\n")
        #expect(health.contains("200 OK"))
    }

    @Test("Starting a socket server creates the socket file and its directory")
    func socketCreatesFileAndParentDirectory() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("run/havm/run/nested")
        let socketPath = nested.appendingPathComponent("havm.sock").path

        let server = MetricsServer(
            registry: SimpleRegistry(), hosts: [], sockets: [socketPath], port: 9210, logger: logger
        )
        try server.start()
        defer { server.stop() }

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(FileManager.default.fileExists(atPath: socketPath))
    }

    @Test("stop() removes the socket file it created")
    func stopRemovesSocketFile() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("havm.sock").path

        let server = MetricsServer(
            registry: SimpleRegistry(), hosts: [], sockets: [socketPath], port: 9210, logger: logger
        )
        try server.start()
        #expect(FileManager.default.fileExists(atPath: socketPath))

        server.stop()
        #expect(!FileManager.default.fileExists(atPath: socketPath),
                "A clean shutdown should leave nothing behind for the next start")
    }

    @Test("A socket file left by an unclean exit is replaced")
    func staleSocketFileIsReplaced() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("havm.sock").path

        // A bound-then-abandoned socket file: exactly what a SIGKILL leaves.
        try plantStaleSocket(at: socketPath)

        let registry = SimpleRegistry()
        registry.record(name: "havm_restarted", labels: [], value: 2.0)
        let server = MetricsServer(
            registry: registry, hosts: [], sockets: [socketPath], port: 9210, logger: logger
        )
        try server.start()
        defer { server.stop() }

        let metrics = try unixSocketRequest(path: socketPath, "GET /metrics HTTP/1.1\r\n\r\n")
        #expect(metrics.contains("havm_restarted 2.0"))
    }

    @Test("A socket-only server does not require a valid TCP port")
    func socketOnlyIgnoresPort() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("havm.sock").path

        let server = MetricsServer(
            registry: SimpleRegistry(), hosts: [], sockets: [socketPath], port: -1, logger: logger
        )
        try server.start()
        defer { server.stop() }
        #expect(FileManager.default.fileExists(atPath: socketPath))
    }

    @Test("A regular file at the socket path is refused, not deleted")
    func regularFileAtSocketPathIsRefused() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("havm.sock").path
        try "not a socket".write(toFile: socketPath, atomically: true, encoding: .utf8)

        let server = MetricsServer(
            registry: SimpleRegistry(), hosts: [], sockets: [socketPath], port: 9210, logger: logger
        )
        #expect(throws: MetricsError.self) { try server.start() }

        let contents = try String(contentsOfFile: socketPath, encoding: .utf8)
        #expect(contents == "not a socket", "The user's file must survive the failed start")
    }

    @Test("A relative socket path is rejected")
    func relativeSocketPathRejected() {
        let server = MetricsServer(
            registry: SimpleRegistry(), hosts: [], sockets: ["run/havm.sock"], port: 9210, logger: logger
        )
        #expect(throws: MetricsError.self) { try server.start() }
    }

    @Test("A socket path past the sun_path limit is rejected")
    func overlengthSocketPathRejected() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent(String(repeating: "x", count: 200)).path
        #expect(socketPath.utf8.count > MetricsServer.maxSocketPathBytes)

        let server = MetricsServer(
            registry: SimpleRegistry(), hosts: [], sockets: [socketPath], port: 9210, logger: logger
        )
        // Network.framework reports an overlong path as a healthy listener and
        // simply creates no socket file, so this must be caught up front.
        #expect(throws: MetricsError.self) { try server.start() }
    }

    @Test("A socket path at the sun_path limit is accepted")
    func maxLengthSocketPathAccepted() throws {
        // /tmp keeps the leading path short enough to reach the limit exactly.
        let prefix = "/tmp/havm-maxlen-"
        let socketPath = prefix + String(repeating: "y", count: MetricsServer.maxSocketPathBytes - prefix.utf8.count)
        #expect(socketPath.utf8.count == MetricsServer.maxSocketPathBytes)
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = MetricsServer(
            registry: SimpleRegistry(), hosts: [], sockets: [socketPath], port: 9210, logger: logger
        )
        try server.start()
        defer { server.stop() }
        #expect(FileManager.default.fileExists(atPath: socketPath))
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

// MARK: - Socket test helpers

/// A short scratch directory under `/tmp`. These tests bind real Unix
/// sockets, whose paths are capped at `sun_path`'s 104 bytes — the system
/// temporary directory expands to `/var/folders/…` and leaves no room.
private func makeScratchDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: "/tmp/havm-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Leave a socket file at `path` with nothing listening on it — what a
/// process killed with SIGKILL leaves behind.
private func plantStaleSocket(at path: String) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketProbeError.socket(errno) }
    defer { close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw SocketProbeError.pathTooLong
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }

    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0 else { throw SocketProbeError.bind(errno) }
}
