import Foundation

enum AwayAction: Hashable, Sendable {
    case blur
    case lock
    /// Undo whatever the policy did.
    case clear
}

/// Turns presence into actions, returning one only when the level changes. Never steps down from
/// `.lock` to `.blur`, and `.unknown` clears rather than escalates because a sensor gap is not an
/// absence.
struct AwayPolicyRunner: Hashable, Sendable {
    var policy: AwayPolicy
    private(set) var response: AwayResponse = .idle

    init(policy: AwayPolicy) {
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
