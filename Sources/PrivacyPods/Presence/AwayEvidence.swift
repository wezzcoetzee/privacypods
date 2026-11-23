import Foundation

/// The rules that turn sensor evidence into a `PresenceState`. Asserting away too eagerly locks
/// the screen while its owner is reading, so these rules are not negotiable:
///
/// - A sensor gap is not an absence: `WearState.unknown` alone never resolves to `.away`.
/// - Away needs corroboration: walking while worn plus a falling signal or a gaze off every
///   display, or the AirPods leaving the Mac with no input since.
/// - Input outranks every inference. It restarts the disconnect clock rather than cancelling it.
/// - Only a disconnect that interrupts recent wear is evidence. AirPods that sat in their case
///   for an hour say nothing about their owner when they finally drop off the radio.
struct AwayEvidence: Hashable, Sendable {
    /// How long a disconnect must go without input before it reads as "walked off wearing them"
    /// rather than "put them in the case and carried on working".
    static let disconnectIdleGrace: TimeInterval = 30
    /// How long a keystroke vouches for the user before gait and proximity may argue again.
    static let inputPresenceWindow: TimeInterval = 5
    /// How recently the AirPods must have been worn for their disconnect to mean anything.
    static let recentWearWindow: TimeInterval = 60

    var isWalking = false
    var proximity: ProximityTrend = .unavailable

    private var wear: WearState = .unknown(.noHeadphonesConnected)
    private var gaze: GazeState = .unknown
    private var lastInput: Date?
    private var disconnectedAt: Date?
    private var awaySince: Date?
    private var lastWornAt: Date?

    mutating func observe(wear newValue: WearState, at now: Date) {
        wear = newValue
        switch newValue {
        case .worn:
            lastWornAt = now
            disconnectedAt = nil
        case .unknown(.noHeadphonesConnected):
            // A sample gap neither starts the clock nor cancels one a disconnect already started.
            if disconnectedAt == nil, wasWornRecently(at: now) { disconnectedAt = now }
        case .unknown:
            break
        }
    }

    mutating func observe(gaze newValue: GazeState) {
        gaze = newValue
        if case .looking = newValue { awaySince = nil }
    }

    mutating func observeInput(at now: Date) {
        lastInput = now
        awaySince = nil
    }

    mutating func reset() {
        self = AwayEvidence()
    }

    /// Latches the instant away was first asserted, so the away policy measures from a stable start.
    mutating func resolve(at now: Date) -> PresenceState {
        // Wear arrives as a change, not a heartbeat, so this keeps "worn recently" current.
        if wear.isWorn { lastWornAt = now }

        if hasInput(within: Self.inputPresenceWindow, at: now) { return .present }
        if let awaySince { return .away(since: awaySince) }

        if wear.isWorn {
            if isWalking, proximity == .falling || gaze == .away { return assertAway(at: now) }
            return .present
        }

        if let disconnectedAt {
            let lastProofOfPresence = max(disconnectedAt, lastInput ?? .distantPast)
            if now.timeIntervalSince(lastProofOfPresence) >= Self.disconnectIdleGrace {
                return assertAway(at: now)
            }
        }
        if hasInput(within: Self.disconnectIdleGrace, at: now) { return .present }
        return .unknown
    }

    private func hasInput(within window: TimeInterval, at now: Date) -> Bool {
        guard let lastInput else { return false }
        return now.timeIntervalSince(lastInput) < window
    }

    private func wasWornRecently(at now: Date) -> Bool {
        guard let lastWornAt else { return false }
        return now.timeIntervalSince(lastWornAt) <= Self.recentWearWindow
    }

    private mutating func assertAway(at now: Date) -> PresenceState {
        awaySince = now
        let summary = "wear=\(wear) walking=\(isWalking) gaze=\(gaze) proximity=\(proximity)"
        Log.presence.notice("Away asserted (\(summary, privacy: .public))")
        return .away(since: now)
    }
}
