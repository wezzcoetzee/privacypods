import Foundation
import Testing
@testable import PrivacyPods

@Suite("Away policy runner")
struct AwayPolicyRunnerTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("Blur then lock escalates once each")
    func escalation() {
        var runner = AwayPolicyRunner(policy: .blurThenLock(blurAfter: 5, lockAfter: 30))
        let away = PresenceState.away(since: start)

        #expect(runner.update(presence: away, at: start) == nil)
        #expect(runner.update(presence: away, at: start + 5) == .blur)
        #expect(runner.update(presence: away, at: start + 10) == nil)
        #expect(runner.update(presence: away, at: start + 30) == .lock)
        #expect(runner.update(presence: away, at: start + 60) == nil)
    }

    @Test("Coming back clears, once")
    func returningClears() {
        var runner = AwayPolicyRunner(policy: .blurThenLock(blurAfter: 5, lockAfter: 30))
        _ = runner.update(presence: .away(since: start), at: start + 5)

        #expect(runner.update(presence: .present, at: start + 6) == .clear)
        #expect(runner.update(presence: .present, at: start + 7) == nil)
        #expect(runner.response == .idle)
    }

    @Test("A sensor gap clears rather than escalating")
    func unknownNeverEscalates() {
        var runner = AwayPolicyRunner(policy: .lockImmediately)

        #expect(runner.update(presence: .unknown, at: start) == nil)
        #expect(runner.update(presence: .away(since: start), at: start) == .lock)
        #expect(runner.update(presence: .unknown, at: start + 1) == .clear)
    }

    @Test("Policies that do nothing, do nothing")
    func doNothingStaysIdle() {
        var runner = AwayPolicyRunner(policy: .doNothing)

        #expect(runner.update(presence: .away(since: start), at: start + 3600) == nil)
        #expect(runner.response == .idle)
    }
}
