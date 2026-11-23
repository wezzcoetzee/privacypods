import CoreGraphics

/// `CGPreflightScreenCaptureAccess` cannot tell "denied" from "never asked", so the status is
/// binary. After a denial `request()` answers immediately without a prompt.
enum ScreenRecordingPermission {
    static var status: PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
