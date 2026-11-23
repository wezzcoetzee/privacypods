import CoreGraphics
import Foundation

// Every `events` stream is single-consumer (the coordinator is the only reader) and emits on
// change only, so read the paired state property for the value at subscribe time.

// MARK: - Head tracking

enum HeadTrackingEvent: Hashable, Sendable {
    case sample(MotionSample)
    case wearState(WearState)
}

/// Implementations own the gap watchdog: once no sample has arrived for longer than the
/// tolerance, emit `.wearState(.unknown(.sampleGap))` unprompted. Silence is the only signal
/// AirPods give when they come off a head.
@MainActor
protocol HeadTrackingProviding: AnyObject {
    var events: AsyncStream<HeadTrackingEvent> { get }
    var wearState: WearState { get }

    func start()
    func stop()
}

// MARK: - Input activity

enum InputActivity: Hashable, Sendable {
    case activity(at: Date)
    /// A burst dense enough to prove the user is looking at the cursor's display. Implies `.activity`.
    case sustained(at: Date, cursor: CGPoint)

    var timestamp: Date {
        switch self {
        case .activity(let date), .sustained(let date, _): date
        }
    }
}

@MainActor
protocol InputActivityProviding: AnyObject {
    var events: AsyncStream<InputActivity> { get }

    func start()
    func stop()
}

// MARK: - Gaze

/// Implementations damp the way out of `.looking` with a grace window and switch back to a
/// display immediately, so a glance away does not flicker the overlay.
@MainActor
protocol GazeClassifying: AnyObject {
    var state: GazeState { get }
    var events: AsyncStream<GazeState> { get }
    var anchors: [DisplayID: DisplayAnchor] { get }

    func ingest(_ event: HeadTrackingEvent)
    /// Records the most recent pose as this display's anchor.
    func anchor(_ display: DisplayID, source: DisplayAnchor.Source)
    func retainOnly(_ displays: Set<DisplayID>)
    /// Re-judges the pose already held, so widening a cone unblurs immediately.
    func update(cone: AcceptanceCone, awayGrace: TimeInterval)
}

// MARK: - Overlay

@MainActor
protocol OverlayControlling: AnyObject {
    /// The worst news any covered display has.
    var captureAvailability: CaptureAvailability { get }
    var captureEvents: AsyncStream<CaptureAvailability> { get }

    /// Absolute and idempotent: anything currently blurred and not listed fades out.
    func setBlurred(_ displays: Set<DisplayID>, radius: Double, notices: [DisplayID: String])
    func teardown()
}

// MARK: - Presence

@MainActor
protocol PresenceProviding: AnyObject {
    var state: PresenceState { get }
    var events: AsyncStream<PresenceState> { get }

    func ingest(_ event: HeadTrackingEvent)
    func ingest(_ activity: InputActivity)
    func ingest(gaze: GazeState)

    func start()
    func stop()
}

// MARK: - Screen lock

@MainActor
protocol ScreenLocking: AnyObject {
    var isLocked: Bool { get }
    var events: AsyncStream<Bool> { get }

    /// `false` means nothing took effect and the Mac is still showing the screen.
    func lock() -> Bool
}

// MARK: - Permissions

@MainActor
protocol PermissionAuditing: AnyObject {
    func status(of permission: Permission) -> PermissionStatus
    /// Prompts in-process where the API allows it, otherwise opens `permission.settingsURL`.
    func request(_ permission: Permission)
    /// TCC sends no change notifications, so callers re-read on demand.
    func refresh()
}
