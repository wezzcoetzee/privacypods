import CoreGraphics

/// Screen Recording is the only permission the overlay needs. Without it `SCShareableContent`
/// throws and no frames arrive, so a blurred display is covered by dark glass carrying
/// `CaptureAvailability.unavailable(.screenRecordingDenied)`'s notice instead of a blurred picture
/// of itself. The screen is still hidden; it is just hidden blind.
///
/// `CGPreflightScreenCaptureAccess` cannot distinguish "denied" from "never asked", so the status
/// is binary. `request()` is what turns the undetermined case into a system prompt; after a denial
/// macOS answers immediately and the caller should send the user to `Permission.screenRecording`'s
/// `settingsURL`.
enum ScreenRecordingPermission {
    static var status: PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Prompts, and reports the status macOS holds at the moment the prompt is dismissed.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
