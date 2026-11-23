import AppKit
import Observation

/// Owns every provider's lifetime and is the single reader of every `AsyncStream`.
///
/// One gate sits above everything: enabled and unlocked. Sensors, overlay and lock all hang off
/// it, and closing it also cancels the away escalation and forgets the away evidence.
@MainActor
@Observable
final class AppCoordinator {
    private let headTracking: any HeadTrackingProviding
    private let inputActivity: any InputActivityProviding
    private let hotkey: ReanchorHotkeyMonitor
    private let overlay: any OverlayControlling
    private let presence: any PresenceProviding
    private let screenLock: any ScreenLocking
    let gaze: any GazeClassifying
    let permissions: any PermissionAuditing
    let settings: SettingsStore

    private(set) var wearState: WearState = .unknown(.motionUnavailable)
    private(set) var gazeState: GazeState = .unknown
    private(set) var presenceState: PresenceState = .unknown
    private(set) var isLocked: Bool = false
    private(set) var displays: [DisplayInfo] = []
    /// Throttled to `displayPoseInterval`: 50 Hz samples would invalidate SwiftUI at the refresh rate.
    private(set) var displayPose: HeadPose?
    /// `false` when another app holds the combination.
    private(set) var isReanchorHotkeyAvailable = true
    private(set) var captureAvailability: CaptureAvailability = .available
    /// A lock the away policy asked for did not take effect. Cleared when the user comes back.
    private(set) var didFailToLock = false
    /// Outlives `didFailToLock`: the owner only reads the menu once they are back.
    private(set) var lockFailedAt: Date?

    private var policy: AwayPolicyRunner
    /// So a settings change reconfigures only what it affects.
    private var appliedSettings: AppSettings
    private var displayPoseUpdatedAt: Date?
    private var tasks: [Task<Void, Never>] = []
    private var escalation: Task<Void, Never>?
    private var lockCheck: Task<Void, Never>?
    private var resumeTimer: Task<Void, Never>?
    private(set) var isCovering = false
    /// The display being looked at, or every display, is covered. A display blurred by design
    /// while you look at another one does not count.
    private(set) var coversView = false
    private var screenParametersObserver: (any NSObjectProtocol)?
    private var isTornDown = false
    private var didPostHeadDataNotice = false

    private static let lockConfirmationDelay: Duration = .seconds(3)
    private static let menuGlanceDuration: Duration = .seconds(1)
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
        settings: SettingsStore
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

    func reanchorNow() {
        guard let display = DisplayInfo.containing(NSEvent.mouseLocation)?.id else { return }
        gaze.anchor(display, source: .hotkey)
    }

