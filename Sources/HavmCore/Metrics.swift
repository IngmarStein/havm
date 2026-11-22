import Darwin
import Foundation
import Network
import Metrics
import Logging
import Synchronization

// MARK: - Simple Prometheus Registry

/// Thread-safe in-memory registry of Prometheus gauge values.
/// Uses `Mutex` from the Swift Synchronization module — values are accessed
/// through `withLock` which provides exclusive access with the borrowing
/// model. `Mutex` is `Sendable`, so the class itself needs no concurrency
/// annotation.
public final class SimpleRegistry: Sendable {
    /// Metric name → (label-set key → value). The label-set key is
    /// Prometheus-format: `name="value",name2="value2"` or "" for no labels.
    private let values = Mutex<[String: [String: Double]]>([:])

    public init() {}

    public func record(name: String, labels: [(String, String)], value: Double) {
        values.withLock { values in
            values[name, default: [:]][Self.labelKey(labels)] = value
        }
    }

    /// Drop one series, for a label set that no longer describes anything —
    /// an address the guest has moved off, say. A series that merely went
    /// away is what Prometheus reports as stale; leaving it behind with a zero
    /// would say something different, that the value is now zero.
    public func remove(name: String, labels: [(String, String)]) {
        values.withLock { values in
            values[name]?.removeValue(forKey: Self.labelKey(labels))
            if values[name]?.isEmpty == true { values.removeValue(forKey: name) }
        }
    }

    /// The Prometheus label set for `labels`: `name="value",name2="value2"`, or
    /// empty when there are none.
    ///
    /// Values are escaped as the exposition format requires — a backslash,
    /// a double quote or a newline in a value would otherwise end the string
    /// early and produce a malformed sample. Guest addresses are the first
    /// values here that havm does not spell itself.
    private static func labelKey(_ labels: [(String, String)]) -> String {
        labels.map { "\($0.0)=\"\(escapeLabelValue($0.1))\"" }.joined(separator: ",")
    }

    private static func escapeLabelValue(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "\\": escaped += #"\\"#
            case "\"": escaped += #"\""#
            case "\n": escaped += #"\n"#
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// Emit the Prometheus exposition format.
    /// - Returns: Text compatible with `Content-Type: text/plain; version=0.0.4`.
    public func emit() -> String {
        values.withLock { values in
            var lines: [String] = []
            for (name, samples) in values.sorted(by: { $0.key < $1.key }) {
                if samples.isEmpty { continue }
                lines.append("# TYPE \(name) gauge")
                for (labelStr, value) in samples.sorted(by: { $0.key < $1.key }) {
                    if labelStr.isEmpty {
                        lines.append("\(name) \(formatValue(value))")
                    } else {
                        lines.append("\(name){\(labelStr)} \(formatValue(value))")
                    }
                }
            }
            lines.append("")
            return lines.joined(separator: "\n")
        }
    }
}

/// Format a double for Prometheus exposition. Handles NaN/Inf per spec and
/// avoids trapping on values outside `Int64`.
private func formatValue(_ v: Double) -> String {
    if v.isNaN { return "NaN" }
    if v.isInfinite { return v.sign == .minus ? "-Inf" : "+Inf" }
    if let intVal = Int64(exactly: v) {
        return "\(intVal).0"
    }
    return String(format: "%.6g", v)
}

// MARK: - Gauge

/// Drop-in replacement for swift-prometheus's `Gauge`. Has the same API surface.
public class Gauge {
    private let handler: RecorderHandler

    public init(label: String, dimensions: [(String, String)] = []) {
        handler = MetricsSystem.factory.makeRecorder(
            label: label,
            dimensions: dimensions,
            aggregate: false
        )
    }

    public func record(_ value: Double) { handler.record(value) }
}

// MARK: - MetricsFactory

/// Bridges swift-metrics to our `SimpleRegistry`. Only `Gauge` (backed by
/// `RecorderHandler` with `aggregate: false`) is supported — other metric
/// types are no-ops.
private struct SimpleMetricsFactory: MetricsFactory {
    let registry: SimpleRegistry

    func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        NoOpHandler()
    }

    func makeMeter(label: String, dimensions: [(String, String)]) -> MeterHandler {
        NoOpHandler()
    }

    func makeRecorder(
        label: String, dimensions: [(String, String)], aggregate: Bool
    ) -> RecorderHandler {
        SimpleRecorder(registry: registry, label: label, dimensions: dimensions)
    }

