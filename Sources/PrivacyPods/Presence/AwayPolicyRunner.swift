import Foundation

/// What the away policy wants done right now, as an edge rather than a level.
enum AwayAction: Hashable, Sendable {
    case blur
    case lock
    /// Undo whatever the policy did: the user is back, or the evidence evaporated.
    case clear
}

/// Turns a stream of `PresenceState` into the few actions the app should actually take.
///
/// Pure, so the escalation can be stepped in tests without waiting out a 30 second timer: the
/// caller passes `now` and the runner returns an action only when the level changes. It never
/// steps back down from `.lock` to `.blur` — once the screen is locked, the only way out is the
/// user returning — and `.unknown` clears rather than escalates, because a sensor gap is not an
/// absence.
struct AwayPolicyRunner: Hashable, Sendable {
    var policy: AwayPolicy
    private(set) var response: AwayResponse = .idle

    init(policy: AwayPolicy = .default) {
        self.policy = policy
    }

    mutating func update(presence: PresenceState, at now: Date) -> AwayAction? {
        let wanted = wantedResponse(for: presence, at: now)

        guard wanted > response else {
            guard wanted == .idle, response != .idle else { return nil }
            response = .idle
            return .clear
        }

        response = wanted
        return wanted == .lock ? .lock : .blur
    }

    private func wantedResponse(for presence: PresenceState, at now: Date) -> AwayResponse {
        guard case .away(let since) = presence else { return .idle }
        return policy.response(awayFor: now.timeIntervalSince(since))
    }
}
