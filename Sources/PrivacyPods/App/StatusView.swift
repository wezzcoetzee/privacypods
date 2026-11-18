import ServiceManagement
import SwiftUI

/// Is PrivacyPods working, and if not, what to do next? Leads with the same status line as the
/// menu, its next step and a count of what needs fixing, then the displays, what the sensors
/// report, the lock, and the permissions. Opens by itself on first launch, so it doubles as
/// setup: until setup is finished it walks through its steps (connect the AirPods, choose what
/// happens if they go quiet, test the lock), each one waiting for the one before it, and the
/// optional permissions wait until head tracking works.
struct StatusView: View {
    let coordinator: AppCoordinator
    let openSettings: () -> Void

    @State private var statuses: [Permission: PermissionStatus]
    /// Decided once when the window opens, so the row does not vanish under the pointer the
    /// moment it is switched on.
    @State private var offersLaunchAtLogin: Bool
    /// Whether this window opened during setup, so it can say so once setup is finished in it.
    @State private var openedDuringSetup: Bool

    init(coordinator: AppCoordinator, openSettings: @escaping () -> Void) {
        self.coordinator = coordinator
        self.openSettings = openSettings
        // Seeded from the auditor's cache, so the first frame is already laid out for the real
        // answer instead of jumping once the first poll lands.
        _statuses = State(initialValue: Self.read(coordinator.permissions))
        // Offered in the first Status window only; after that it lives in Settings, and a user who
        // chose off is not asked again.
        let settings = coordinator.settings.settings
        _offersLaunchAtLogin = State(initialValue: !settings.launchAtLogin && !settings.launchAtLoginOffered)
        _openedDuringSetup = State(initialValue: !settings.setupFinished)
    }

    private var settings: AppSettings { coordinator.settings.settings }
    private var isSettingUp: Bool { !settings.setupFinished }
    /// Whether walking away can lock, so there is a lock to test at all.
    private var locks: Bool { settings.awayPolicy != .doNothing }

    var body: some View {
        let issues = coordinator.issues
        // Until Motion is allowed only Motion matters: the optional permissions wait for head
        // tracking, the same rule the menu follows. During setup its first step says it instead.
        let shownPermissions: [Permission] = statuses[.motion] == .granted ? Permission.allCases
            : isSettingUp ? [] : [.motion]
        // Floated to the top only while there is something to answer; a declined optional
        // permission is the user's answer and waits at the bottom with the rest.
        let needsPermissions = shownPermissions.contains { permission in
            let status = statuses[permission] ?? .notDetermined
            return status == .notDetermined || (permission == .motion && status != .granted)
        }
        Pane(width: 520) {
            headline(issues: issues)
            if isSettingUp { setupSteps }
            if needsPermissions { permissions(shownPermissions) }
            // Displays and sensors have nothing to say before there is head data to say it about.
            if coordinator.isHeadTrackingReady {
                displays
                detection
            }
            // One place for the lock, whatever state it is in, live failure included. During
            // setup that place is its last step.
            if !isSettingUp, coordinator.lockFailedAt != nil || issues.contains(.lockUntested)
                || (coordinator.isLockTested && locks) {
                lock
            }
            if !needsPermissions, !shownPermissions.isEmpty { permissions(shownPermissions) }
            if offersLaunchAtLogin { startup }
        }
        .task { await pollPermissions() }
        .onDisappear {
            if offersLaunchAtLogin { coordinator.settings.settings.launchAtLoginOffered = true }
        }
    }

    // MARK: - Sections