    func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        NoOpHandler()
    }

    func destroyCounter(_ handler: CounterHandler) {}
    func destroyMeter(_ handler: MeterHandler) {}
    func destroyRecorder(_ handler: RecorderHandler) {}
    func destroyTimer(_ handler: TimerHandler) {}
}

private final class SimpleRecorder: RecorderHandler {
    let registry: SimpleRegistry
    let label: String
    let dimensions: [(String, String)]

    init(registry: SimpleRegistry, label: String, dimensions: [(String, String)]) {
        self.registry = registry
        self.label = label
        self.dimensions = dimensions
    }

    func record(_ value: Int64) {
        registry.record(name: label, labels: dimensions, value: Double(value))
    }

    func record(_ value: Double) {
        registry.record(name: label, labels: dimensions, value: value)
    }
}

private final class NoOpHandler: CounterHandler, MeterHandler, TimerHandler {
    func increment(by: Int64) {}
    func increment(by: Double) {}
    func decrement(by: Double) {}
    func set(_ value: Int64) {}
    func set(_ value: Double) {}
    func reset() {}
    func record(_ value: Int64) {}
    func record(_ value: Double) {}
    func recordNanoseconds(_ duration: Int64) {}
}

// MARK: - Metrics Server

/// Minimal HTTP server that exposes Prometheus metrics via Network.framework.
///
/// Serves `GET /metrics` with the Prometheus exposition format and
/// `GET /health` for liveness checks. All other paths return 404.
///
/// Uses HTTP/1.0 semantics — closes the connection after each response.
/// Designed for Prometheus scraping (every 15–60s), not high-throughput use.
///
/// Listens on TCP addresses, Unix domain sockets, or both — a server with
/// only sockets configured opens no TCP port at all.
public final class MetricsServer: @unchecked Sendable {
    /// Maximum length of a Unix domain socket path in UTF-8 bytes.
    ///
    /// `sockaddr_un.sun_path` is 104 bytes on Darwin. Network.framework does
    /// not report a longer path as an error — the listener reaches `.ready`
    /// and no socket file is created — so havm rejects it up front and then
    /// verifies the file exists (see `startSocketListener`).
    public static let maxSocketPathBytes = 104

    private let registry: SimpleRegistry
    private let hosts: [String]
    private let sockets: [String]
    private let port: Int
    private let logger: Logger
    private let queue: DispatchQueue
    private var listeners: [NWListener] = []
    /// Socket files this server created, removed again by `stop()`.
    private var socketFiles: [String] = []

    /// Optional closure called before each metrics scrape. Use for on-demand
    /// gauges that should be computed fresh (e.g. disk usage).
    public var preScrape: (() -> Void)?

    public init(
        registry: SimpleRegistry,
        hosts: [String],
        sockets: [String] = [],
        port: Int,
        logger: Logger
    ) {
        self.registry = registry
        self.hosts = hosts
        self.sockets = sockets
        self.port = port
        self.logger = logger
        self.queue = DispatchQueue(label: "havm.metrics-server")
    }

