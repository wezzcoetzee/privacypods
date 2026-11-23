import Foundation

/// There is deliberately no `notWorn` case. The sensors cannot tell "in the case", "on the desk"
/// and "connected but silent" apart, so anything that is not a live sample stream is `unknown`,
/// and `unknown` never justifies blurring away or locking.
enum WearState: Hashable, Sendable {
    case worn
    case unknown(Reason)

    enum Reason: Hashable, Sendable {
        case noHeadphonesConnected
        /// Connected, but samples stopped: off the head, in the case, or taken by an iPhone.
        case sampleGap
        case motionUnavailable
        case permissionDenied
    }

    var isWorn: Bool { self == .worn }
}

enum GazeState: Hashable, Sendable {
    case looking(DisplayID)
    case away
    /// No trustworthy head data. Must never be substituted for `away`.
    case unknown

    var display: DisplayID? {
        if case .looking(let display) = self { display } else { nil }
    }
}

enum PresenceState: Hashable, Sendable {
    case present
    /// A sensor gap. Cannot escalate to blur-and-lock on its own.
    case unknown
    case away(since: Date)

    var isAway: Bool {
        if case .away = self { true } else { false }
    }
}

/// Ordered so a driver can act only on escalation.
enum AwayResponse: Int, Hashable, Sendable, Comparable {
    case idle = 0
    case blur = 1
    case lock = 2

    static func < (lhs: AwayResponse, rhs: AwayResponse) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Whether the overlay is showing a blurred picture of a display, or covering it blind.
enum CaptureAvailability: Hashable, Sendable {
    case available
    case unavailable(Reason)

    enum Reason: Hashable, Sendable {
        case screenRecordingDenied
        case captureFailed
    }

    var notice: String? {
        switch self {
        case .available: nil
        case .unavailable(.screenRecordingDenied):
            "This display is dark because Screen Recording is off. To blur it instead, choose Allow Screen Recording… in the PrivacyPods menu."
        case .unavailable(.captureFailed):
            "PrivacyPods cannot capture this display, so it stays covered. To try again, choose Retry Display Capture in the PrivacyPods menu."
        }
    }
}
