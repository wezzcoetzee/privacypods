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
    /// The pose the Status window reads to say whether each display is in range. Samples arrive at ~50 Hz, which is both faster
    /// than anyone can read and fast enough to invalidate a SwiftUI form at the refresh rate,
    /// so it is republished at `displayPoseInterval` and cleared whenever the head data stops.
    private(set) var displayPose: HeadPose?
    /// `false` when the re-anchor combination could not be registered, usually because another
    /// app already holds it. With Input Monitoring denied the hotkey is the only way left to
    /// anchor, so the Status window says so rather than letting it fail silently.
    private(set) var isReanchorHotkeyAvailable = true
    /// Whether the overlay is blurring a picture of the screen or covering it blind, mirrored
    /// from the overlay so the Status window can say which.
    private(set) var captureAvailability: CaptureAvailability = .available
    /// `true` when a lock the away policy asked for did not take effect. The displays stay
    /// blurred, so nothing is exposed, but the Mac is not locked and the user has to be told
    /// rather than left believing it is. Cleared when they come back or the screen does lock.
    private(set) var didFailToLock = false
    /// When the last lock failure happened. Outlives `didFailToLock`, which clears the moment the
    /// user is back: the owner is the one who needs to hear about it, and they only look at the
    /// menu once they have returned. Cleared by a lock that works, or once the owner has seen it.
    private(set) var lockFailedAt: Date?

    private var policy: AwayPolicyRunner
    /// The settings the providers were last configured with, so a change can be applied to the
    /// one thing it affects rather than restarting everything.
    private var appliedSettings: AppSettings
    private var displayPoseUpdatedAt: Date?
    private var tasks: [Task<Void, Never>] = []
    private var escalation: Task<Void, Never>?
    private var lockCheck: Task<Void, Never>?
    private var resumeTimer: Task<Void, Never>?
    /// Whether anything is covered right now, so Status and Settings can rise above the sheet.
    private(set) var isCovering = false
    /// Whether the display being looked at, or every display, is covered: what the icon's slash
    /// means. A display blurred by design while you look at another one is not news.
    private(set) var coversView = false
    private var screenParametersObserver: (any NSObjectProtocol)?
    private var isTornDown = false

    private static let lockConfirmationDelay: Duration = .seconds(3)
    private static let menuGlanceDuration: Duration = .seconds(1)

    /// How often the Status window's live numbers are allowed to change.
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
        scheduleResume()
    }

    func stop() {
        isTornDown = true
        tasks.forEach { $0.cancel() }
        tasks = []
        escalation?.cancel()
        escalation = nil
        lockCheck?.cancel()
        resumeTimer?.cancel()
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

    /// Re-anchors from the menu. Picking a menu item means looking up at the menu bar, so the
    /// pose is taken a moment later, once the head is back on the display.
    /// The display is the one under the pointer at the click, which is the one whose menu bar was
    /// used; only the pose waits, since the pointer may already be heading elsewhere.
    func reanchorAfterMenu() {
        guard let display = DisplayInfo.containing(NSEvent.mouseLocation)?.id else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.menuGlanceDuration)
            self?.gaze.anchor(display, source: .hotkey)
        }
    }

    /// Pauses for `duration`, or until `resume()` when `nil`. Everything that follows happens in
    /// `applyRunState`, driven by the settings observer.
    func pause(for duration: TimeInterval?) {
        settings.settings.resumeAt = duration.map { timeSource.now.addingTimeInterval($0) }
        settings.settings.isEnabled = false
        scheduleResume()
    }

    func resume() {
        resumeTimer?.cancel()
        settings.settings.resumeAt = nil
        settings.settings.isEnabled = true
    }

    /// A timed pause outlives a relaunch, so this runs at start as well as when pausing.
    private func scheduleResume() {
        resumeTimer?.cancel()
        guard !settings.settings.isEnabled, let resumeAt = settings.settings.resumeAt else { return }
        let delay = max(0, resumeAt.timeIntervalSince(timeSource.now))
        resumeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.resume()
        }
    }

    /// Whether typing reaches the app, so no instruction tells the user to type for nothing.
    var canType: Bool {
        permissions.status(of: .inputMonitoring) == .granted
    }

    /// Whether an "Allow…" button makes sense for `permission` right now.
    ///
    /// Motion is the exception. The only way to raise its prompt is to probe the motion stream,
    /// which belongs to the run gate, so an undetermined Motion status is unanswerable while
    /// tracking is already running, and while it is running the status is known anyway. A
    /// Motion status that TCC has already decided only ever opens System Settings, which the
    /// gate has no opinion about.
    func canRequest(_ permission: Permission) -> Bool {
        let status = permissions.status(of: permission)
        guard status != .granted else { return false }
        // macOS asks for Bluetooth itself when proximity first starts, with the AirPods on.
        if permission == .bluetooth, status == .notDetermined { return false }
        guard permission == .motion, status == .notDetermined else { return true }
        return !isRunGateOpen
    }

    /// Requests `permission`, routing Motion through the run gate so its probe can never start
    /// the motion stream behind the gate's back.
    func request(_ permission: Permission) {
        guard canRequest(permission) else { return }
        permissions.request(permission)
    }

    /// What the menu bar shows: the status line, its icon and the icon's VoiceOver label.
    var status: AppStatus {
        AppStatus.current(
            settings: settings.settings,
            wearState: wearState,
            gazeState: gazeState,
            presenceState: presenceState,
            didFailToLock: didFailToLock,
            hasUnanchoredDisplay: hasUnanchoredDisplay,
            displayName: displayName
        )
    }

    /// Things the user can fix, worst first. Permissions are read from the auditor's cache, so
    /// callers that need them fresh call `permissions.refresh()` first.
    var issues: [Issue] {
        Issue.current(
            lockFailedAt: lockFailedAt,
            // Offered once head tracking can work, so first run is only about getting there.
            lockUntested: !settings.settings.lockTested && settings.settings.awayPolicy != .doNothing
                && permissions.status(of: .motion) == .granted,
            permissions: permissions.status(of:),
            capture: captureAvailability,
            isCovering: isCovering,
            isHotkeyAvailable: isReanchorHotkeyAvailable,
            hotkey: settings.settings.reanchorHotkey
        )
    }

    /// Whether some attached display has no anchor, so looking at it cannot be told from looking
    /// away.
    var hasUnanchoredDisplay: Bool {
        displays.contains { gaze.anchors[$0.id] == nil }
    }

    /// The name macOS gives a display, for anywhere the UI would otherwise print an ID.
    func displayName(_ id: DisplayID) -> String {
        displays.first { $0.id == id }?.name ?? "an unknown display"
    }

    /// Re-anchoring needs head data to record, so it only does anything while the app is running
    /// and the AirPods are worn.
    var canReanchor: Bool {
        isRunGateOpen && wearState.isWorn
    }

    /// Locks now, from the Status window, so the owner can check that a change to Lock Screen
    /// settings worked. A lock that takes clears the failure on its own.
    func lockNow() {
        lock()
    }

    /// Whether a lock started by PrivacyPods has ever been seen to take on this Mac. Until then the
    /// owner is offered a test, so the first real lock is not also the first try.
    var isLockTested: Bool {
        settings.settings.lockTested
    }

    func dismissLockFailure() {
        lockFailedAt = nil
    }

    /// Re-reads every permission, and picks up a Motion grant made in System Settings while the
    /// app was running: the tracker refused to start without it and nothing else restarts it.
    func refreshPermissions() {
        permissions.refresh()
        if isRunGateOpen, wearState == .unknown(.permissionDenied), permissions.status(of: .motion) == .granted {
            headTracking.start()
        }
        // A blind sheet would otherwise keep asking for a permission that has just been given.
        if captureAvailability == .unavailable(.screenRecordingDenied), permissions.status(of: .screenRecording) == .granted {
            retryCapture()
        }
    }

    /// Stops and starts the motion stream, for a tracker that stopped on an error.
    func restartHeadTracking() {
        headTracking.stop()
        if isRunGateOpen { headTracking.start() }
    }

    /// Rebuilds every overlay surface, which restarts their captures. For a stream that failed
    /// for a reason that has since gone away.
    func retryCapture() {
        overlay.teardown()
        recomputeOverlay()
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
        if locked {
            lockFailedAt = nil
            // The lock notification is the proof a pending check waits for. Settle it here: an
            // unlock inside the check's window (Touch ID, a Watch) must not read as a failure.
            if lockCheck != nil {
                lockCheck?.cancel()
                lockCheck = nil
                settings.settings.lockTested = true
            }
        }
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
            lock()
        case .clear:
            didFailToLock = false
        case .blur:
            break
        }
        recomputeOverlay()
    }

    /// Locks, and then checks that it worked. `lock()` reporting success is not proof: its
    /// fallback only sleeps the displays, which locks nothing unless the password delay is set to
    /// immediately. The lock notification is the proof, so its absence after a few seconds counts
    /// as a failure.
    private func lock() {
        guard screenLock.lock() else {
            lockFailed()
            return
        }
        lockCheck?.cancel()
        lockCheck = Task { [weak self] in
            try? await Task.sleep(for: Self.lockConfirmationDelay)
            guard let self, !Task.isCancelled else { return }
            self.lockCheck = nil
            if self.screenLock.isLocked {
                self.settings.settings.lockTested = true
            } else {
                self.lockFailed()
            }
        }
    }

    private func lockFailed() {
        Log.app.error("The screen did not lock; the displays stay blurred instead")
        // A lock that worked once and has now failed is not "working".
        settings.settings.lockTested = false
        didFailToLock = isRunGateOpen && presenceState.isAway
        lockFailedAt = timeSource.now
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
        let hotkey = isReanchorHotkeyAvailable ? settings.settings.reanchorHotkey.label : nil
        isCovering = !toBlur.isEmpty
        coversView = isCovering && (gazeState.display.map(toBlur.contains) ?? true)
        var notices: [DisplayID: String] = [:]
        for id in toBlur {
            notices[id] = Self.overlayNotice(
                gaze: gazeState, wearState: wearState, awayResponse: policy.response, hotkey: hotkey, canType: canType,
                displayIsAnchored: gaze.anchors[id] != nil
            )
        }
        overlay.setBlurred(toBlur, radius: settings.settings.blurRadius, notices: notices)
    }

    /// The line a blurred display carries when looking at it would not, on its own, clear it.
    /// A normal look-away blur clears the moment the user looks back, so it says nothing, and an
    /// away blur says nothing because whoever is reading it is not the owner.
    nonisolated static func overlayNotice(
        gaze: GazeState,
        wearState: WearState,
        awayResponse: AwayResponse,
        hotkey: String?,
        canType: Bool,
        displayIsAnchored: Bool = true
    ) -> String? {
        guard awayResponse < .blur else { return nil }
        // "Away" may be the user looking at a display that has no anchor yet, and looking at it
        // would never clear it, so that display, and only that one, says how to anchor it.
        if gaze == .away, !displayIsAnchored {
            let input = canType ? "type" : "move the pointer around"
            return "Looking here? This display is not anchored yet. Put the pointer here and \(input)"
                + (hotkey.map { ", or press \($0)." } ?? ".")
        }
        guard gaze == .unknown else { return nil }
        guard case .unknown(let reason) = wearState else {
            return "Not anchored. " + AppStatus.anchoringAdvice(hotkey: hotkey, canType: canType)
        }
        let fix = switch reason {
        case .sampleGap: "Put them back in"
        case .noHeadphonesConnected: "Connect them"
        case .permissionDenied: "Choose Allow Motion… in the PrivacyPods menu"
        case .motionUnavailable: "Choose Status… in the PrivacyPods menu and click Restart Head Tracking"
        }
        return "\(reason.title). \(fix), or choose Pause in the PrivacyPods menu."
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