    /// Start the HTTP server. Creates a listener for each configured host —
    /// so users can bind both IPv4 and IPv6 without relying on dual-stack
    /// behaviour (Network.framework sets IPV6_V6ONLY) — and for each
    /// configured Unix domain socket path.
    ///
    /// Throws for a socket path that cannot be prepared, and for a host whose
    /// listener binds somewhere other than the configured port. The port is
    /// only validated when there is a TCP host to bind: a socket-only server
    /// has no use for it.
    public func start() throws {
        do {
            if !hosts.isEmpty {
                guard let requested = UInt16(exactly: port),
                      let nwPort = NWEndpoint.Port(rawValue: requested) else {
                    throw MetricsError.invalidPort(port)
                }
                for host in hosts {
                    let ready = ListenerStartupSignal()
                    let listener = try makeListener(
                        endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort),
                        displayName: Self.formatHostPort(host: host, port: port),
                        startupSignal: ready
                    )
                    listener.start(queue: queue)
                    listeners.append(listener)
                    if case .ready(let bound) = ready.wait(timeout: 2), bound != requested {
                        throw MetricsError.portNotBound(host: host, requested: requested, bound: bound)
                    }
                }
            }

            for path in sockets {
                try startSocketListener(path: path)
            }
        } catch {
            // Don't leave listeners from a partial start running — callers
            // discard the server when this throws.
            stop()
            throw error
        }
    }

    /// Bind one Unix domain socket listener.
    private func startSocketListener(path: String) throws {
        let socketPath = path.trimmingCharacters(in: .whitespaces)
        guard !socketPath.isEmpty, socketPath.hasPrefix("/") else {
            throw MetricsError.invalidSocketPath(path, reason: "path must be absolute")
        }
        let length = socketPath.utf8.count
        guard length <= Self.maxSocketPathBytes else {
            throw MetricsError.invalidSocketPath(
                path,
                reason: "path is \(length) bytes, limit is \(Self.maxSocketPathBytes)"
            )
        }

        // Create the parent directory so the socket path can be configured
        // without the user having to create its directory first.
        let parent = (socketPath as NSString).deletingLastPathComponent
        if !parent.isEmpty, !FileManager.default.fileExists(atPath: parent) {
            do {
                try FileManager.default.createDirectory(
                    atPath: parent, withIntermediateDirectories: true
                )
            } catch {
                throw MetricsError.invalidSocketPath(
                    path, reason: "cannot create \(parent) — \(error.localizedDescription)"
                )
            }
        }
        try clearStaleSocket(at: socketPath)

        let ready = ListenerStartupSignal()
        let listener = try makeListener(
            endpoint: .unix(path: socketPath),
            displayName: "unix:\(socketPath)",
            startupSignal: ready
        )
        listener.start(queue: queue)
        listeners.append(listener)
        socketFiles.append(socketPath)

        guard case .ready = ready.wait(timeout: 2),
              FileManager.default.fileExists(atPath: socketPath) else {
            throw MetricsError.socketBindFailed(socketPath)
        }
        _ = chmod(socketPath, 0o600)
    }

    /// Create a listener that serves the metrics endpoints.
    private func makeListener(
        endpoint: NWEndpoint,
        displayName: String,
        startupSignal: ListenerStartupSignal
    ) throws -> NWListener {
        let params = NWParameters.tcp
        // Allow multiple listeners on the same port (e.g. 127.0.0.1 + ::1).
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = endpoint

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .setup:
                self.logger.debug("Metrics server setting up on \(displayName)")
            case .waiting(let error):
                self.logger.warning("Metrics server waiting on \(displayName) — \(error.localizedDescription)")
            case .ready:
                self.logger.info("Metrics server listening on \(displayName)")
                startupSignal.resolve(.ready(port: listener?.port?.rawValue))
            case .failed(let error):
                self.logger.error("Metrics server failed on \(displayName) — \(error.localizedDescription)")
                startupSignal.resolve(.failed)
            case .cancelled:
                self.logger.debug("Metrics server stopped on \(displayName)")
                startupSignal.resolve(.failed)
            @unknown default:
                break
            }
        }
        return listener
    }

    /// Remove a socket file left behind by a process that did not shut down
    /// cleanly. Binding over one fails with `EADDRINUSE` even with
    /// `allowLocalEndpointReuse`, which would otherwise leave a restarted
    /// service with no metrics.
    ///
    /// Anything that is not a socket is left alone and reported instead —
    /// the path may be a file the user put there.
    private func clearStaleSocket(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard isSocket(path) else {
            throw MetricsError.socketInUse(path)
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func isSocket(_ path: String) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.type] as? FileAttributeType) == .typeSocket
    }

    /// Format a host:port pair, wrapping IPv6 addresses in brackets.
    public static func formatHostPort(host: String, port: Int) -> String {
        if host.contains(":") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }

    /// Format a list of hosts with a port for log messages.
    public static func formatHostsPort(_ hosts: [String], port: Int) -> String {
        hosts.map { formatHostPort(host: $0, port: port) }.joined(separator: ", ")
    }

    /// Format every configured endpoint for log messages, e.g.
    /// `127.0.0.1:9210, ::1:9210, unix:/opt/homebrew/var/run/havm.sock`.
    public static func formatEndpoints(hosts: [String], port: Int, sockets: [String]) -> String {
        let tcp = hosts.map { formatHostPort(host: $0, port: port) }
        return (tcp + sockets.map { "unix:\($0)" }).joined(separator: ", ")
    }

    /// Stop the HTTP server and remove the socket files it created, so a
    /// clean exit leaves nothing behind for the next start to trip over.
    public func stop() {
        for listener in listeners {
            listener.cancel()
        }
        listeners.removeAll()
        for path in socketFiles where isSocket(path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        socketFiles.removeAll()
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        let received = Mutex(false)
        queue.asyncAfter(deadline: .now() + 5) {
            if received.withLock({ !$0 }) {
                connection.cancel()
            }
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            received.withLock { $0 = true }
            guard let self else { connection.cancel(); return }

            let responseData: Data
            if let data, let request = String(data: data, encoding: .utf8) {
                responseData = self.buildResponse(for: request)
            } else {
                responseData = Self.httpResponse(status: "400 Bad Request", body: "")
            }

            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func buildResponse(for request: String) -> Data {
        let line: String
        if let lineEnd = request.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
            line = String(request[..<lineEnd])
        } else {
            line = request
        }

        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0] == "GET" else {
            return Self.httpResponse(status: "404 Not Found", body: "")
        }
        let path = parts[1].split(separator: "?", maxSplits: 1).first ?? parts[1]

        // GET /metrics — Prometheus scrape endpoint
        if path == "/metrics" {
            preScrape?()
            let body = registry.emit()
            return Self.httpResponse(
                status: "200 OK",
                contentType: "text/plain; version=0.0.4",
                body: body
            )
        }

        // GET /health — liveness check
        if path == "/health" {
            return Self.httpResponse(status: "200 OK", body: "OK")
        }

        // Everything else
        return Self.httpResponse(status: "404 Not Found", body: "")
    }

    // MARK: - Helpers

    private static func httpResponse(
        status: String, contentType: String? = nil, body: String
    ) -> Data {
        var response = Data()
        response.append(contentsOf: "HTTP/1.1 \(status)\r\n".utf8)
        if let ct = contentType {
            response.append(contentsOf: "Content-Type: \(ct)\r\n".utf8)
        }
        let bodyData = body.data(using: .utf8) ?? Data()
        response.append(contentsOf: "Content-Length: \(bodyData.count)\r\n".utf8)
        response.append(contentsOf: "Connection: close\r\n\r\n".utf8)
        if !bodyData.isEmpty {
            response.append(contentsOf: bodyData)
        }
        return response
    }
}

