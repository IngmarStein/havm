import Foundation
import Network
import Metrics
import Prometheus
import Logging

// MARK: - Metrics Server

/// Minimal HTTP server that exposes Prometheus metrics via Network.framework.
///
/// Serves `GET /metrics` with the Prometheus exposition format from the shared
/// `PrometheusCollectorRegistry`. Also serves `GET /health` for simple liveness
/// checks. All other paths return 404.
///
/// Uses HTTP/1.0 semantics — closes the connection after each response.
/// This is fine for Prometheus scraping (every 15–60s), not for high-throughput
/// use.
public final class MetricsServer: @unchecked Sendable {
    private let registry: PrometheusCollectorRegistry
    private let host: String
    private let port: Int
    private let logger: Logger
    private let queue: DispatchQueue
    private var listener: NWListener?

    public init(registry: PrometheusCollectorRegistry, host: String, port: Int, logger: Logger) {
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

        // Bind to the configured host (e.g., 127.0.0.1) rather than all interfaces.
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
        let line = request.split(separator: "\r\n").first.map(String.init) ?? request

        // GET /metrics — Prometheus scrape endpoint
        if line.hasPrefix("GET /metrics") {
            let body = registry.emitToString()
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

    private static func httpResponse(status: String, contentType: String? = nil, body: String) -> Data {
        var lines = ["HTTP/1.1 \(status)"]
        if let ct = contentType {
            lines.append("Content-Type: \(ct)")
        }
        let bodyData = body.data(using: .utf8) ?? Data()
        lines.append("Content-Length: \(bodyData.count)")
        lines.append("")  // blank line separator
        lines.append("")
        var response = lines.joined(separator: "\r\n")
        if !body.isEmpty {
            response += body
        }
        return response.data(using: .utf8) ?? Data()
    }
}

// MARK: - Metrics Bootstrap

/// Bootstrap the `swift-metrics` system with the Prometheus backend.
///
/// - Returns: The `PrometheusCollectorRegistry` so the caller can serve
///   `emitToString()` over HTTP.
public func bootstrapMetrics(logger: Logger) -> PrometheusCollectorRegistry {
    let registry = PrometheusCollectorRegistry()
    let factory = PrometheusMetricsFactory(registry: registry)
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
