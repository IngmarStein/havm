import Foundation
import Logging
import Security
import Synchronization

/// Loads X.509 certificates from PEM (single or multi-cert bundle) or DER data.
enum HACertificateLoader {
    private static let beginMarker = "-----BEGIN CERTIFICATE-----"
    private static let endMarker = "-----END CERTIFICATE-----"

    static func loadCertificates(from data: Data) -> [SecCertificate] {
        if let text = String(data: data, encoding: .utf8), text.contains(beginMarker) {
            return parsePEMCertificates(in: text)
        }
        if let cert = SecCertificateCreateWithData(nil, data as CFData) {
            return [cert]
        }
        return []
    }

    static func loadCertificates(atPath path: String) throws -> [SecCertificate] {
        loadCertificates(from: try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private static func parsePEMCertificates(in text: String) -> [SecCertificate] {
        var certs: [SecCertificate] = []
        var searchStart = text.startIndex
        while let beginRange = text.range(of: beginMarker, range: searchStart..<text.endIndex),
              let endRange = text.range(of: endMarker, range: beginRange.upperBound..<text.endIndex) {
            let base64 = text[beginRange.upperBound..<endRange.lowerBound]
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            if let der = Data(base64Encoded: base64),
               let cert = SecCertificateCreateWithData(nil, der as CFData) {
                certs.append(cert)
            }
            searchStart = endRange.upperBound
        }
        return certs
    }
}

/// Evaluates server TLS trust against optional custom CA certificates or an
/// explicit `insecure_skip_verify` opt-in, and blocks cross-host redirects so
/// bearer tokens and custom TLS rules never apply to another host.
final class HATLSDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let anchorCertificates: [SecCertificate]
    private let insecureSkipVerify: Bool
    private let logger: Logger?
    private let loggedBlockedRedirects = Mutex<Set<String>>([])

    init(
        anchorCertificates: [SecCertificate] = [],
        insecureSkipVerify: Bool = false,
        logger: Logger? = nil
    ) {
        self.anchorCertificates = anchorCertificates
        self.insecureSkipVerify = insecureSkipVerify
        self.logger = logger
        super.init()
    }

    /// Whether a redirect from `originalURL` to `nextURL` stays on the same
    /// host (case-insensitive) and does not downgrade `https` to non-`https`.
    /// Allows `http` → `https` and port changes on the same host while blocking
    /// cross-host hops, userinfo spoofing, and TLS downgrades.
    static func shouldFollowRedirect(from originalURL: URL?, to nextURL: URL?) -> Bool {
        guard let originalHost = originalURL?.host?.lowercased(), !originalHost.isEmpty,
              let nextHost = nextURL?.host?.lowercased(), !nextHost.isEmpty else {
            return false
        }
        guard originalHost == nextHost else { return false }
        if originalURL?.scheme?.lowercased() == "https",
           nextURL?.scheme?.lowercased() != "https" {
            return false
        }
        return true
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let originalURL = task.originalRequest?.url
        let nextURL = request.url
        guard Self.shouldFollowRedirect(from: originalURL, to: nextURL) else {
            let fromScheme = originalURL?.scheme?.lowercased() ?? ""
            let toScheme = nextURL?.scheme?.lowercased() ?? ""
            let fromHost = originalURL?.host?.lowercased() ?? "(unknown)"
            let toHost = nextURL?.host?.lowercased() ?? "(unknown)"
            let key = "\(fromScheme)://\(fromHost)->\(toScheme)://\(toHost)"
            let isFirst = loggedBlockedRedirects.withLock { $0.insert(key).inserted }
            let message: Logger.Message = if fromHost == toHost, fromScheme == "https", toScheme != "https" {
                "Blocked HTTPS downgrade redirect from \(fromScheme)://\(fromHost) to \(toScheme)://\(toHost)"
            } else {
                "Blocked cross-host redirect from \(fromHost) to \(toHost) — set ha.url to the canonical URL if Home Assistant is behind a reverse proxy"
            }
            if isFirst {
                logger?.warning(message)
            } else {
                logger?.debug(message)
            }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if insecureSkipVerify {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        guard !anchorCertificates.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard SecTrustSetAnchorCertificates(serverTrust, anchorCertificates as CFArray) == errSecSuccess else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        _ = SecTrustSetAnchorCertificatesOnly(serverTrust, false)

        var error: CFError?
        if SecTrustEvaluateWithError(serverTrust, &error) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// HTTP(S) client for Home Assistant with bounded total request deadlines
/// (`timeoutIntervalForResource`) and optional custom CA / self-signed TLS.
final class HAClient: Sendable {
    enum ShutdownResult: Equatable, Sendable {
        case success
        case timedOut
        case failed
    }

    enum RestartResult: Equatable, Sendable {
        case accepted
        case rejected(Int)
        case failed(String)
    }

    private enum ShutdownAttempt {
        case accepted
        case timedOut
        case unreachable
        case rejected
    }

    private static let emptyJSONBody = Data("{}".utf8)

    private let session: URLSession
    private let logger: Logger
    private let warnedProbeTLS = Mutex(false)

    init(
        caCertPath: String? = nil,
        insecureSkipVerify: Bool = false,
        logger: Logger
    ) {
        self.logger = logger

        var anchors: [SecCertificate] = []
        if let caCertPath {
            do {
                let loaded = try HACertificateLoader.loadCertificates(atPath: caCertPath)
                if loaded.isEmpty {
                    logger.warning("HA TLS: no valid certificates found in \(caCertPath)")
                } else {
                    anchors = loaded
                    logger.info("HA TLS: loaded \(loaded.count) custom CA certificate(s) from \(caCertPath)")
                }
            } catch {
                logger.warning("HA TLS: could not read ca_cert at \(caCertPath): \(error.localizedDescription)")
            }
        }
        if insecureSkipVerify {
            logger.warning("HA TLS: insecure_skip_verify is enabled — TLS certificate verification is disabled for ha.url")
        }

        // Dedicated session with a hard total-resource timeout so a trickling
        // or stalled peer cannot inherit URLSession.shared's 7-day cap.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForResource = 15
        let delegate = HATLSDelegate(
            anchorCertificates: anchors,
            insecureSkipVerify: insecureSkipVerify,
            logger: logger
        )
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func pingObserver(host: String, timeout: TimeInterval = 2) async -> Bool {
        guard let url = URL(string: "\(HAEndpoint.baseURL(host: host, port: 4357))/ping") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func answersManifest(at baseURL: String, timeout: TimeInterval = 5) async -> Bool {
        guard let url = URL(string: "\(baseURL)/manifest.json") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch let error as URLError where Self.isTLSError(error) {
            let firstWarning = warnedProbeTLS.withLock { warned -> Bool in
                guard !warned else { return false }
                warned = true
                return true
            }
            let message: Logger.Message = "Home Assistant TLS error at \(baseURL): \(error.localizedDescription) — configure ha.ca_cert or ha.insecure_skip_verify if using a self-signed certificate"
            if firstWarning {
                logger.warning(message)
            } else {
                logger.debug(message)
            }
            return false
        } catch {
            return false
        }
    }

    func supervisorShutdown(candidates: [String], token: String, timeout: Int) async -> ShutdownResult {
        for (index, baseURL) in candidates.enumerated() {
            switch await postShutdown(to: baseURL, token: token, timeout: timeout) {
            case .accepted:
                logger.info("REST API shutdown accepted.")
                return .success
            case .timedOut:
                return .timedOut
            case .rejected:
                return .failed
            case .unreachable:
                if index < candidates.count - 1 {
                    logger.info("REST API not listening on \(baseURL) — trying the next address.")
                }
            }
        }
        logger.info("REST API unavailable — falling through to SSH.")
        return .failed
    }

    func restartHomeAssistant(baseURL: String, token: String, timeout: TimeInterval = 10) async -> RestartResult {
        guard let url = URL(string: "\(baseURL)/api/services/homeassistant/restart") else {
            return .failed("Invalid URL: \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.emptyJSONBody
        request.timeoutInterval = timeout

        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            return code == 200 ? .accepted : .rejected(code)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func postShutdown(to baseURL: String, token: String, timeout: Int) async -> ShutdownAttempt {
        guard let url = URL(string: "\(baseURL)/api/services/hassio/host_shutdown") else {
            return .unreachable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.emptyJSONBody
        request.timeoutInterval = TimeInterval(ShutdownPolicy.restTimeout(within: timeout))

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return .rejected }
            if httpResponse.statusCode == 200 { return .accepted }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                logger.warning("REST API: HTTP \(httpResponse.statusCode) — check ha.api_token in config.")
            } else {
                logger.info("REST API: HTTP \(httpResponse.statusCode) — falling through to SSH.")
            }
            return .rejected
        } catch let error as URLError where error.code == .timedOut {
            return .timedOut
        } catch let error as URLError where Self.isTLSError(error) {
            logger.warning("REST API TLS error at \(baseURL): \(error.localizedDescription)")
            return .rejected
        } catch {
            logger.debug("REST API unreachable at \(baseURL): \(error.localizedDescription)")
            return .unreachable
        }
    }

    private static func isTLSError(_ error: URLError) -> Bool {
        switch error.code {
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return true
        default:
            return false
        }
    }
}
