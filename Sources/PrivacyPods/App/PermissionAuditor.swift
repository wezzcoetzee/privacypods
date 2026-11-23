import AppKit
import CoreBluetooth
import IOKit.hid

/// Input Monitoring is read from IOKit because `CGPreflightListenEventAccess` cannot tell denied from never asked.
@MainActor
final class PermissionAuditor: PermissionAuditing {
    private let motion: HeadphoneMotionTracker
    /// Screen Recording preflight cannot tell denied from never asked; once asked, a continued `false` means denied.
    private var hasRequestedScreenRecording: Bool
    private var cachedStatuses: [Permission: PermissionStatus] = [:]
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
            // CoreMotion has no request call: the prompt fires on the first sample subscription, so asking means probing the stream.
            switch status(of: .motion) {
            case .notDetermined:
                probeMotion()
                return
            case .granted:
                break
            case .denied, .unavailable:
                NSWorkspace.shared.open(permission.settingsURL)
            }
        // Both requests return `false` while their prompt is on screen, so System Settings opens only after the user has been asked.
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

    /// The Motion probe answers asynchronously, after `request` has returned.
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
