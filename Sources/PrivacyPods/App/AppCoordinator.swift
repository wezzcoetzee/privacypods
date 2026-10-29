import AppKit
import Observation

/// The hub. Builds nothing itself (see `ProviderFactory`) but owns every provider's lifetime,
/// is the single reader of every `AsyncStream`, and pushes results into whoever needs them.
/// Sensors and effects are referenced only through their Core protocol; the re-anchor hotkey
/// and the settings store have no protocol because nothing else implements them.
///
/// One gate sits above everything else: enabled and unlocked. Sensors, overlay and lock all
/// hang off that single predicate, so a disabled app or an already-locked screen neither
/// watches nor touches the screen. Closing it also cancels the away escalation and forgets the
/// away evidence, so a session that ended with the user walking off cannot colour the one that
/// starts when they come back.
@MainActor
@Observable
final class AppCoordinator {
    private let headTracking: any HeadTrackingProviding
    private let inputActivity: any InputActivityProviding
    private let hotkey: ReanchorHotkeyMonitor
    private let overlay: any OverlayControlling
    private let presence: any PresenceProviding
    private let screenLock: any ScreenLocking
    private let timeSource: any TimeSource
    let gaze: any GazeClassifying
    let permissions: any PermissionAuditing
    let settings: SettingsStore

    private(set) var wearState: WearState = .unknown(.motionUnavailable)
    private(set) var gazeState: GazeState = .unknown
    private(set) var presenceState: PresenceState = .unknown
    private(set) var isLocked: Bool = false
    private(set) var displays: [DisplayInfo] = []
    /// The pose the calibration window reads. Samples arrive at ~50 Hz, which is both faster
    /// than anyone can read and fast enough to invalidate a SwiftUI form at the refresh rate,
    /// so it is republished at `displayPoseInterval` and cleared whenever the head data stops.
    private(set) var displayPose: HeadPose?
    /// `false` when the re-anchor combination could not be registered, usually because another
    /// app already holds it. With Input Monitoring denied the hotkey is the only way left to
    /// anchor, so the calibration window says so rather than letting it fail silently.
    private(set) var isReanchorHotkeyAvailable = true
    /// Whether the overlay is blurring a picture of the screen or covering it blind, mirrored
    /// from the overlay so the calibration window can say which.
    private(set) var captureAvailability: CaptureAvailability = .available
    /// `true` when a lock the away policy asked for did not take effect. The displays stay
    /// blurred, so nothing is exposed, but the Mac is not locked and the user has to be told
    /// rather than left believing it is. Cleared when they come back or the screen does lock.
    private(set) var didFailToLock = false

    private var policy: AwayPolicyRunner
    /// The settings the providers were last configured with, so a change can be applied to the
    /// one thing it affects rather than restarting everything.
    private var appliedSettings: AppSettings
    private var displayPoseUpdatedAt: Date?
    private var tasks: [Task<Void, Never>] = []
    private var escalation: Task<Void, Never>?
    private var screenParametersObserver: (any NSObjectProtocol)?
    private var isTornDown = false

    /// How often the calibration window's live numbers are allowed to change.
    private static let displayPoseInterval: TimeInterval = 0.1

    init(
        headTracking: any HeadTrackingProviding,
        inputActivity: any InputActivityProviding,
        hotkey: ReanchorHotkeyMonitor,
        gaze: any GazeClassifying,
        overlay: any OverlayControlling,
        presence: any PresenceProviding,
        screenLock: any ScreenLocking,
        permissions: any PermissionAuditing,
        settings: SettingsStore,
        timeSource: any TimeSource = SystemTimeSource()
    ) {
        self.headTracking = headTracking
        self.inputActivity = inputActivity
        self.hotkey = hotkey
        self.gaze = gaze
        self.overlay = overlay
        self.presence = presence
        self.screenLock = screenLock
        self.permissions = permissions
        self.settings = settings
        self.timeSource = timeSource
        policy = AwayPolicyRunner(policy: settings.settings.awayPolicy)
        appliedSettings = settings.settings
    }

    func start() {
        isLocked = screenLock.isLocked
        captureAvailability = overlay.captureAvailability
        wearState = headTracking.wearState
        gazeState = gaze.state
        presenceState = presence.state
        refreshDisplays()
        subscribe()
        observeSettings()
        applyRunState()
    }

    func stop() {
        isTornDown = true
        tasks.forEach { $0.cancel() }
        tasks = []
        escalation?.cancel()
        escalation = nil
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        screenParametersObserver = nil
        headTracking.stop()
        inputActivity.stop()
        presence.stop()
        hotkey.unregister()
        overlay.teardown()
    }

    /// Re-anchors the display under the cursor right now, same as the global hotkey.
    func reanchorNow() {
        guard let display = DisplayInfo.containing(NSEvent.mouseLocation)?.id else { return }
        gaze.anchor(display, source: .hotkey)
    }

