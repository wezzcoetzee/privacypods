import Foundation

/// Whether the headphones are on a head that the app can read.
///
/// There is deliberately no `notWorn` case. The sensors cannot distinguish "in the case",
/// "on the desk" and "connected but silent", and conflating any of them with "the user left"
/// is the failure mode that makes an app like this unusable. Everything that is not a live
/// stream of samples is `unknown`, and `unknown` never justifies blurring away or locking.
enum WearState: Hashable, Sendable {
    case worn
    case unknown(Reason)

    enum Reason: Hashable, Sendable {
        /// No headphones with a gyro are connected to this Mac.
        case noHeadphonesConnected
        /// Connected, but samples stopped arriving. In the case, off the head, or handed
        /// over to an iPhone by automatic device switching.
        case sampleGap
        /// This Mac or these headphones cannot provide head motion at all.
        case motionUnavailable
        case permissionDenied
    }

    var isWorn: Bool { self == .worn }
}

/// Which display, if any, the user is looking at.
enum GazeState: Hashable, Sendable {
    case looking(DisplayID)
    case away
    /// No trustworthy head data. Distinct from `away`, and must never be substituted for it.
    case unknown

    var display: DisplayID? {
        if case .looking(let display) = self { display } else { nil }
    }
}

/// Whether the user is at the machine.
enum PresenceState: Hashable, Sendable {
    case present
    /// A sensor gap. Cannot escalate to blur-and-lock on its own.
    case unknown
    case away(since: Date)

    var isAway: Bool {
        if case .away = self { true } else { false }
    }
}

/// What the away policy wants done, given how long the user has been away.
///
/// Ordered so a driver can compare against what it has already done and only act on escalation.
enum AwayResponse: Int, Hashable, Sendable, Comparable, CaseIterable {
    case idle = 0
    case blur = 1
    case lock = 2

    static func < (lhs: AwayResponse, rhs: AwayResponse) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Whether the overlay is showing a blurred picture of a display, or covering it blind.
///
/// The two failures are worth telling apart in the one line the overlay prints: a missing
/// permission is something the user can fix, a dead stream is not. Neither uncovers the screen.
enum CaptureAvailability: Hashable, Sendable {
    case available
    case unavailable(Reason)

    enum Reason: Hashable, Sendable {
        case screenRecordingDenied
        case captureFailed
    }

    /// The line the overlay shows while it cannot blur; `nil` whenever it can.
    var notice: String? {
        switch self {
        case .available: nil
        case .unavailable(.screenRecordingDenied): "PrivacyPods needs Screen Recording"
        case .unavailable(.captureFailed): "PrivacyPods cannot capture this display"
        }
    }
}
