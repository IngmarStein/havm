import Foundation
import Network
import Metrics
import Logging

// MARK: - Simple Prometheus Registry

/// Thread-safe in-memory registry of Prometheus gauge values.
/// Uses `NSLock` so metrics can be recorded from any thread without
/// async overhead.
public final class SimpleRegistry: @unchecked Sendable {
    private let lock = NSLock()
    /// Metric name → (label-set key → value). The label-set key is
    /// Prometheus-format: `name="value",name2="value2"` or "" for no labels.
    private var values: [String: [String: Double]] = [:]

    public init() {}

    public func record(name: String, labels: [(String, String)], value: Double) {
        lock.lock()
        defer { lock.unlock() }
        let key = labels.map { "\($0.0)=\"\($0.1)\"" }.joined(separator: ",")
        values[name, default: [:]][key] = value
    }

    /// Emit the Prometheus exposition format.
    /// - Returns: Text compatible with `Content-Type: text/plain; version=0.0.4`.
    public func emit() -> String {
        lock.lock()
        defer { lock.unlock() }
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

/// Format a double for Prometheus exposition. Drops trailing zeros (".0" → "0")
/// while preserving enough precision for realistic gauge values.
private func formatValue(_ v: Double) -> String {
    // Prometheus expects at least one decimal digit for gauge values.
    // Use a compact format: integer values get ".0", fractional get up to 6 places.
    if v == Double(Int64(v)) {
        return "\(Int64(v)).0"
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
public final class MetricsServer: @unchecked Sendable {
    private let registry: SimpleRegistry
    private let host: String
    private let port: Int
    private let logger: Logger
    private let queue: DispatchQueue
    private var listener: NWListener?

    /// Optional closure called before each metrics scrape. Use for on-demand
    /// gauges that should be computed fresh (e.g. disk usage).
    public var preScrape: (() -> Void)?

    public init(registry: SimpleRegistry, host: String, port: Int, logger: Logger) {
        self.registry = registry
        self.host = host
        self.port = port
        self.logger = logger
        self.queue = DispatchQueue(label: "havm.metrics-server")
    }

    /// Start the HTTP server. Throws if the port cannot be bound.
    public func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw MetricsError.invalidPort(port)
        }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: nwPort
        )

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.logger.info("Metrics server listening on \(self.host):\(self.port)")
            case .failed(let error):
                self.logger.error("Metrics server failed: \(error.localizedDescription)")
            case .cancelled:
                self.logger.debug("Metrics server stopped")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Stop the HTTP server.
    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
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
        if let crlf = request.firstIndex(of: "\r\n") {
            line = String(request[..<crlf])
        } else {
            line = request
        }

        // GET /metrics — Prometheus scrape endpoint
        if line.hasPrefix("GET /metrics") {
            preScrape?()
            let body = registry.emit()
            return Self.httpResponse(
                status: "200 OK",
                contentType: "text/plain; version=0.0.4",
                body: body
            )
        }

        // GET /health — liveness check
        if line.hasPrefix("GET /health") {
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
        response.append(contentsOf: "Content-Length: \(bodyData.count)\r\n\r\n".utf8)
        if !bodyData.isEmpty {
            response.append(contentsOf: bodyData)
        }
        return response
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

    public var description: String {
        switch self {
        case .invalidPort(let port):
            return "Invalid metrics port: \(port) (must be 1–65535)"
        case .serverAlreadyRunning:
            return "Metrics server is already running"
        }
    }
}
