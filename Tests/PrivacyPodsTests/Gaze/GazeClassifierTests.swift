import Foundation
import Testing
@testable import PrivacyPods

/// A classifier plus the clock its sample timestamps are measured against. Samples move the
/// clock with them, so head data is live unless a test deliberately lets it go stale.
@MainActor
private final class Session {
    static let start = Date(timeIntervalSince1970: 1_000_000)

    let classifier: GazeClassifier
    private let clock = ManualTimeSource(Session.start)
    private var elapsed: TimeInterval = 0

    init(cone: AcceptanceCone = .default, awayGrace: TimeInterval = 0.7) {
        classifier = GazeClassifier(cone: cone, awayGrace: awayGrace, time: clock)
    }

    var state: GazeState { classifier.state }
    var anchors: [DisplayID: DisplayAnchor] { classifier.anchors }
    var events: AsyncStream<GazeState> { classifier.events }

    /// Delivers a sample `offset` seconds into the session. Offsets only ever move forwards.
    func sample(yaw: Double = 0, pitch: Double = 0, at offset: TimeInterval) {
        advance(by: offset - elapsed)
        classifier.ingest(.sample(MotionSample(
            pose: HeadPose(yaw: Degrees(yaw), pitch: Degrees(pitch)),
            userAcceleration: .zero,
            timestamp: Session.start.addingTimeInterval(offset)
        )))
    }

    /// Time passing with no sample, which is what a silent stream looks like before the head
    /// tracker's watchdog has called it a gap.
    func advance(by interval: TimeInterval) {
        clock.advance(by: interval)
        elapsed += interval
    }

    func wear(_ state: WearState) {
        classifier.ingest(.wearState(state))
    }

    func anchor(_ display: DisplayID, source: DisplayAnchor.Source) {
        classifier.anchor(display, source: source)
    }

    func retainOnly(_ displays: Set<DisplayID>) {
        classifier.retainOnly(displays)
    }
}

@MainActor
struct GazeClassifierTests {
    private let a = DisplayID(1)
    private let b = DisplayID(2)

    @Test func looksAtTheAnchoredDisplayTheHeadIsPointedAt() {
        let gaze = Session()
        gaze.sample(at: 0)
        gaze.anchor(a, source: .sustainedInput)
        #expect(gaze.state == .looking(a))

        gaze.sample(yaw: 40, at: 1)
        gaze.anchor(b, source: .sustainedInput)
        #expect(gaze.state == .looking(b))

        gaze.sample(yaw: 5, at: 2)
        #expect(gaze.state == .looking(a))
    }

    @Test func picksTheNearerConeRatherThanTheSmallerAngle() {
        let gaze = Session(cone: AcceptanceCone(yawHalfAngle: 30, pitchHalfAngle: 10))
        gaze.sample(at: 0)
        gaze.anchor(a, source: .sustainedInput)
        gaze.sample(yaw: 12, pitch: 6, at: 1)
        gaze.anchor(b, source: .sustainedInput)

        // 12 degrees of yaw from a is 0.4 of a's cone; 6 degrees of pitch from b is 0.6 of b's.
        // Comparing raw degrees would pick b.
        gaze.sample(yaw: 12, at: 2)
        #expect(gaze.state == .looking(a))
    }

    @Test func holdsTheLastDisplayUntilTheGraceWindowExpires() {
        let gaze = Session(awayGrace: 0.7)
        gaze.sample(at: 0)
        gaze.anchor(a, source: .sustainedInput)

        gaze.sample(yaw: 90, at: 1)
        #expect(gaze.state == .looking(a))
        gaze.sample(yaw: 90, at: 1.5)
        #expect(gaze.state == .looking(a))
        gaze.sample(yaw: 90, at: 1.7)
        #expect(gaze.state == .away)
    }

    @Test func aGlanceBackRestartsTheGraceWindow() {
        let gaze = Session(awayGrace: 0.7)
        gaze.sample(at: 0)
        gaze.anchor(a, source: .sustainedInput)

        gaze.sample(yaw: 90, at: 1)
        gaze.sample(at: 1.5)
        #expect(gaze.state == .looking(a))

        gaze.sample(yaw: 90, at: 2)
        gaze.sample(yaw: 90, at: 2.6)
        #expect(gaze.state == .looking(a))
        gaze.sample(yaw: 90, at: 2.8)
        #expect(gaze.state == .away)
    }