    /// Picking a menu item means looking up at the menu bar, so the pose is taken a moment later.
    /// The display is fixed at the click, since the pointer may already be heading elsewhere.
    func reanchorAfterMenu() {
        guard let display = DisplayInfo.containing(NSEvent.mouseLocation)?.id else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.menuGlanceDuration)
            self?.gaze.anchor(display, source: .hotkey)
        }
    }

    /// `nil` pauses until `resume()`.
    func pause(for duration: TimeInterval?) {
        settings.settings.resumeAt = duration.map { Date().addingTimeInterval($0) }
        settings.settings.isEnabled = false
        scheduleResume()
    }

    func resume() {
        resumeTimer?.cancel()
        settings.settings.resumeAt = nil
        settings.settings.isEnabled = true
    }

    /// Also runs at start: a timed pause outlives a relaunch.
    private func scheduleResume() {
        resumeTimer?.cancel()
        guard !settings.settings.isEnabled, let resumeAt = settings.settings.resumeAt else { return }
        let delay = max(0, resumeAt.timeIntervalSinceNow)
        resumeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.resume()
        }
    }

    var canType: Bool {
        permissions.status(of: .inputMonitoring) == .granted
    }

    /// An undetermined Motion can only be prompted by probing the motion stream, which belongs to
    /// the run gate, so it is not requestable while tracking runs.
    func canRequest(_ permission: Permission) -> Bool {
        let status = permissions.status(of: permission)
        guard status != .granted else { return false }
        // macOS asks for Bluetooth itself when proximity first starts, with the AirPods on.
        if permission == .bluetooth, status == .notDetermined { return false }
        guard permission == .motion, status == .notDetermined else { return true }
        return !isRunGateOpen
    }

    /// The UI requests through here, never the auditor, so a Motion probe cannot bypass the run gate.
    func request(_ permission: Permission) {
        guard canRequest(permission) else { return }
        permissions.request(permission)
    }

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

    /// Reads the auditor's cache; call `refreshPermissions()` first for fresh statuses.
    var issues: [Issue] {
        Issue.current(
            lockFailedAt: lockFailedAt,
            lockUntested: !settings.settings.lockTested && settings.settings.awayPolicy != .doNothing
                && permissions.status(of: .motion) == .granted,
            failModeUnchosen: !settings.settings.failModeChosen && permissions.status(of: .motion) == .granted,
            permissions: permissions.status(of:),
            capture: captureAvailability,
            isCovering: isCovering,
            isHotkeyAvailable: isReanchorHotkeyAvailable,
            hotkey: settings.settings.reanchorHotkey
        )
    }

    var isHeadTrackingReady: Bool {
        wearState != .unknown(.noHeadphonesConnected) && permissions.status(of: .motion) == .granted
    }

    /// The fail mode can be chosen in Settings before the AirPods ever connect, so the owner's
    /// steps alone do not finish setup.
    private func finishSetupIfDone() {
        guard !settings.settings.setupFinished, settings.settings.hasDoneSetupSteps, isHeadTrackingReady else { return }
        settings.settings.setupFinished = true
    }

    var hasUnanchoredDisplay: Bool {
        displays.contains { gaze.anchors[$0.id] == nil }
    }

    func displayName(_ id: DisplayID) -> String {
        displays.first { $0.id == id }?.name ?? "an unknown display"
    }

    var canReanchor: Bool {
        isRunGateOpen && wearState.isWorn
    }

    var isLockTested: Bool {
        settings.settings.lockTested
    }

    func dismissLockFailure() {
        lockFailedAt = nil
    }

    /// Also restarts the tracker after a Motion grant made in System Settings: nothing else would.
    func refreshPermissions() {
        permissions.refresh()
        if isRunGateOpen, wearState == .unknown(.permissionDenied), permissions.status(of: .motion) == .granted {
            headTracking.start()
        }
        if captureAvailability == .unavailable(.screenRecordingDenied), permissions.status(of: .screenRecording) == .granted {
            retryCapture()
        }
    }

    func restartHeadTracking() {
        headTracking.stop()
        if isRunGateOpen { headTracking.start() }
    }

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

    /// `@Observable` tracking is one-shot, so the closure re-arms itself.
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

        finishSetupIfDone()

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

    /// Idempotent, so it can run on any state change.
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
            if let reason = HeadDataNotice.reasonToPost(
                from: wearState, to: state, settings: settings.settings, alreadyPosted: didPostHeadDataNotice
            ) {
                didPostHeadDataNotice = true
                HeadDataNotice.post(reason)
            }
            wearState = state
            finishSetupIfDone()
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

        // Escalation depends on elapsed time, not on further events, so re-ask on a timer.
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
            // Settle a pending check here: an unlock inside its window (Touch ID, a Watch) must
            // not read as a failure.
            if lockCheck != nil {
                lockCheck?.cancel()
                lockCheck = nil
                settings.settings.lockTested = true
            }
        }
        applyRunState()
    }

    private func applyPolicy() {
        guard isRunGateOpen else { return }
        guard let action = policy.update(presence: presenceState, at: Date()) else { return }
        switch action {
        case .lock:
            Log.app.notice("Away policy is locking the screen")
            lockNow()
        case .clear:
            didFailToLock = false
        case .blur:
            break
        }
        recomputeOverlay()
    }

    /// `screenLock.lock()` succeeding is not proof: its fallback only sleeps the displays. The lock
    /// notification is the proof, so its absence after a few seconds counts as a failure.
    func lockNow() {
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
        settings.settings.lockTested = false
        didFailToLock = isRunGateOpen && presenceState.isAway
        lockFailedAt = Date()
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

    /// Only for blurs that looking would not clear. An away blur says nothing: whoever reads it is
    /// not the owner.
    nonisolated static func overlayNotice(
        gaze: GazeState,
        wearState: WearState,
        awayResponse: AwayResponse,
        hotkey: String?,
        canType: Bool,
        displayIsAnchored: Bool = true
    ) -> String? {
        guard awayResponse < .blur else { return nil }
        // "Away" may be the user looking at this unanchored display, which looking would never clear.
        if gaze == .away, !displayIsAnchored {
            let input = canType ? "type" : "move the pointer around"
            return "Looking here? This display is not anchored yet. Put the pointer here and \(input)"
                + (hotkey.map { ", or press \($0)." } ?? ".")
        }
        guard gaze == .unknown else { return nil }
        guard case .unknown(let reason) = wearState else {
            return "Not anchored. " + AppStatus.anchoringAdvice(hotkey: hotkey, canType: canType)
        }
        let fix =
            switch reason {
            case .sampleGap: "Put them back in"
            case .noHeadphonesConnected: "Connect them"
            case .permissionDenied: "Choose Allow Motion… in the PrivacyPods menu"
            case .motionUnavailable: "Choose Status… in the PrivacyPods menu and click Restart Head Tracking"
            }
        return "\(reason.title). \(fix), or choose Pause in the PrivacyPods menu."
    }

    /// An away escalation covers every display whatever the blur mode; a closed run gate clears all.
    nonisolated static func blurredDisplays(
        settings: AppSettings,
        gaze: GazeState,
        allDisplays: Set<DisplayID>,
        awayResponse: AwayResponse,
        isLocked: Bool
    ) -> Set<DisplayID> {
        guard settings.isEnabled, !isLocked else { return [] }
        if awayResponse >= .blur { return allDisplays }
        return settings.blurMode.displaysToBlur(gaze: gaze, allDisplays: allDisplays, failMode: settings.failMode)
    }

    private var isRunGateOpen: Bool {
        settings.settings.isEnabled && !isLocked
    }
}