    /// The status and its one next step. Each issue is said once, in its own section next to the
    /// button that fixes it; the headline only counts them. Until the AirPods are connected for
    /// the first time, there is no status worth leading with, so setup leads instead.
    @ViewBuilder
    private func headline(issues: [Issue]) -> some View {
        let status = coordinator.status
        let toFix = issues.filter { !$0.isSetupStep }.count
        VStack(alignment: .leading, spacing: 6) {
            if isSettingUp, !coordinator.isHeadTrackingReady {
                Text("Set up PrivacyPods")
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(setupSummary(coversScreens: status.coversScreensMeanwhile)).fixedSize(horizontal: false, vertical: true)
                // A refused Motion is orange in the first step; orange is always counted.
                if toFix > 0 { fixCount(toFix) }
            } else {
                Text(status.title)
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let effect = status.effect { Text(effect) }
                if openedDuringSetup, !isSettingUp { Text("Setup is done.") }
                if let step = status.nextStep(hotkey: hotkey, canType: coordinator.canType) {
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
                let toSetUp = issues.filter(\.isSetupStep).count
                if toFix > 0 {
                    fixCount(toFix)
                // During setup the numbered steps already say what is left.
                } else if toSetUp > 0, !isSettingUp {
                    Text(toSetUp == 1 ? "1 setup step below." : "\(toSetUp) setup steps below.")
                }
            }
        }
    }

    private func fixCount(_ count: Int) -> some View {
        Text(count == 1 ? "1 thing to fix below." : "\(count) things to fix below.")
            .foregroundStyle(.orange)
    }

    /// "Three steps. Until the first is done, screens stay readable." Nothing in setup changes
    /// what the screens do until the AirPods are connected, so this stays true until then.
    private func setupSummary(coversScreens: Bool?) -> String {
        let count = locks ? "Three steps." : "Two steps."
        guard let coversScreens else { return count }
        return "\(count) Until the first is done, screens stay \(coversScreens ? "blurred" : "readable")."
    }

    /// Setup, one step per row, each waiting for the one before it: the choice and the lock test
    /// mean nothing until there is head data.
    private var setupSteps: some View {
        let ready = coordinator.isHeadTrackingReady
        let waiting = "Available once your AirPods are connected."
        return PaneSection(title: "Steps") {
            LabeledContent {
                Text(connectionStep).foregroundStyle(statuses[.motion] == .denied ? .orange : .white)
                if statuses[.motion] == .denied {
                    Button("Open System Settings…") { coordinator.request(.motion) }.fixedSize()
                }
            } label: {
                StepLabel(number: 1, title: "Connect your AirPods", detail: statuses[.motion] == .denied
                    ? Permission.motion.rationale
                    : ready ? nil
                    : "AirPods Pro, AirPods (3rd generation or later), AirPods Max or Beats Fit Pro. macOS then asks to allow Motion.")
            }
            LabeledContent {
                Picker("If they go quiet", selection: chosenFailMode) {
                    ForEach(FailMode.allCases) { Text($0.title).tag(Optional($0)) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(!ready)
            } label: {
                StepLabel(number: 2, title: "If they go quiet", detail: ready
                    ? "Out, in the case, or taken by your iPhone. This never locks the Mac."
                    : waiting)
            }
            if locks {
                LabeledContent {
                    if ready { lockState }
                    Button("Lock Now to Test", action: coordinator.lockNow).fixedSize().disabled(!ready)
                } label: {
                    StepLabel(number: 3, title: "Test the lock", detail: !ready ? waiting
                        : coordinator.lockFailedAt != nil ? Issue.lockAdvice
                        : coordinator.isLockTested ? nil
                        : "PrivacyPods locks the screen when you walk away. Test it once now, so the first time is not when you have already gone.")
                }
                if coordinator.lockFailedAt != nil { lockRemedies.padding(.top, 8) }
            }
        }
    }

    private var connectionStep: String {
        if statuses[.motion] == .denied { return "Motion not allowed" }
        if coordinator.wearState == .unknown(.noHeadphonesConnected) { return "Waiting" }
        return statuses[.motion] == .granted ? "Connected" : "Waiting for Motion"
    }

    /// The fail mode as setup shows it: no answer selected until the owner gives one.
    private var chosenFailMode: Binding<FailMode?> {
        Binding(
            get: { settings.failModeChosen ? settings.failMode : nil },
            set: { if let mode = $0 { coordinator.settings.settings.choose(failMode: mode) } }
        )
    }

    private func permissions(_ shown: [Permission]) -> some View {
        PaneSection(title: "Permissions") {
            if statuses.values.allSatisfy({ $0 == .granted }) && statuses.count == Permission.allCases.count {
                LabeledContent(Permission.allCases.map(\.title).formatted(.list(type: .and)), value: "All allowed")
            } else {
                ForEach(shown) { permission in
                    PermissionRow(
                        permission: permission,
                        status: statuses[permission] ?? .notDetermined,
                        isCounted: coordinator.issues.contains { $0 == .permission(permission) && !$0.isSetupStep },
                        request: coordinator.canRequest(permission) ? { coordinator.request(permission) } : nil
                    )
                }
            }
            // A denied Screen Recording is already a row above; only a failed stream is news.
            if coordinator.captureAvailability == .unavailable(.captureFailed),
               let notice = coordinator.captureAvailability.notice {
                HStack {
                    PaneNotice(text: notice)
                    Spacer()
                    Button("Try Again", action: coordinator.retryCapture).fixedSize()
                }
            }
        }
    }

    /// The lock in one row with one state (not tested, works, or failed), one test button, and
    /// the cause and remedies only while they apply.
    private var lock: some View {
        let failedAt = coordinator.lockFailedAt
        return PaneSection(title: "Lock") {
            LabeledContent("Screen lock") {
                lockState
                Button("Lock Now to Test", action: coordinator.lockNow).fixedSize()
            }
            if failedAt != nil || !coordinator.isLockTested {
                Text(failedAt != nil
                    ? Issue.lockAdvice
                    : "PrivacyPods locks the screen when you walk away. Test it once now, so the first time is not when you have already gone.")
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                lockRemedies.padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var lockState: some View {
        if let failedAt = coordinator.lockFailedAt {
            Text("Failed at \(failedAt.formatted(date: .omitted, time: .shortened))").foregroundStyle(.orange)
        } else {
            Text(coordinator.isLockTested ? "Works" : "Not tested yet")
        }
    }

    private var lockRemedies: some View {
        HStack {
            Spacer()
            Button("Open Lock Screen Settings…") { NSWorkspace.shared.open(Self.lockScreenSettings) }
            if coordinator.lockFailedAt != nil { Button("Dismiss", action: coordinator.dismissLockFailure) }
        }
    }

    /// Offered here as well as in Settings while it is off: a privacy tool that is not running
    /// after a restart protects nothing, and this window is where a new user sets things up.
    private var startup: some View {
        PaneSection(title: "Startup") {
            LabeledContent("Launch at login") {
                Toggle("Launch at login", isOn: Bindable(coordinator.settings).settings.launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            LoginItemApprovalNotice(isOn: coordinator.settings.settings.launchAtLogin)
        }
    }

    /// Each display's anchor, and a line under any display that needs something: an overlap with
    /// the one you are looking at, or no anchor yet when anchoring can work right now and the
    /// headline is not already saying how.
    private var displays: some View {
        let explainsAnchoring = coordinator.canReanchor && !coordinator.status.isAboutAnchoring
        return PaneSection(title: "Displays") {
            ForEach(coordinator.displays) { display in
                let state = anchorState(for: display.id)
                LabeledContent(display.name, value: state.title)
                    .help(anchorSource(for: display.id))
                switch state {
                case .overlapping:
                    HStack {
                        PaneNotice(text: "\(display.name) overlaps the display you're looking at, so PrivacyPods can mix them up. Narrow Horizontal range to fix it.", tone: .info)
                        Spacer()
                        Button("Open Settings…", action: openSettings).fixedSize()
                    }
                case .notAnchored where explainsAnchoring:
                    PaneNotice(text: AppStatus.anchoringAdvice(for: display.name, hotkey: hotkey, canType: coordinator.canType), tone: .info)
                default:
                    EmptyView()
                }
            }
            if !coordinator.isReanchorHotkeyAvailable {
                HStack {
                    PaneNotice(text: Issue.hotkeyTakenText(coordinator.settings.settings.reanchorHotkey.label))
                    Spacer()
                    Button("Change Re-anchor Shortcut…", action: openSettings).fixedSize()
                }
            }
        }
    }

    private var detection: some View {
        PaneSection(title: "Detection") {
            LabeledContent("AirPods") {
                Text(wearDescription)
                if coordinator.wearState == .unknown(.motionUnavailable) {
                    Button("Restart Head Tracking", action: coordinator.restartHeadTracking).fixedSize()
                }
            }
            LabeledContent("Presence", value: coordinator.presenceState.title)
                .help(Issue.awayRule(canType: coordinator.canType))
        }
    }

    // MARK: - Helpers

    private static let lockScreenSettings = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!

    /// `nil` while another app holds the shortcut, so nothing tells the user to press a dead key.
    private var hotkey: String? {
        coordinator.isReanchorHotkeyAvailable ? coordinator.settings.settings.reanchorHotkey.label : nil
    }

    /// TCC sends no change notifications, so a grant made in System Settings only shows up if
    /// the window asks again. The loop lives for as long as the window does: `WindowController`
    /// drops a closed window, which tears this view down and cancels the task.
    private func pollPermissions() async {
        while !Task.isCancelled {
            coordinator.refreshPermissions()
            statuses = Self.read(coordinator.permissions)
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private static func read(_ permissions: any PermissionAuditing) -> [Permission: PermissionStatus] {
        Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, permissions.status(of: $0)) })
    }

    private var wearDescription: String {
        switch coordinator.wearState {
        case .worn: "Worn"
        case .unknown(let reason): reason.title
        }
    }

    private enum AnchorState {
        case notAnchored, lookingHere, anchored, inRange, outOfRange
        /// In range while another display wins: the overlap the README warns about.
        case overlapping

        var title: String {
            switch self {
            case .notAnchored: "Not anchored yet"
            case .lookingHere: "Looking here"
            case .anchored: "Anchored"
            case .inRange: "In range"
            case .outOfRange: "Out of range"
            case .overlapping: "Overlapping"
            }
        }
    }

    /// Which display wins, and whether the head is inside each one's range right now.
    private func anchorState(for id: DisplayID) -> AnchorState {
        guard let anchor = coordinator.gaze.anchors[id] else { return .notAnchored }
        if coordinator.gazeState == .looking(id) { return .lookingHere }
        guard let pose = coordinator.displayPose else { return .anchored }
        guard coordinator.settings.settings.acceptanceCone.contains(pose.offset(from: anchor.pose)) else { return .outOfRange }
        return coordinator.gazeState.display == nil ? .inRange : .overlapping
    }

    private func anchorSource(for id: DisplayID) -> String {
        switch coordinator.gaze.anchors[id]?.source {
        case .hotkey: "Anchored with the shortcut."
        case .sustainedInput: "Anchored automatically, from typing or pointer movement."
        case nil: "Put the pointer on this display, look at it, and type or press the shortcut."
        }
    }
}

/// A setup step's label: its number, what to do, and the one line that says how or why.
private struct StepLabel: View {
    let number: Int
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(number)").monospacedDigit().frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let status: PermissionStatus
    /// Whether the headline counts this row as a thing to fix, which is what orange means.
    let isCounted: Bool
    /// `nil` when there is nothing left to ask: already granted, or only answerable by starting
    /// a sensor the run gate currently owns.
    let request: (() -> Void)?

    var body: some View {
        LabeledContent {
            HStack {
                Text(statusText)
                    .foregroundStyle(isCounted ? .orange : .white)
                    .fixedSize()
                if let request {
                    let title = status == .denied ? "Open System Settings…" : "Allow…"
                    Button(title, action: request)
                        .fixedSize()
                        .accessibilityLabel(status == .denied ? "Open System Settings for \(permission.title)" : "Allow \(permission.title)")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                // The why only where there is something to decide, and where to find it in
                // System Settings only once that is where the button goes.
                if status != .granted, request != nil {
                    Text([permission.rationale, status == .denied ? permission.systemSettingsNote : nil]
                        .compactMap { $0 }.joined(separator: " "))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var statusText: String {
        // Motion and Bluetooth have no prompt of their own: macOS raises them when their sensor
        // first starts.
        if status == .notDetermined, request == nil {
            switch permission {
            case .motion: return "Asked when head tracking starts"
            case .bluetooth: return "Asked when you first wear AirPods"
            default: break
            }
        }
        return status.title
    }
}

/// Shown under a Launch at login switch that is on while macOS still holds the login item for
/// approval, with the way to give it. Shared by Settings and Status.
struct LoginItemApprovalNotice: View {
    let isOn: Bool

    var body: some View {
        if isOn, SMAppService.mainApp.status == .requiresApproval {
            HStack {
                PaneNotice(text: "Waiting for your approval in Login Items.")
                Spacer()
                Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
    }
}
