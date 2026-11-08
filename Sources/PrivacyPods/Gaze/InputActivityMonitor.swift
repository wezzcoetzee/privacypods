import AppKit
import CoreGraphics

/// Watches keyboard and pointer events and reports the two things the rest of the app cares
/// about: that a human is here at all, and that they are engaged enough to be looking at the
/// display under the cursor.
@MainActor
final class InputActivityMonitor: InputActivityProviding {
    let events: AsyncStream<InputActivity>

    private let continuation: AsyncStream<InputActivity>.Continuation
    /// The global and local `NSEvent` monitors, empty while stopped.
    private var monitors: [Any] = []
    private var permissionWatch: Task<Void, Never>?
    private var detector = SustainedInputDetector()
    private var lastActivity: Date?

    /// `.activity` only resets away timers, so twice a second is as fine-grained as anyone
    /// needs. Mouse-moved events alone arrive sixty times a second.
    private let activityInterval: TimeInterval = 0.5

    /// How often to look for an Input Monitoring grant that arrived mid-session. TCC sends no
    /// notification, and the check is a single preflight call, so polling is the cheap answer.
    private static let permissionPollInterval: Duration = .seconds(5)

    private static let mask: NSEvent.EventTypeMask = [
        .keyDown, .flagsChanged,
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    deinit {
        continuation.finish()
    }

    func start() {
        guard monitors.isEmpty else { return }
        install()
        watchForPermission()
    }

    func stop() {
        permissionWatch?.cancel()
        permissionWatch = nil
        removeMonitors()
        detector.reset()
        lastActivity = nil
    }

    /// A global monitor sees other apps; a local one sees PrivacyPods' own windows. Both are
    /// needed, or typing in the setup or settings window would neither anchor nor count
    /// as activity. They never see the same event, so a burst cannot be double-counted.
    ///
    /// Pointer events arrive without Input Monitoring; keyboard ones do not. Install regardless
    /// so mouse anchoring keeps working while the permission is missing.
    private func install() {
        removeMonitors()
        let global = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    /// Keyboard events start flowing the moment Input Monitoring is granted, but only into
    /// monitors installed after the grant, so the ones we hold have to be replaced. Polling
    /// stops as soon as the grant lands and never starts at all if it is already there.
    private func watchForPermission() {
        guard !hasInputMonitoring else { return }
        Log.gaze.notice("Input Monitoring not granted: keyboard anchoring unavailable until it is")
        permissionWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.permissionPollInterval) } catch { return }
                // A cancel landing while the sleep was already finishing must not reinstall
                // monitors that `stop()` has just torn down.
                guard let self, !Task.isCancelled else { return }
                guard hasInputMonitoring else { continue }
                Log.gaze.notice("Input Monitoring granted: reinstalling the event monitors")
                install()
                return
            }
        }
    }

    /// CoreGraphics' view of the Input Monitoring switch, and a yes or no rather than a
    /// `PermissionStatus`: all this type does with the answer is decide whether to keep
    /// polling. `PermissionAuditing` remains the only place that reports a permission.
    private var hasInputMonitoring: Bool { CGPreflightListenEventAccess() }

    private func handle(_ event: NSEvent) {
        let now = Date()
        if let kind = Self.kind(of: event), detector.record(kind, at: now) {
            lastActivity = now
            continuation.yield(.sustained(at: now, cursor: NSEvent.mouseLocation))
            return
        }
        guard lastActivity.map({ now.timeIntervalSince($0) >= activityInterval }) ?? true else { return }
        lastActivity = now
        continuation.yield(.activity(at: now))
    }

    /// Which events count towards a burst. Clicks and modifier presses prove a human is here but
    /// say nothing about how long they have been engaged, so they only ever mean `.activity`.
    ///
    /// The two exclusions are the same rule twice: a burst has to be evidence of a person
    /// working, and neither a key the hardware is repeating on its own nor a trackpad flick
    /// coasting to a stop says anyone is still at the desk, let alone looking at it.
    private static func kind(of event: NSEvent) -> SustainedInputDetector.Kind? {
        switch event.type {
        case .keyDown: event.isARepeat ? nil : .key
        case .scrollWheel: event.momentumPhase.isEmpty ? .pointer : nil
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: .pointer
        default: nil
        }
    }
}
