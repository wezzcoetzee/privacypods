import Testing
@testable import PrivacyPods

/// The overlay's only pure logic: what several displays' capture states add up to, and what the
/// sheet prints for each of them.
@Suite("Capture availability")
struct CaptureAvailabilityTests {
    @Test("Nothing to report means available")
    func emptyIsAvailable() {
        let none = BlurOverlayController.combined([CaptureAvailability]())
        let allFine = BlurOverlayController.combined([.available, .available])
        #expect(none == .available)
        #expect(allFine == .available)
    }

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

    @Test("Only an unavailable capture has something to say")
    func noticeExistsOnlyWhenBlind() {
        #expect(CaptureAvailability.available.notice == nil)
        #expect(CaptureAvailability.unavailable(.screenRecordingDenied).notice != nil)
        #expect(CaptureAvailability.unavailable(.captureFailed).notice != nil)
    }
}
