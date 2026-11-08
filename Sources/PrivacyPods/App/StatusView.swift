import ServiceManagement
import SwiftUI

/// Is PrivacyPods working, and if not, what to do next? Leads with the same status line as the
/// menu, its next step and a count of what needs fixing, then the displays, what the sensors
/// report, the lock, and the permissions. Opens by itself on first launch, so it doubles as
/// setup; until the AirPods are connected and Motion is allowed it shows only what can be done.
struct StatusView: View {
    let coordinator: AppCoordinator
    let openSettings: () -> Void

    @State private var statuses: [Permission: PermissionStatus]
    /// Decided once when the window opens, so the row does not vanish under the pointer the
    /// moment it is switched on.
    @State private var offersLaunchAtLogin: Bool

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
    }

    var body: some View {
        let issues = coordinator.issues
        // Floated to the top only while there is something to answer; a declined optional
        // permission is the user's answer and waits at the bottom with the rest.
        let needsPermissions = statuses.contains { permission, status in
            status == .notDetermined || (permission == .motion && status != .granted)
        }
        // Displays and sensors have nothing to say before there is head data to say it about.
        let canDiagnose = coordinator.wearState != .unknown(.noHeadphonesConnected)
            && statuses[.motion] == .granted
        Pane(width: 520) {
            headline(issues: issues)
            if needsPermissions { permissions }
            if canDiagnose {
                displays
                detection
            }
            // One place for the lock, whatever state it is in, live failure included.
            if coordinator.lockFailedAt != nil || issues.contains(.lockUntested)
                || (coordinator.isLockTested && coordinator.settings.settings.awayPolicy != .doNothing) {
                lock
            }
            if !needsPermissions { permissions }
            if offersLaunchAtLogin { startup }
        }
        .task { await pollPermissions() }
        .onDisappear {
            if offersLaunchAtLogin { coordinator.settings.settings.launchAtLoginOffered = true }
        }
    }

    // MARK: - Sections

    /// The status and its one next step. Each issue is said once, in its own section next to the
    /// button that fixes it; the headline only counts them.
    private func headline(issues: [Issue]) -> some View {
        let status = coordinator.status
        return VStack(alignment: .leading, spacing: 6) {
            Text(status.title)
                .font(.system(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if let step = status.nextStep(hotkey: hotkey, canType: coordinator.canType) {
                Text(step).fixedSize(horizontal: false, vertical: true)
            }
            let toFix = issues.filter { !$0.isSetupStep }.count
            let toSetUp = issues.filter(\.isSetupStep).count
            if toFix > 0 {
                Text(toFix == 1 ? "1 thing to fix below." : "\(toFix) things to fix below.")
                    .foregroundStyle(.orange)
            } else if toSetUp > 0 {
                Text(toSetUp == 1 ? "1 setup step below." : "\(toSetUp) setup steps below.")
            }
        }
    }

    private var permissions: some View {
        PaneSection(title: "Permissions") {
            if statuses.values.allSatisfy({ $0 == .granted }) && statuses.count == Permission.allCases.count {
                LabeledContent(Permission.allCases.map(\.title).formatted(.list(type: .and)), value: "All allowed")
            } else {
                ForEach(Permission.allCases) { permission in
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
                if let failedAt {
                    Text("Failed at \(failedAt.formatted(date: .omitted, time: .shortened))").foregroundStyle(.orange)
                } else {
                    Text(coordinator.isLockTested ? "Works" : "Not tested yet")
                }
                Button("Lock Now to Test", action: coordinator.lockNow).fixedSize()
            }
            if failedAt != nil || !coordinator.isLockTested {
                Text(failedAt != nil
                    ? Issue.lockAdvice
                    : "PrivacyPods locks the screen when you walk away. Test it once now, so the first time is not when you have already gone.")
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                HStack {
                    Spacer()
                    Button("Open Lock Screen Settings…") { NSWorkspace.shared.open(Self.lockScreenSettings) }
                    if failedAt != nil { Button("Dismiss", action: coordinator.dismissLockFailure) }
                }
                .padding(.top, 8)
            }
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

    private var displays: some View {
        PaneSection(title: "Displays") {
            ForEach(coordinator.displays) { display in
                LabeledContent(display.name, value: anchorDescription(for: display.id))
                    .help(anchorDescription(for: display.id) == "Also in range"
                        ? "This display's range overlaps the one you are looking at. If the wrong display wins, narrow Horizontal range in Settings."
                        : anchorSource(for: display.id))
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

    /// Which display wins, and whether the head is inside each one's range right now. Two
    /// displays "in range" at once is the overlap the README warns about.
    private func anchorDescription(for id: DisplayID) -> String {
        guard let anchor = coordinator.gaze.anchors[id] else { return "Not anchored" }
        if coordinator.gazeState == .looking(id) { return "Looking here" }
        guard let pose = coordinator.displayPose else { return "Anchored" }
        // In range while another display wins is the overlap the README warns about.
        let inRange = coordinator.settings.settings.acceptanceCone.contains(pose.offset(from: anchor.pose))
        return inRange ? (coordinator.gazeState.display == nil ? "In range" : "Also in range") : "Out of range"
    }

    private func anchorSource(for id: DisplayID) -> String {
        switch coordinator.gaze.anchors[id]?.source {
        case .hotkey: "Anchored with the shortcut."
        case .sustainedInput: "Anchored automatically, from typing or pointer movement."
        case nil: "Put the pointer on this display, look at it, and type or press the shortcut."
        }
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
                // The why only where there is something to decide.
                if status != .granted, request != nil {
                    Text(permission.rationale)
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
