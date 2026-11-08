import Foundation

/// A TCC permission the app needs. Listed in the Status window in the order it is declared.
enum Permission: String, Hashable, Sendable, CaseIterable, Identifiable {
    case motion
    case screenRecording
    case inputMonitoring
    /// Asked by macOS the first time the proximity monitor lists paired devices.
    case bluetooth

    var id: Self { self }

    var title: String {
        switch self {
        case .motion: "Motion"
        case .screenRecording: "Screen Recording"
        case .inputMonitoring: "Input Monitoring"
        case .bluetooth: "Bluetooth"
        }
    }

    var rationale: String {
        switch self {
        case .motion:
            "Reads AirPods head orientation. Without it there is no gaze tracking at all."
        case .screenRecording:
            "Captures each display so the overlay can blur what is actually on screen. System Settings lists it as Screen & System Audio Recording."
        case .inputMonitoring:
            "Notices typing, so anchors set themselves and typing counts as being here. Without it, only the pointer and the shortcut do, and you can be locked while typing with the AirPods out."
        case .bluetooth:
            "Checks how far away the AirPods are, to back up walk-away detection. Without it, walking away is judged from head motion and input alone."
        }
    }

    /// The System Settings pane to open when the permission cannot be prompted for in-process.
    var settingsURL: URL {
        let anchor = switch self {
        case .motion: "Privacy_Motion"
        case .screenRecording: "Privacy_ScreenCapture"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .bluetooth: "Privacy_Bluetooth"
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
