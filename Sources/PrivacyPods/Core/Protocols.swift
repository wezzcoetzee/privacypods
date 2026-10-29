import CoreGraphics
import Foundation

// MARK: - Head tracking

/// Anything the head tracker tells the rest of the app.
enum HeadTrackingEvent: Hashable, Sendable {
    case sample(MotionSample)
    case wearState(WearState)
}

/// Owns `CMHeadphoneMotionManager` and turns it into a wear state plus a sample stream.
///
/// Implementations are responsible for the gap watchdog: if no sample has arrived for longer
/// than the tracker's tolerance, emit `.wearState(.unknown(.sampleGap))` without waiting to be
/// asked. Silence is the only signal AirPods give when they come off a head.
@MainActor
protocol HeadTrackingProviding: AnyObject {
    /// Single-consumer. Created once when the provider is built; the engine is the only reader.
    var events: AsyncStream<HeadTrackingEvent> { get }
    var wearState: WearState { get }

    func start()
    func stop()
}

// MARK: - Input activity

/// Evidence that a human is at the keyboard.
enum InputActivity: Hashable, Sendable {
    /// A single observed keyboard or pointer event. Resets the away timers.
    case activity(at: Date)
    /// A burst dense enough to prove the user is looking at the cursor's display. Implies
    /// `.activity` at the same instant; consumers of `.activity` do not need both.
    case sustained(at: Date, cursor: CGPoint)

    var timestamp: Date {
        switch self {
        case .activity(let date), .sustained(let date, _): date
        }
    }
}

/// Watches global keyboard and pointer events.
///
/// Input Monitoring is what makes keyboard events visible; without it the monitor still sees
/// pointer events, so anchoring degrades rather than stops. `PermissionAuditing` is the single
/// place that reports on that permission.
@MainActor
protocol InputActivityProviding: AnyObject {
    /// Single-consumer, as with `HeadTrackingProviding`.
    var events: AsyncStream<InputActivity> { get }

    func start()
    func stop()
}

// MARK: - Gaze

/// Holds the per-display anchors and decides which display is being looked at.
///
/// Implementations apply the grace window on the way out of `.looking` and switch back to a
/// display immediately, so a glance at a colleague does not flicker the overlay.
@MainActor
protocol GazeClassifying: AnyObject {
    var state: GazeState { get }
    /// Single-consumer. Emits on change only, never repeats the current value.
    var events: AsyncStream<GazeState> { get }
    var anchors: [DisplayID: DisplayAnchor] { get }

    func ingest(_ event: HeadTrackingEvent)
    /// Records the most recent pose as this display's anchor, replacing any existing one.
    func anchor(_ display: DisplayID, source: DisplayAnchor.Source)
    /// Drops anchors for displays that are no longer attached.
    func retainOnly(_ displays: Set<DisplayID>)
    /// Applies changed settings to the pose already held, so widening a cone in the settings
    /// window unblurs immediately instead of at the next sample.
    func update(cone: AcceptanceCone, awayGrace: TimeInterval)
}

// MARK: - Overlay

/// Owns one blur window per display.
@MainActor
protocol OverlayControlling: AnyObject {
    /// Whether the overlay is blurring a live picture of the displays it covers, or covering
    /// them blind. The worst news any covered display has.
    var captureAvailability: CaptureAvailability { get }
    /// Single-consumer. Emits on change only, so read `captureAvailability` at subscribe time.
    var captureEvents: AsyncStream<CaptureAvailability> { get }

    /// Blurs exactly `displays`; anything currently blurred and not listed fades out. Idempotent,
    /// so the engine can call it on every state change without tracking what is already shown.
    func setBlurred(_ displays: Set<DisplayID>, radius: Double)
    /// Tears down every window and stops capture. Called on quit and whenever the app is disabled.
    func teardown()
}

// MARK: - Presence

/// Decides whether the user is at the machine, from head motion, gait, proximity and input.
@MainActor
protocol PresenceProviding: AnyObject {
    var state: PresenceState { get }
    /// Single-consumer. Emits on change only.
    var events: AsyncStream<PresenceState> { get }

    func ingest(_ event: HeadTrackingEvent)
    func ingest(_ activity: InputActivity)
    func ingest(gaze: GazeState)

    func start()
    func stop()
}

// MARK: - Screen lock

/// Locks the screen, and reports whether it is already locked.
@MainActor
protocol ScreenLocking: AnyObject {
    var isLocked: Bool { get }
    /// Single-consumer. `true` when the screen locks, `false` when it unlocks.
    var events: AsyncStream<Bool> { get }

    /// Locks the screen, reporting whether any mechanism took effect. `false` means the Mac is
    /// still showing whatever it was showing, which the caller has to be able to say out loud
    /// rather than assume away.
    @discardableResult
    func lock() -> Bool
}

// MARK: - Permissions

/// Reports and requests the app's TCC permissions for the calibration view.
@MainActor
protocol PermissionAuditing: AnyObject {
    func status(of permission: Permission) -> PermissionStatus
    /// Prompts in-process where the API allows it, otherwise opens `permission.settingsURL`.
    func request(_ permission: Permission)
    /// Re-reads every status. Called when the calibration view appears and when the app
    /// returns to the foreground, because TCC gives no change notifications.
    func refresh()
}
