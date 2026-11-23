import Foundation

/// Kept free of CoreMotion so the sample-gap rule can be stepped in tests.
struct WearStateMachine {
    enum Signal: Hashable, Sendable {
        /// `headphonesAvailable` mirrors `isDeviceMotionAvailable`, which means "headphones with a
        /// gyro are connected", never "we are allowed to read them".
        case started(authorization: PermissionStatus, headphonesAvailable: Bool)
        case stopped
        case headphonesConnected
        case headphonesDisconnected
        case sampleArrived
        case failed(Failure)
        /// The watchdog heartbeat: the only signal that can notice silence.
        case tick
    }

    enum Failure: Hashable, Sendable {
        case notAuthorized
        case unavailable
    }

    /// About 75 missing samples at ~50 Hz: past any hiccup, short enough to react while the user
    /// is still walking away.
    private static let gapTolerance: TimeInterval = 1.5

    private(set) var state: WearState = .unknown(.motionUnavailable)

    private var isRunning = false
    private var hasFailed = false
    private var authorization: PermissionStatus = .notDetermined
    private var headphonesConnected = false
    private var lastSampleAt: Date?

    /// Returns the new state, or `nil` when it did not change.
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
            // A sample can only come from connected headphones we are allowed to read.
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

    /// A refusal outranks a generic failure: only one tells the user what to do about it.
    private func resolution(now: Date) -> WearState {
        guard isRunning else { return .unknown(.motionUnavailable) }
        guard authorization != .denied else { return .unknown(.permissionDenied) }
        guard !hasFailed else { return .unknown(.motionUnavailable) }
        guard headphonesConnected else { return .unknown(.noHeadphonesConnected) }
        guard let lastSampleAt, now.timeIntervalSince(lastSampleAt) <= Self.gapTolerance else {
            return .unknown(.sampleGap)
        }
        return .worn
    }
}
