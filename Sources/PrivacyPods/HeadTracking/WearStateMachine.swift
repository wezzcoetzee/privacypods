import Foundation

/// Turns the handful of facts CoreMotion exposes into a `WearState`.
///
/// Kept free of CoreMotion so the one rule that actually matters — how long silence is
/// tolerated before the stream counts as untrustworthy — can be stepped in tests.
///
/// AirPods say nothing when they come off a head: the sample stream simply stops. The only
/// honest reading of silence is `.unknown(.sampleGap)`, which is why there is no `notWorn`
/// case to reach for.
struct WearStateMachine {
    /// Everything that can change the answer. `tick` is the watchdog heartbeat and is the only
    /// signal that can notice silence.
    enum Signal: Hashable, Sendable {
        /// Updates requested. `headphonesAvailable` mirrors `isDeviceMotionAvailable`, which
        /// means "headphones with a gyro are connected", never "we are allowed to read them".
        case started(authorization: PermissionStatus, headphonesAvailable: Bool)
        case stopped
        case headphonesConnected
        case headphonesDisconnected
        case sampleArrived
        /// The motion handler reported an error.
        case failed(Failure)
        case tick
    }

    /// Why the motion handler gave up. The two resolve differently: a refusal is something the
    /// user can undo in System Settings, anything else is the sensor being the sensor.
    enum Failure: Hashable, Sendable {
        case notAuthorized
        case unavailable
    }

    /// AirPods stream at ~50 Hz, so 1.5 s of silence is roughly 75 missing samples: far past
    /// any plausible hiccup, and short enough that the overlay reacts while the user is still
    /// walking away.
    static let defaultGapTolerance: TimeInterval = 1.5

    let gapTolerance: TimeInterval
    private(set) var state: WearState = .unknown(.motionUnavailable)

    private var isRunning = false
    private var hasFailed = false
    private var authorization: PermissionStatus = .notDetermined
    private var headphonesConnected = false
    private var lastSampleAt: Date?

    init(gapTolerance: TimeInterval = Self.defaultGapTolerance) {
        self.gapTolerance = gapTolerance
    }

    /// Applies a signal and returns the new state, or `nil` when the answer did not change.
    /// Callers yield only the non-`nil` results, which is what keeps the event stream
    /// change-only as the Core contract requires.
    mutating func apply(_ signal: Signal, at now: Date) -> WearState? {
        switch signal {
        case .started(let authorization, let headphonesAvailable):
            isRunning = true
            hasFailed = false
            self.authorization = authorization
            headphonesConnected = headphonesAvailable
            lastSampleAt = nil
        case .stopped:
            isRunning = false
            lastSampleAt = nil
        case .headphonesConnected:
            headphonesConnected = true
        case .headphonesDisconnected:
            headphonesConnected = false
            lastSampleAt = nil
        case .sampleArrived:
            // Data is better evidence than any flag CoreMotion offers: a sample can only
            // reach us from connected headphones we are allowed to read.
            headphonesConnected = true
            authorization = .granted
            hasFailed = false
            lastSampleAt = now
        case .failed(let failure):
            hasFailed = true
            lastSampleAt = nil
            if failure == .notAuthorized { authorization = .denied }
        case .tick:
            break
        }

        let resolved = resolution(now: now)
        guard resolved != state else { return nil }
        state = resolved
        return resolved
    }

    /// A refusal outranks a generic failure: both stop the samples, but only one tells the
    /// user what to do about it.
    private func resolution(now: Date) -> WearState {
        guard isRunning else { return .unknown(.motionUnavailable) }
        guard authorization != .denied else { return .unknown(.permissionDenied) }
        guard !hasFailed else { return .unknown(.motionUnavailable) }
        guard headphonesConnected else { return .unknown(.noHeadphonesConnected) }
        guard let lastSampleAt, now.timeIntervalSince(lastSampleAt) <= gapTolerance else {
            return .unknown(.sampleGap)
        }
        return .worn
    }
}