    /// Everything that follows from the toggle happens in `applyRunState`, driven by the
    /// settings observer, so the menu bar and the settings window cannot diverge.
    func setEnabled(_ enabled: Bool) {
        settings.settings.isEnabled = enabled
    }

    /// Whether a "Grant…" button makes sense for `permission` right now.
    ///
    /// Motion is the exception. The only way to raise its prompt is to probe the motion stream,
    /// which belongs to the run gate, so an undetermined Motion status is unanswerable while
    /// tracking is already running — and while it is running the status is known anyway. A
    /// Motion status that TCC has already decided only ever opens System Settings, which the
    /// gate has no opinion about.
    func canRequest(_ permission: Permission) -> Bool {
        let status = permissions.status(of: permission)
        guard status != .granted else { return false }
        guard permission == .motion, status == .notDetermined else { return true }
        return !isRunGateOpen
    }

    /// Requests `permission`, routing Motion through the run gate so its probe can never start
    /// the motion stream behind the gate's back.
    func request(_ permission: Permission) {
        guard canRequest(permission) else { return }
        permissions.request(permission)
    }

    /// One line for the menu bar: what the user is doing right now, from the coordinator's
    /// point of view. Kept as a pure function of state so it is trivially testable.
    var statusLine: String {
        Self.statusLine(
            isEnabled: settings.settings.isEnabled,
            wearState: wearState,
            gazeState: gazeState,
            presenceState: presenceState,
            didFailToLock: didFailToLock,
            displayName: { id in displays.first(where: { $0.id == id })?.name }
        )
    }

    nonisolated static func statusLine(
        isEnabled: Bool,
        wearState: WearState,
        gazeState: GazeState,
        presenceState: PresenceState,
        didFailToLock: Bool,
        displayName: (DisplayID) -> String?
    ) -> String {
        guard isEnabled else { return "Disabled" }
        // Outranks everything below it: the app was asked to lock, said it would, and did not.
        if didFailToLock { return "Could not lock the screen" }
        if presenceState.isAway { return "Away" }
        if case .unknown(let reason) = wearState {
            switch reason {
            case .noHeadphonesConnected: return "No AirPods connected"
            case .sampleGap: return "No head data"
            case .motionUnavailable: return "Head tracking unavailable"
            case .permissionDenied: return "Motion access denied"
            }
        }
        switch gazeState {
        case .looking(let id): return "Looking at: \(displayName(id) ?? id.description)"
        case .away: return "Looking away"
        case .unknown: return "Not anchored yet"
        }
    }

    // MARK: - Subscriptions

