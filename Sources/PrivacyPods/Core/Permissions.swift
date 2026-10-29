import Foundation

/// A TCC permission the app needs. Listed in the calibration view in the order it is declared.
enum Permission: String, Hashable, Sendable, CaseIterable, Identifiable {
    case motion
    case screenRecording
    case inputMonitoring

    var id: Self { self }

    var title: String {
        switch self {
        case .motion: "Motion"
        case .screenRecording: "Screen Recording"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    var rationale: String {
        switch self {
        case .motion:
            "Reads AirPods head orientation. Without it there is no gaze tracking at all."
        case .screenRecording:
            "Captures each display so the overlay can blur what is actually on screen."
        case .inputMonitoring:
            "Notices typing and pointer movement so anchors set themselves. Without it, anchoring is hotkey-only."
        }
    }

    /// The System Settings pane to open when the permission cannot be prompted for in-process.
    var settingsURL: URL {
        let anchor = switch self {
        case .motion: "Privacy_Motion"
        case .screenRecording: "Privacy_ScreenCapture"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

enum PermissionStatus: Hashable, Sendable {
    case granted
    case denied
    case notDetermined
    /// Cannot apply on this machine, e.g. no headphones with a gyro have ever been connected.
    case unavailable
}
