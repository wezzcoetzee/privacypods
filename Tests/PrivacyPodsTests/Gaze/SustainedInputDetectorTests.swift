import Foundation
import Testing
@testable import PrivacyPods

@Suite("Sustained input")
struct SustainedInputDetectorTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// Feeds `events` at their offsets and reports the offsets that completed a burst.
    private func burstOffsets(_ events: [(SustainedInputDetector.Kind, TimeInterval)]) -> [TimeInterval] {
        var detector = SustainedInputDetector()
        return events.filter { detector.record($0.0, at: start + $0.1) }.map(\.1)
    }

    @Test func threeKeystrokesInsideTheWindowAreTyping() {
        #expect(burstOffsets([(.key, 0), (.key, 0.2)]).isEmpty)
        #expect(burstOffsets([(.key, 0), (.key, 0.2), (.key, 0.4)]) == [0.4])
    }

    @Test func keystrokesOlderThanTheWindowStopCounting() {
        #expect(burstOffsets([(.key, 0), (.key, 0.5), (.key, 1.6)]).isEmpty)
    }

    @Test func aBurstClearsTheWindowSoTheNextOneEarnsItsOwn() {
        let typing: [(SustainedInputDetector.Kind, TimeInterval)] =
            [(.key, 0), (.key, 0.1), (.key, 0.2), (.key, 0.3), (.key, 0.4), (.key, 0.5)]
        #expect(burstOffsets(typing) == [0.2, 0.5])
    }

    @Test func pointerMotionHasToFillPartOfTheWindow() {
        // Gaps of 0.08 s read as one continuous movement, so three of them is 0.24 s of
        // motion, under the bar, and the fourth carries it over.
        let drag: [(SustainedInputDetector.Kind, TimeInterval)] =
            [(.pointer, 0), (.pointer, 0.08), (.pointer, 0.16), (.pointer, 0.24), (.pointer, 0.32)]
        #expect(burstOffsets(drag) == [0.32])
    }

    @Test func aSingleKnockIsNotMotion() {
        #expect(burstOffsets([(.pointer, 0), (.pointer, 0.5)]).isEmpty)
    }

    @Test func theIdleTimeBetweenNudgesIsNotMotion() {
        // Three nudges spanning most of the window, but the pointer only moved for the 0.08 s
        // of each: measuring the span instead would call this sustained.
        let nudges: [(SustainedInputDetector.Kind, TimeInterval)] =
            [(.pointer, 0), (.pointer, 0.08), (.pointer, 0.4),
             (.pointer, 0.48), (.pointer, 0.8), (.pointer, 0.88)]
        #expect(burstOffsets(nudges).isEmpty)
    }
}