    @Test func comingBackToADisplayIsImmediate() {
        let gaze = Session(awayGrace: 0.7)
        gaze.sample(at: 0)
        gaze.anchor(a, source: .sustainedInput)
        gaze.sample(yaw: 90, at: 1)
        gaze.sample(yaw: 90, at: 2)
        #expect(gaze.state == .away)

        gaze.sample(at: 2.01)
        #expect(gaze.state == .looking(a))
    }

    @Test func aSampleGapIsUnknownAndNeverAway() {
        let gaze = Session(awayGrace: 0.7)
        gaze.sample(at: 0)
        gaze.anchor(a, source: .sustainedInput)

        gaze.wear(.unknown(.sampleGap))
        #expect(gaze.state == .unknown)
        #expect(gaze.anchors[a] != nil)

        // The gap does not count towards the grace window: it restarts on the next sample.
        gaze.sample(yaw: 90, at: 10)
        #expect(gaze.state == .unknown)
        gaze.sample(yaw: 90, at: 10.8)
        #expect(gaze.state == .away)
    }

    @Test func losingTheHeadphonesDropsTheAnchors() {
        let gaze = Session()
        gaze.sample(at: 0)
        gaze.anchor(a, source: .sustainedInput)

        gaze.wear(.unknown(.noHeadphonesConnected))
        #expect(gaze.anchors.isEmpty)
        #expect(gaze.state == .unknown)
    }

    @Test func withoutAnchorsThereIsNothingToJudge() {
        let gaze = Session(awayGrace: 0.7)
        gaze.sample(at: 0)
        gaze.sample(at: 5)
        #expect(gaze.state == .unknown)
    }

    @Test func anchoringNeedsLiveHeadData() {
        let gaze = Session()
        gaze.anchor(a, source: .hotkey)
        #expect(gaze.anchors.isEmpty)
    }

    /// The watchdog takes up to ~1.75 s to call a silent stream a gap, so between those two
    /// moments the newest pose is stale rather than absent. Anchoring to it would record where
    /// the head was, not where it is.
    @Test func anchoringRefusesAStaleSampleBeforeTheWatchdogNoticesTheGap() {
        let gaze = Session()
        gaze.sample(at: 0)
        gaze.advance(by: 1)
        gaze.anchor(a, source: .hotkey)
        #expect(gaze.anchors.isEmpty)

        gaze.sample(at: 1.1)
        gaze.anchor(a, source: .hotkey)
        #expect(gaze.anchors[a]?.pose.yaw == Degrees(0))
    }

    @Test func aHotkeyAnchorOutranksItsOwnKeystrokesButNotLaterTyping() {
        let gaze = Session()
        gaze.sample(at: 0)
        gaze.anchor(a, source: .hotkey)
        gaze.anchor(a, source: .sustainedInput)
        #expect(gaze.anchors[a]?.source == .hotkey)

        gaze.sample(yaw: 3, at: 1)
        gaze.anchor(a, source: .sustainedInput)
        #expect(gaze.anchors[a]?.source == .sustainedInput)
        #expect(gaze.anchors[a]?.pose.yaw == Degrees(3))
    }

    @Test func disconnectedDisplaysLoseTheirAnchors() {
        let gaze = Session()
        gaze.sample(at: 0)
        gaze.anchor(a, source: .sustainedInput)
        gaze.sample(yaw: 40, at: 1)
        gaze.anchor(b, source: .sustainedInput)
        #expect(gaze.state == .looking(b))

        gaze.retainOnly([a])
        #expect(Set(gaze.anchors.keys) == [a])
        #expect(gaze.state == .unknown)
    }

    @Test func eventsReportChangesOnly() async {
        let gaze = Session(awayGrace: 0)
        var events = gaze.events.makeAsyncIterator()

        gaze.sample(at: 0)
        gaze.anchor(a, source: .sustainedInput)
        gaze.sample(at: 0.1)
        gaze.sample(yaw: 90, at: 0.2)

        #expect(await events.next() == .looking(a))
        #expect(await events.next() == .away)
    }
}
