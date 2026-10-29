import Foundation

/// The evidence behind `PresenceState`, and the rules that turn it into one.
///
/// Split out of `PresenceEngine` because these rules are the whole product risk: assert away too
/// eagerly and the app locks the screen while its owner is reading. Four rules matter more than
/// the rest, and none of them is negotiable:
///
/// - A sensor gap is not an absence. `WearState.unknown` on its own resolves to
///   `PresenceState.unknown`, never to `.away`, whatever the fail mode says about blurring.
/// - Away needs corroboration. Either the user walked off while wearing the AirPods (rhythmic
///   gait plus a falling signal or a gaze that left every display), or the AirPods left the Mac
///   entirely and nobody has touched the keyboard since.
/// - A keystroke outranks every inference. Somebody typing is at the machine, whatever the
///   accelerometer thinks it heard. It restarts the disconnect clock rather than cancelling it:
///   the AirPods are still gone, so the next silence counts again from that keystroke.
/// - Only a disconnect that interrupts recent wear is evidence. AirPods that have been sitting in
///   their case for an hour say nothing about their owner when they finally drop off the radio.
struct AwayEvidence: Hashable, Sendable {
    struct Configuration: Hashable, Sendable {
        /// How long an AirPods disconnect has to go without a single keystroke or mouse move
        /// before it reads as "the user walked off wearing them" rather than "the user put them
        /// in the case and carried on working".
        var disconnectIdleGrace: TimeInterval = 30
        /// How long a keystroke vouches for the user outright. Gait and proximity are
        /// inferences and they lag; input is proof, so it wins for a few seconds before the
        /// sensors are allowed to argue again.
        var inputPresenceWindow: TimeInterval = 5
        /// How recently the AirPods must have been on a readable head for their disconnect to
        /// mean anything. Past this they were already off, and a Mac must never lock because a
        /// pair of headphones on the desk ran out of battery.
        var recentWearWindow: TimeInterval = 60

        static let `default` = Configuration()
    }

    var configuration: Configuration
    /// Set by the engine from the gait detector before each resolve.
    var isWalking = false
    /// Set by the engine from the Bluetooth monitor before each resolve.
    var proximity: ProximityTrend = .unavailable

    private(set) var wear: WearState = .unknown(.noHeadphonesConnected)
    private(set) var gaze: GazeState = .unknown
    private(set) var lastInput: Date?
    private(set) var disconnectedAt: Date?
    private(set) var awaySince: Date?
    private var lastWornAt: Date?

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    mutating func observe(wear newValue: WearState, at now: Date) {
        wear = newValue
        switch newValue {
        case .worn:
            lastWornAt = now
            disconnectedAt = nil
        case .unknown(.noHeadphonesConnected):
            // Only a real disconnect starts the clock, and only while the AirPods were recently
            // on a head. A sample gap leaves it alone: it neither starts one nor cancels one that
            // a disconnect already started.
            if disconnectedAt == nil, wasWornRecently(at: now) { disconnectedAt = now }
        case .unknown:
            break
        }
    }

    mutating func observe(gaze newValue: GazeState) {
        gaze = newValue
        // Looking at a display is proof the user came back, and it arrives sooner than the next
        // keystroke would.
        if case .looking = newValue { awaySince = nil }
    }

    /// Input proves the user is here now. It restarts the disconnect clock but does not erase the
    /// disconnect itself, so walking off some minutes after the last keystroke still registers.
    mutating func observeInput(at now: Date) {
        lastInput = now
        awaySince = nil
    }

    mutating func reset() {
        self = AwayEvidence(configuration: configuration)
    }

    /// Resolves the current evidence, latching the instant away was first asserted so the away
    /// policy measures from a stable start.
    mutating func resolve(at now: Date) -> PresenceState {
        // Wear arrives as a change, not as a heartbeat, so this tick is the only place a
        // continuously worn pair keeps its "worn recently" timestamp current.
        if wear.isWorn { lastWornAt = now }

        if hasInput(within: configuration.inputPresenceWindow, at: now) { return .present }
        if let awaySince { return .away(since: awaySince) }

        if wear.isWorn {
            if isWalking, proximity == .falling || gaze == .away { return assertAway(at: now) }
            return .present
        }

        if let disconnectedAt {
            let lastProofOfPresence = max(disconnectedAt, lastInput ?? .distantPast)
            if now.timeIntervalSince(lastProofOfPresence) >= configuration.disconnectIdleGrace {
                return assertAway(at: now)
            }
        }
        // The AirPods are gone, but somebody was typing recently enough that "unknown" would be
        // pessimistic.
        if hasInput(within: configuration.disconnectIdleGrace, at: now) { return .present }
        return .unknown
    }

    private func hasInput(within window: TimeInterval, at now: Date) -> Bool {
        guard let lastInput else { return false }
        return now.timeIntervalSince(lastInput) < window
    }

    private func wasWornRecently(at now: Date) -> Bool {
        guard let lastWornAt else { return false }
        return now.timeIntervalSince(lastWornAt) <= configuration.recentWearWindow
    }

    private mutating func assertAway(at now: Date) -> PresenceState {
        awaySince = now
        let summary = "wear=\(wear) walking=\(isWalking) gaze=\(gaze) proximity=\(proximity)"
        Log.presence.notice("Away asserted (\(summary, privacy: .public))")
        return .away(since: now)
    }
}
