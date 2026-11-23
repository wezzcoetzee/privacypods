import Testing

@testable import PrivacyPods

@Suite("Capture availability")
struct CaptureAvailabilityTests {
    @Test("A missing permission outranks a failed stream")
    func permissionWins() {
        let combined = BlurOverlayController.combined([
            .unavailable(.captureFailed),
            .available,
            .unavailable(.screenRecordingDenied),
        ])
        #expect(combined == .unavailable(.screenRecordingDenied))
    }

    @Test("One failed display is enough to report a failure")
    func oneFailureIsEnough() {
        let combined = BlurOverlayController.combined([.available, .unavailable(.captureFailed)])
        #expect(combined == .unavailable(.captureFailed))
    }
}
