import SwiftUI

/// Permissions with live status, live yaw/pitch, and per-display anchor status. This is the
/// only place in the app that shows raw numbers; everything else stays a plain state line.
struct CalibrationView: View {
    let coordinator: AppCoordinator

    @State private var statuses: [Permission: PermissionStatus] = [:]

    var body: some View {
        Form {
            Section("Permissions") {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(
                        permission: permission,
                        status: statuses[permission] ?? .notDetermined,
                        request: coordinator.canRequest(permission) ? { coordinator.request(permission) } : nil
                    )
                }
                if !coordinator.isReanchorHotkeyAvailable {
                    Label("Re-anchor hotkey unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let notice = coordinator.captureAvailability.notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Head tracking") {
                LabeledContent("Wear state", value: describe(coordinator.wearState))
                LivePose(coordinator: coordinator)
                LabeledContent("Gaze", value: describe(coordinator.gazeState))
            }

            Section("Displays") {
                ForEach(coordinator.displays) { display in
                    LabeledContent(display.name, value: anchorDescription(for: display.id))
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
        .preferredColorScheme(.dark)
        .task { await pollPermissions() }
    }

    /// TCC sends no change notifications, so a grant made in System Settings only shows up if
    /// the window asks again. The loop lives for as long as the window does: `WindowController`
    /// drops a closed window, which tears this view down and cancels the task.
    private func pollPermissions() async {
        while !Task.isCancelled {
            coordinator.permissions.refresh()
            statuses = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, coordinator.permissions.status(of: $0)) })
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func describe(_ wearState: WearState) -> String {
        switch wearState {
        case .worn: "Worn"
        case .unknown(.noHeadphonesConnected): "No headphones connected"
        case .unknown(.sampleGap): "Sample gap"
        case .unknown(.motionUnavailable): "Motion unavailable"
        case .unknown(.permissionDenied): "Permission denied"
        }
    }

    private func describe(_ gazeState: GazeState) -> String {
        switch gazeState {
        case .looking(let id): "Looking at \(id)"
        case .away: "Away"
        case .unknown: "Unknown"
        }
    }

    private func anchorDescription(for id: DisplayID) -> String {
        guard let anchor = coordinator.gaze.anchors[id] else { return "Not anchored" }
        let source = anchor.source == .hotkey ? "hotkey" : "input"
        return "Anchored (\(source))"
    }
}

/// The only rows that change while the head moves, kept apart from the rest of the form so a
/// new pose invalidates two labels rather than every control in the window.
private struct LivePose: View {
    let coordinator: AppCoordinator

    var body: some View {
        let pose = coordinator.displayPose
        LabeledContent("Yaw", value: pose?.yaw.description ?? "—")
        LabeledContent("Pitch", value: pose?.pitch.description ?? "—")
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let status: PermissionStatus
    /// `nil` when there is nothing left to ask: already granted, or only answerable by starting
    /// a sensor the run gate currently owns.
    let request: (() -> Void)?

    var body: some View {
        LabeledContent {
            HStack {
                Text(statusText)
                if let request {
                    Button("Grant…", action: request)
                }
            }
        } label: {
            VStack(alignment: .leading) {
                Text(permission.title)
                Text(permission.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        switch status {
        case .granted: "Granted"
        case .denied: "Denied"
        case .notDetermined: "Not determined"
        case .unavailable: "Unavailable"
        }
    }
}
