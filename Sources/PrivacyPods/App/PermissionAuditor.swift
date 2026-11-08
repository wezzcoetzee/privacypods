import AppKit
import CoreBluetooth
import IOKit.hid

/// The `PermissionAuditing` implementation, and the only place the app reports on permissions.
///
/// It owns no TCC call of its own: Motion belongs to `HeadTracking` and Screen Recording to
/// `Overlay`, so both are read through those modules. Motion is also the one permission whose
/// request has a side effect on a sensor, which is why `AppCoordinator.request(_:)` is what the
/// UI calls: it keeps the probe from running while the tracker is already started. Input Monitoring has no owning module
/// because nothing degrades gracefully enough to need one, so it is read straight from IOKit,
/// which (unlike `CGPreflightListenEventAccess`) can tell "denied" from "never asked".
@MainActor
final class PermissionAuditor: PermissionAuditing {
    private let motion: HeadphoneMotionTracker
    /// Screen Recording's preflight call cannot distinguish "denied" from "never asked"; once
    /// we have asked, a continued `false` means denied rather than not-yet-determined.
    private var hasRequestedScreenRecording: Bool
    private var cachedStatuses: [Permission: PermissionStatus] = [:]
    /// Held only so the Bluetooth prompt stays up until it is answered.
    private var bluetoothProbe: CBCentralManager?

    init(motion: HeadphoneMotionTracker) {
        self.motion = motion
        hasRequestedScreenRecording = UserDefaults.standard.bool(forKey: Self.screenRecordingRequestedKey)
        refresh()
    }

    func status(of permission: Permission) -> PermissionStatus {
        cachedStatuses[permission] ?? currentStatus(of: permission)
    }

    func request(_ permission: Permission) {
        switch permission {
        case .motion:
            // CoreMotion has no request call: the prompt fires on the first sample
            // subscription, so asking means probing the stream, and the probe answers
            // asynchronously. Once TCC has answered there is nothing left to prompt and the
            // System Settings pane is the only way back.
            switch status(of: .motion) {
            case .notDetermined:
                probeMotion()
                return
            case .granted:
                break
            case .denied, .unavailable:
                NSWorkspace.shared.open(permission.settingsURL)
            }
        // Both requests return `false` on the first call while their prompt is still on screen,
        // so System Settings only opens once the user has already been asked and said no.
        case .screenRecording:
            let wasAsked = hasRequestedScreenRecording
            hasRequestedScreenRecording = true
            UserDefaults.standard.set(true, forKey: Self.screenRecordingRequestedKey)
            if !ScreenRecordingPermission.request(), wasAsked {
                NSWorkspace.shared.open(permission.settingsURL)
            }
        case .inputMonitoring:
            let wasDenied = status(of: .inputMonitoring) == .denied
            if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent), wasDenied {
                NSWorkspace.shared.open(permission.settingsURL)
            }
        case .bluetooth:
            // Bluetooth has no request call either: creating a manager raises the prompt once.
            if status(of: .bluetooth) == .notDetermined {
                bluetoothProbe = CBCentralManager()
            } else {
                NSWorkspace.shared.open(permission.settingsURL)
            }
        }
        refresh()
    }

    /// The Motion probe opens the motion stream just long enough for TCC to answer and closes
    /// it again, so it is the one status the auditor learns rather than reads, and it lands
    /// after `request` has returned.
    private func probeMotion() {
        Task { [weak self] in
            guard let self else { return }
            cachedStatuses[.motion] = await motion.requestAuthorization()
        }
    }

    func refresh() {
        for permission in Permission.allCases {
            cachedStatuses[permission] = currentStatus(of: permission)
        }
    }

    private func currentStatus(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .motion:
            HeadphoneMotionTracker.authorizationStatus
        case .screenRecording:
            if ScreenRecordingPermission.status == .granted {
                .granted
            } else if hasRequestedScreenRecording {
                .denied
            } else {
                .notDetermined
            }
        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: .granted
            case kIOHIDAccessTypeDenied: .denied
            default: .notDetermined
            }
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: .granted
            case .denied, .restricted: .denied
            case .notDetermined: .notDetermined
            @unknown default: .unavailable
            }
        }
    }

    private static let screenRecordingRequestedKey = "dev.wesley.privacypods.screenRecordingRequested"
}