    private func subscribe() {
        tasks = [
            Task { [weak self] in
                guard let events = self?.headTracking.events else { return }
                for await event in events { self?.handle(event) }
            },
            Task { [weak self] in
                guard let events = self?.inputActivity.events else { return }
                for await activity in events { self?.handle(activity) }
            },
            Task { [weak self] in
                guard let events = self?.hotkey.events else { return }
                for await _ in events { self?.reanchorNow() }
            },
            Task { [weak self] in
                guard let events = self?.gaze.events else { return }
                for await state in events { self?.handle(gazeState: state) }
            },
            Task { [weak self] in
                guard let events = self?.presence.events else { return }
                for await state in events { self?.handle(presenceState: state) }
            },
            Task { [weak self] in
                guard let events = self?.screenLock.events else { return }
                for await locked in events { self?.handle(locked: locked) }
            },
            Task { [weak self] in
                guard let events = self?.overlay.captureEvents else { return }
                for await availability in events { self?.captureAvailability = availability }
            },
        ]

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays() }
        }
    }

    /// `@Observable` tracking is one-shot, so the closure re-arms itself. Settings are applied
    /// field by field: the ones that reconfigure a provider do so, and everything else simply
    /// re-runs the overlay decision.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.settings
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isTornDown else { return }
                self.settingsChanged()
                self.observeSettings()
            }
        }
    }

    private func settingsChanged() {
        let new = settings.settings
        let old = appliedSettings
        appliedSettings = new

        if new.acceptanceCone != old.acceptanceCone || new.awayGrace != old.awayGrace {
            gaze.update(cone: new.acceptanceCone, awayGrace: new.awayGrace)
        }
        if new.awayPolicy != old.awayPolicy {
            policy.policy = new.awayPolicy
        }
        if new.isEnabled != old.isEnabled || new.reanchorHotkey != old.reanchorHotkey {
            applyRunState()
        } else {
            recomputeOverlay()
        }
    }

    // MARK: - Run state

    /// Starts or stops every provider to match the enable toggle and the lock state. Idempotent:
    /// each provider's `start()` and `stop()` is, so this can run on any state change.
    ///
    /// A locked screen stops the sensors as firmly as the toggle does. There is nothing to
    /// protect behind the lock window, and the anchors are worth no more than the session they
    /// were recorded in: the motion stream picks a new reference frame every time it restarts,
    /// and the first burst of typing after the user returns anchors it again.
    private func applyRunState() {
        if isRunGateOpen {
            headTracking.start()
            inputActivity.start()
            presence.start()
            isReanchorHotkeyAvailable = hotkey.register(settings.settings.reanchorHotkey)
        } else {
            headTracking.stop()
            inputActivity.stop()
            presence.stop()
            hotkey.unregister()
            isReanchorHotkeyAvailable = true
            escalation?.cancel()
            escalation = nil
            policy = AwayPolicyRunner(policy: settings.settings.awayPolicy)
            didFailToLock = false
            displayPose = nil
            displayPoseUpdatedAt = nil
        }

        recomputeOverlay()
    }

    // MARK: - Event handling

    private func handle(_ event: HeadTrackingEvent) {
        switch event {
        case .sample(let sample):
            publish(pose: sample.pose, at: sample.timestamp)
        case .wearState(let state):
            wearState = state
            if !state.isWorn {
                displayPose = nil
                displayPoseUpdatedAt = nil
            }
        }
        gaze.ingest(event)
        presence.ingest(event)
    }

    private func handle(_ activity: InputActivity) {
        presence.ingest(activity)
        if case .sustained(_, let cursor) = activity, let display = DisplayInfo.containing(cursor)?.id {
            gaze.anchor(display, source: .sustainedInput)
        }
    }

    private func handle(gazeState: GazeState) {
        self.gazeState = gazeState
        presence.ingest(gaze: gazeState)
        recomputeOverlay()
    }

    private func handle(presenceState: PresenceState) {
        self.presenceState = presenceState
        escalation?.cancel()
        escalation = nil
        applyPolicy()

        // Escalation is a function of elapsed time rather than of any further event, so while
        // the user is away the policy has to be asked again on a timer. Once it has reached
        // `.lock` there is nothing left to escalate to.
        guard isRunGateOpen, presenceState.isAway, policy.response != .lock else { return }
        escalation = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.isRunGateOpen, self.presenceState.isAway else { return }
                self.applyPolicy()
                if self.policy.response == .lock { return }
            }
        }
    }

    private func handle(locked: Bool) {
        isLocked = locked
        applyRunState()
    }

    /// The away escalation, behind the same gate as the overlay: a disabled app or a locked
    /// screen neither blurs nor locks, whatever the policy has escalated to.
    private func applyPolicy() {
        guard isRunGateOpen else { return }
        guard let action = policy.update(presence: presenceState, at: timeSource.now) else { return }
        switch action {
        case .lock:
            Log.app.notice("Away policy is locking the screen")
            didFailToLock = !screenLock.lock()
            if didFailToLock {
                Log.app.error("The screen did not lock; the displays stay blurred instead")
            }
        case .clear:
            didFailToLock = false
        case .blur:
            break
        }
        recomputeOverlay()
    }

    private func publish(pose: HeadPose, at instant: Date) {
        if let last = displayPoseUpdatedAt, instant.timeIntervalSince(last) < Self.displayPoseInterval { return }
        displayPose = pose
        displayPoseUpdatedAt = instant
    }

    private func refreshDisplays() {
        displays = DisplayInfo.current()
        gaze.retainOnly(Set(displays.map(\.id)))
        recomputeOverlay()
    }

    private func recomputeOverlay() {
        let toBlur = Self.blurredDisplays(
            settings: settings.settings,
            gaze: gazeState,
            allDisplays: Set(displays.map(\.id)),
            awayResponse: policy.response,
            isLocked: isLocked
        )
        overlay.setBlurred(toBlur, radius: settings.settings.blurRadius)
    }

    /// What should be blurred right now, as a pure function of state. An away escalation to
    /// `.blur` or `.lock` overrides the blur-mode matrix and covers every display; a locked
    /// screen or a disabled app always clears it, regardless of gaze or away state.
    nonisolated static func blurredDisplays(
        settings: AppSettings,
        gaze: GazeState,
        allDisplays: Set<DisplayID>,
        awayResponse: AwayResponse,
        isLocked: Bool
    ) -> Set<DisplayID> {
        guard isRunGateOpen(isEnabled: settings.isEnabled, isLocked: isLocked) else { return [] }
        if awayResponse >= .blur { return allDisplays }
        return settings.blurMode.displaysToBlur(gaze: gaze, allDisplays: allDisplays, failMode: settings.failMode)
    }

    /// The run gate. Sensors, overlay and lock all sit behind it, so the app can neither watch
    /// nor touch the screen while it is disabled or the screen is already locked.
    nonisolated static func isRunGateOpen(isEnabled: Bool, isLocked: Bool) -> Bool {
        isEnabled && !isLocked
    }

    private var isRunGateOpen: Bool {
        Self.isRunGateOpen(isEnabled: settings.settings.isEnabled, isLocked: isLocked)
    }
}