/// Bridges `NWListener.stateUpdateHandler` to `MetricsServer.start()` without busy-waiting.
private final class ListenerStartupSignal: Sendable {
    enum Outcome: Sendable {
        case ready(port: UInt16?)
        case failed
        case timedOut
    }

    private let semaphore = DispatchSemaphore(value: 0)
    private let outcome = Mutex<Outcome?>(nil)

    func resolve(_ value: Outcome) {
        let shouldSignal = outcome.withLock { current -> Bool in
            guard current == nil else { return false }
            current = value
            return true
        }
        if shouldSignal { semaphore.signal() }
    }

    func wait(timeout: TimeInterval) -> Outcome {
        if semaphore.wait(timeout: .now() + timeout) == .timedOut { return .timedOut }
        return outcome.withLock { $0 ?? .timedOut }
    }
}

// MARK: - Bootstrap

/// Bootstrap the `swift-metrics` system with our simple Prometheus backend.
///
/// - Returns: A `SimpleRegistry` that callers can use to serve
///   Prometheus exposition format via `emit()`.
public func bootstrapMetrics(logger: Logger) -> SimpleRegistry {
    let registry = SimpleRegistry()
    let factory = SimpleMetricsFactory(registry: registry)
    MetricsSystem.bootstrap(factory)
    logger.debug("Metrics: Prometheus backend bootstrapped")
    return registry
}

// MARK: - Errors

public enum MetricsError: Error, CustomStringConvertible {
    case invalidPort(Int)
    case serverAlreadyRunning
    case invalidSocketPath(String, reason: String)
    case socketInUse(String)
    case socketBindFailed(String)
    case portNotBound(host: String, requested: UInt16, bound: UInt16?)

    public var description: String {
        switch self {
        case .invalidPort(let port):
            return "Invalid metrics port: \(port) (must be 1–65535)"
        case .serverAlreadyRunning:
            return "Metrics server is already running"
        case .invalidSocketPath(let path, let reason):
            return "Invalid metrics socket path \"\(path)\": \(reason)"
        case .socketInUse(let path):
            return "Metrics socket path \"\(path)\" exists and is not a socket"
        case .socketBindFailed(let path):
            return "Metrics socket \"\(path)\" could not be created — check that the path is writable, or delete a stale socket file"
        case .portNotBound(let host, let requested, let bound):
            let actual = bound.map(String.init) ?? "no port"
            return "host \"\(host)\" bound \(actual) instead of \(requested) — host takes a numeric "
                + "bind address such as \"127.0.0.1\" or \"::\", and the port comes from "
                + "metrics.prometheus.port"
        }
    }
}
