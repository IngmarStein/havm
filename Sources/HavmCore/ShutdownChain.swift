import Foundation

/// The order havm asks the guest to halt in, and the budget it asks on.
///
/// The budget is a single deadline for the whole graceful phase, not one
/// timeout per method. Restarting the budget per method is what used to
/// force-stop a guest that was still halting cleanly after an accepted
/// shutdown request (issue #11), and grew the worst case to
/// `min(budget, 10) + 3 × budget`.
enum ShutdownPolicy {

    /// One way of asking the guest to halt, in the order they are tried.
    enum Method: String, CaseIterable, Sendable {
        /// `hassio.host_shutdown` over the Home Assistant REST API.
        case restAPI
        /// The debug SSH on port 22222, root on the host.
        case debugSSH
        /// The Terminal & SSH app on port 22.
        case sshAddon

        /// What the log says while this method is being tried.
        var logDescription: String {
            switch self {
            case .restAPI:   "Attempting shutdown via REST API..."
            case .debugSSH:  "Attempting SSH shutdown via port 22222..."
            case .sshAddon:  "Attempting SSH shutdown via port 22..."
            }
        }
    }

    /// The methods to try, given what is configured.
    ///
    /// Only the REST API depends on configuration: it needs `ha.api_token`.
    /// Whether the guest accepts either SSH method is the guest's answer —
    /// havm cannot see whether the app on port 22 is installed, and the key on
    /// port 22222 only proves the CONFIG disk was attached once.
    static func methods(hasAPIToken: Bool) -> [Method] {
        hasAPIToken ? Method.allCases : [.debugSSH, .sshAddon]
    }

    /// Seconds left before `deadline`, or `nil` once the budget is spent.
    /// Callers skip an attempt entirely on `nil` rather than issuing a request
    /// with no time to answer it.
    static func remainingSeconds(until deadline: Date, now: Date) -> Int? {
        let seconds = Int(deadline.timeIntervalSince(now).rounded(.down))
        return seconds > 0 ? seconds : nil
    }

    /// How long one REST request may take, inside the budget it was given.
    /// An unanswered request to a host that may already be halting is exactly
    /// what issue #11 was about, so the attempt is capped rather than allowed
    /// to consume the phase.
    static func restTimeout(within budget: Int) -> Int { min(budget, 10) }

    /// How long SSH may spend connecting, inside the budget it was given. The
    /// connection phase is capped so an unreachable host cannot eat the rest.
    static func sshConnectTimeout(within budget: Int) -> Int { min(budget, 5) }

    /// The tip naming the shutdown methods that are unconfigured, or `nil` when
    /// none is.
    ///
    /// Naming a method the user has already set up sends them looking in the
    /// wrong place: a wrong tip is worse than no tip, and a log line telling
    /// someone who configured `ssh.authorized_keys` to configure
    /// `ssh.authorized_keys` is how a real failure gets reported as a
    /// configuration mistake (issue #19).
    static func unconfiguredTip(hasAPIToken: Bool, hasSSHKeys: Bool) -> String? {
        // The Terminal & SSH app runs in the guest, so havm cannot see whether
        // it is installed. Offering it is only unambiguous when there is no
        // config-based method at all — otherwise the user has chosen a path,
        // and we don't get to assume the app is what's missing.
        var unconfigured: [String] = []
        if !hasAPIToken { unconfigured.append("ha.api_token (REST API)") }
        // A path that is set but points at nothing is reported by HAOSSetup at
        // startup, so "configured" is the right test here.
        if !hasSSHKeys { unconfigured.append("ssh.authorized_keys (debug SSH)") }
        guard !unconfigured.isEmpty else { return nil }

        var tip = "Tip: configure " + unconfigured.joined(separator: " or ")
        if unconfigured.count == 2 {
            tip += ", or install the Terminal & SSH app in Home Assistant"
        }
        return tip
    }
}

/// Walks the shutdown methods on one shared deadline, with the effects
/// injected so the sequencing can be tested without a guest.
///
/// The rule that matters is what happens after a method accepts the request:
/// the chain waits for the guest to halt, and if it does not, the caller
/// force-stops. It does not go on to the next method, because the wait has
/// consumed the rest of the budget — and asking a guest that is already
/// halting to halt again is the shape of issue #11.
struct ShutdownChain {

    /// What one attempt at one method came to.
    enum Attempt: Equatable {
        /// The guest took the request.
        case accepted
        /// The request went unanswered. For a host that may already be
        /// halting, that is the same as accepted.
        case unanswered
        /// Nothing is listening on the address, or the guest declined.
        case failed
    }

    /// How the chain ended.
    enum Outcome: Equatable {
        /// The guest halted inside the budget.
        case halted
        /// A method accepted the request and the guest had not halted when the
        /// budget ran out. The caller force-stops.
        case acceptedButStillRunning
        /// No method accepted the request. The caller force-stops.
        case nothingAccepted
    }

    let deadline: Date
    let methods: [ShutdownPolicy.Method]
    /// Injected so a test can spend the budget without sleeping.
    var now: () -> Date = Date.init
    let attempt: @Sendable (ShutdownPolicy.Method, Int) async -> Attempt
    let waitForStop: @Sendable (Date) async -> Bool

    func run() async -> Outcome {
        for method in methods {
            guard let budget = ShutdownPolicy.remainingSeconds(until: deadline, now: now()) else {
                break
            }
            switch await attempt(method, budget) {
            case .accepted, .unanswered:
                if await waitForStop(deadline) { return .halted }
                return .acceptedButStillRunning
            case .failed:
                continue
            }
        }
        return .nothingAccepted
    }
}
