import Foundation
import Synchronization
import Testing
@testable import HavmCore

/// The shutdown chain's sequencing, with the guest replaced by a script.
///
/// The rule these tests exist for is the one issue #11 got wrong: a method
/// that accepts the request ends the chain, whether or not the guest halts.
/// The wait consumes the rest of the shared budget, so asking the next method
/// to halt a guest that is already halting is what force-stopped a clean
/// shutdown.
@Suite struct ShutdownChainTests {

    // MARK: - Policy

    @Test func restIsTriedOnlyWhenAnAPITokenIsConfigured() {
        #expect(ShutdownPolicy.methods(hasAPIToken: true) == [.restAPI, .debugSSH, .sshAddon])
        #expect(ShutdownPolicy.methods(hasAPIToken: false) == [.debugSSH, .sshAddon])
    }

    @Test func aSpentBudgetHasNoSecondsLeft() {
        let now = Date()
        #expect(ShutdownPolicy.remainingSeconds(until: now.addingTimeInterval(30), now: now) == 30)
        #expect(ShutdownPolicy.remainingSeconds(until: now.addingTimeInterval(0.9), now: now) == nil)
        #expect(ShutdownPolicy.remainingSeconds(until: now, now: now) == nil)
        #expect(ShutdownPolicy.remainingSeconds(until: now.addingTimeInterval(-5), now: now) == nil)
    }

    @Test func requestAttemptsAreCappedInsideTheBudget() {
        #expect(ShutdownPolicy.restTimeout(within: 90) == 10)
        #expect(ShutdownPolicy.restTimeout(within: 4) == 4)
        #expect(ShutdownPolicy.sshConnectTimeout(within: 90) == 5)
        #expect(ShutdownPolicy.sshConnectTimeout(within: 2) == 2)
    }

    @Test func theTipNamesOnlyWhatIsUnconfigured() {
        #expect(ShutdownPolicy.unconfiguredTip(hasAPIToken: true, hasSSHKeys: true) == nil)
        #expect(ShutdownPolicy.unconfiguredTip(hasAPIToken: false, hasSSHKeys: true)
            == "Tip: configure ha.api_token (REST API)")
        #expect(ShutdownPolicy.unconfiguredTip(hasAPIToken: true, hasSSHKeys: false)
            == "Tip: configure ssh.authorized_keys (debug SSH)")
        #expect(ShutdownPolicy.unconfiguredTip(hasAPIToken: false, hasSSHKeys: false)
            == "Tip: configure ha.api_token (REST API) or ssh.authorized_keys (debug SSH), "
                + "or install the Terminal & SSH app in Home Assistant")
    }

    // MARK: - Sequencing

    @Test func aHaltedGuestEndsTheChain() async {
        let clock = TestClock()
        let recorder = Recorder()
        let chain = makeChain(clock: clock, recorder: recorder, outcomes: [.accepted], halts: true)

        #expect(await chain.run() == .halted)
        #expect(recorder.attempted == [.restAPI])
    }

    /// Issue #11: once a method accepts, the chain waits and gives up. It does
    /// not try the remaining methods, because the wait has spent the budget.
    @Test func anAcceptedRequestIsNotFollowedByAnotherMethod() async {
        let clock = TestClock()
        let recorder = Recorder()
        let chain = makeChain(
            clock: clock, recorder: recorder,
            outcomes: [.accepted, .accepted, .accepted], halts: false
        )

        #expect(await chain.run() == .acceptedButStillRunning)
        #expect(recorder.attempted == [.restAPI])
    }

    /// An unanswered request counts as accepted: a host that did not reply may
    /// already be halting, and asking it again is what issue #11 was about.
    @Test func anUnansweredRequestCountsAsAccepted() async {
        let clock = TestClock()
        let recorder = Recorder()
        let chain = makeChain(clock: clock, recorder: recorder, outcomes: [.unanswered], halts: true)

        #expect(await chain.run() == .halted)
        #expect(recorder.attempted == [.restAPI])
    }

    @Test func aFailedMethodFallsThroughToTheNext() async {
        let clock = TestClock()
        let recorder = Recorder()
        let chain = makeChain(
            clock: clock, recorder: recorder,
            outcomes: [.failed, .failed, .accepted], halts: true
        )

        #expect(await chain.run() == .halted)
        #expect(recorder.attempted == [.restAPI, .debugSSH, .sshAddon])
    }

    @Test func everyMethodFailingLeavesNothingAccepted() async {
        let clock = TestClock()
        let recorder = Recorder()
        let chain = makeChain(
            clock: clock, recorder: recorder,
            outcomes: [.failed, .failed, .failed], halts: false
        )

        #expect(await chain.run() == .nothingAccepted)
        #expect(recorder.attempted == [.restAPI, .debugSSH, .sshAddon])
    }

    /// The deadline is shared, not restarted per method: time a failed attempt
    /// spends comes out of the next one's budget, and a spent budget ends the
    /// chain without another attempt.
    @Test func aSpentBudgetStopsTheChain() async {
        let clock = TestClock()
        let recorder = Recorder()
        let chain = makeChain(
            clock: clock, recorder: recorder,
            outcomes: [.failed, .accepted, .accepted], halts: true,
            // The first attempt burns the whole budget.
            onAttempt: { _, _ in clock.advance(by: 90) }
        )

        #expect(await chain.run() == .nothingAccepted)
        #expect(recorder.attempted == [.restAPI])
    }

    @Test func noMethodsMeansNothingAccepted() async {
        let chain = ShutdownChain(
            deadline: Date().addingTimeInterval(90),
            methods: [],
            attempt: { _, _ in .accepted },
            waitForStop: { _ in true }
        )
        #expect(await chain.run() == .nothingAccepted)
    }

    // MARK: - Helpers

    /// A chain that answers `outcomes` in order, recording each method it is
    /// asked about.
    private func makeChain(
        clock: TestClock,
        recorder: Recorder,
        outcomes: [ShutdownChain.Attempt],
        halts: Bool,
        onAttempt: (@Sendable (ShutdownPolicy.Method, Int) -> Void)? = nil
    ) -> ShutdownChain {
        let queue = Mutex(outcomes)
        return ShutdownChain(
            deadline: clock.now.addingTimeInterval(90),
            methods: ShutdownPolicy.methods(hasAPIToken: true),
            now: { clock.now },
            attempt: { method, budget in
                recorder.record(method)
                onAttempt?(method, budget)
                return queue.withLock { $0.isEmpty ? .failed : $0.removeFirst() }
            },
            waitForStop: { _ in halts }
        )
    }
}

// MARK: - Test doubles

private final class TestClock: @unchecked Sendable {
    private let value = Mutex(Date())
    var now: Date { value.withLock { $0 } }
    func advance(by seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

private final class Recorder: @unchecked Sendable {
    private let methods = Mutex<[ShutdownPolicy.Method]>([])
    func record(_ method: ShutdownPolicy.Method) { methods.withLock { $0.append(method) } }
    var attempted: [ShutdownPolicy.Method] { methods.withLock { $0 } }
}
