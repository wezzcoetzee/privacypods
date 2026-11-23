import AppKit
import CoreGraphics

@MainActor
final class InputActivityMonitor: InputActivityProviding {
    let events: AsyncStream<InputActivity>

    private let continuation: AsyncStream<InputActivity>.Continuation
    private var monitors: [Any] = []
    private var permissionWatch: Task<Void, Never>?
    private var detector = SustainedInputDetector()
    private var lastActivity: Date?

    /// Throttle: mouse-moved events alone arrive about sixty times a second.
    private let activityInterval: TimeInterval = 0.5

    /// TCC sends no notification when Input Monitoring is granted mid-session, so poll.
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

    /// Global sees other apps, local sees our own windows; never the same event. Pointer events
    /// need no Input Monitoring, so install regardless.
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

    /// Keyboard events only reach monitors installed after the Input Monitoring grant, so reinstall.
    private func watchForPermission() {
        guard !hasInputMonitoring else { return }
        Log.gaze.notice("Input Monitoring not granted: keyboard anchoring unavailable until it is")
        permissionWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.permissionPollInterval) } catch { return }
                // A cancel landing as the sleep finishes must not reinstall monitors `stop()` removed.
                guard let self, !Task.isCancelled else { return }
                guard hasInputMonitoring else { continue }
                Log.gaze.notice("Input Monitoring granted: reinstalling the event monitors")
                install()
                return
            }
        }
    }

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

    /// Key repeats and momentum scroll are excluded: neither shows anyone is still at the desk.
    private static func kind(of event: NSEvent) -> SustainedInputDetector.Kind? {
        switch event.type {
        case .keyDown: event.isARepeat ? nil : .key
        case .scrollWheel: event.momentumPhase.isEmpty ? .pointer : nil
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: .pointer
        default: nil
        }
    }
}
