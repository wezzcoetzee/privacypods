import Foundation
import Testing
@testable import PrivacyPods

@Suite("Away evidence")
struct AwayEvidenceTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let grace = AwayEvidence.Configuration.default.disconnectIdleGrace

    private func worn(walking: Bool = false, gaze: GazeState = .looking(DisplayID(1))) -> AwayEvidence {
        var evidence = AwayEvidence()
        evidence.observe(wear: .worn, at: start)
        evidence.observe(gaze: gaze)
        evidence.isWalking = walking
        return evidence
    }

    @Test("Walking away needs corroboration")
    func walkingAloneIsNotAway() {
        var pacing = worn(walking: true)
        #expect(pacing.resolve(at: start) == .present)

        var leaving = worn(walking: true, gaze: .away)
        #expect(leaving.resolve(at: start) == .away(since: start))

        var fading = worn(walking: true)
        fading.proximity = .falling
        #expect(fading.resolve(at: start) == .away(since: start))
    }

    @Test("A sensor gap is never an absence")
    func gapsResolveToUnknown() {
        var evidence = worn()
        evidence.observeInput(at: start)
        evidence.observe(wear: .unknown(.sampleGap), at: start)

        #expect(evidence.resolve(at: start) == .present)
        #expect(evidence.resolve(at: start + grace) == .unknown)
        #expect(evidence.resolve(at: start + 3600) == .unknown)
    }

    @Test("A disconnect with no input since becomes away")
    func disconnectWithoutInput() {
        var evidence = worn()
        evidence.observe(wear: .unknown(.noHeadphonesConnected), at: start)

        #expect(evidence.resolve(at: start + grace - 1) == .unknown)
        #expect(evidence.resolve(at: start + grace) == .away(since: start + grace))
    }

    @Test("Typing restarts the disconnect clock rather than erasing it")
    func inputRestartsTheDisconnectClock() {
        var evidence = worn()
        evidence.observe(wear: .unknown(.noHeadphonesConnected), at: start)
        evidence.observeInput(at: start + 5)

        #expect(evidence.resolve(at: start + grace) == .present)
        // The AirPods are still gone, so the silence after that keystroke counts again.
        let deadline = start + 5 + grace
        #expect(evidence.resolve(at: deadline) == .away(since: deadline))
    }

    @Test("Only a disconnect that interrupts recent wear is evidence")
    func staleWearIsNotEvidence() {
        let window = AwayEvidence.Configuration.default.recentWearWindow

        // They take the AirPods off and leave them on the desk; the app only sees silence.
        // The battery dies well after that, and nobody walked anywhere.
        var stale = worn()
        stale.observe(wear: .unknown(.sampleGap), at: start)
        let flat = start + window + 1
        stale.observe(wear: .unknown(.noHeadphonesConnected), at: flat)
        #expect(stale.resolve(at: flat + grace) == .unknown)
        #expect(stale.resolve(at: flat + 3600) == .unknown)

        // The same disconnect a moment before the window closes still counts.
        var recent = worn()
        recent.observe(wear: .unknown(.sampleGap), at: start)
        let soon = start + window - 1
        recent.observe(wear: .unknown(.noHeadphonesConnected), at: soon)
        #expect(recent.resolve(at: soon + grace) == .away(since: soon + grace))
    }

    @Test("Away sticks until the user comes back")
    func awayIsLatchedUntilReturn() {
        var evidence = worn(walking: true, gaze: .away)
        #expect(evidence.resolve(at: start) == .away(since: start))

        // The gait detector goes quiet the moment they stop walking; they are still not here.
        evidence.isWalking = false
        #expect(evidence.resolve(at: start + 60) == .away(since: start))

        evidence.observe(gaze: .looking(DisplayID(1)))
        #expect(evidence.resolve(at: start + 61) == .present)
    }

    @Test("Input clears away immediately, and holds only as long as it is evidence")
    func inputClearsAway() {
        let window = AwayEvidence.Configuration.default.inputPresenceWindow
        var evidence = worn(walking: true, gaze: .away)
        #expect(evidence.resolve(at: start).isAway)

        // Typing beats the accelerometer even though the walking evidence is still standing.
        evidence.observeInput(at: start + 2)
        #expect(evidence.resolve(at: start + 2) == .present)

        // Once the keystroke is stale the sensors get to argue again.
        let resumed = start + 2 + window
        #expect(evidence.resolve(at: resumed) == .away(since: resumed))
    }
}
