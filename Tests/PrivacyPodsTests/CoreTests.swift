import Foundation
import Testing
@testable import PrivacyPods

@Suite("Core value types")
struct CoreTests {
    private let left = DisplayID(1)
    private let right = DisplayID(2)

    @Test("Blur mode resolves which displays to cover")
    func blurModeResolution() {
        let all: Set<DisplayID> = [left, right]

        #expect(BlurMode.off.displaysToBlur(gaze: .away, allDisplays: all, failMode: .closed).isEmpty)
        #expect(BlurMode.whenLookingAway.displaysToBlur(gaze: .looking(left), allDisplays: all, failMode: .open).isEmpty)
        #expect(BlurMode.whenLookingAway.displaysToBlur(gaze: .away, allDisplays: all, failMode: .open) == all)
        #expect(BlurMode.unfocusedDisplays.displaysToBlur(gaze: .looking(left), allDisplays: all, failMode: .open) == [right])
        #expect(BlurMode.unfocusedDisplays.displaysToBlur(gaze: .away, allDisplays: all, failMode: .open) == all)
    }

    @Test("A sensor gap blurs only in fail-closed mode")
    func failModeGovernsSensorGaps() {
        let all: Set<DisplayID> = [left, right]

        #expect(BlurMode.whenLookingAway.displaysToBlur(gaze: .unknown, allDisplays: all, failMode: .open).isEmpty)
        #expect(BlurMode.whenLookingAway.displaysToBlur(gaze: .unknown, allDisplays: all, failMode: .closed) == all)
        #expect(BlurMode.unfocusedDisplays.displaysToBlur(gaze: .unknown, allDisplays: all, failMode: .closed) == all)
    }

    @Test("Away policy escalates idle to blur to lock")
    func awayPolicyEscalation() {
        let policy = AwayPolicy.blurThenLock(blurAfter: 5, lockAfter: 30)

        #expect(policy.response(awayFor: 0) == .idle)
        #expect(policy.response(awayFor: 5) == .blur)
        #expect(policy.response(awayFor: 29.9) == .blur)
        #expect(policy.response(awayFor: 30) == .lock)
        #expect(AwayPolicy.doNothing.response(awayFor: 3600) == .idle)
        #expect(AwayPolicy.lockImmediately.response(awayFor: 0) == .lock)
    }

    @Test("Yaw offsets take the short way round the wrap point")
    func yawWrapping() {
        let anchor = HeadPose(yaw: 175, pitch: 0)
        let turned = HeadPose(yaw: -175, pitch: 0)

        #expect(turned.offset(from: anchor).yaw.value == 10)
        #expect(AcceptanceCone.default.contains(turned.offset(from: anchor)))
    }

    @Test("Settings survive a key being added later")
    func settingsDecodeTolerantly() throws {
        let stored = Data(#"{"blurRadius": 42}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: stored)

        #expect(decoded.blurRadius == 42)
        #expect(decoded.blurMode == .whenLookingAway)
        #expect(decoded.awayPolicy == .default)
    }

    @Test("Manual time source steps on demand")
    func manualTimeSourceAdvances() {
        let clock = ManualTimeSource()
        let start = clock.now
        clock.advance(by: 90)

        #expect(clock.now.timeIntervalSince(start) == 90)
    }
}
