import Foundation
import Testing
@testable import PrivacyPods

/// The gates the coordinator puts above `BlurMode.displaysToBlur`. The mode matrix itself is
/// covered in `CoreTests`; what matters here is that the gates cannot be argued with.
@Suite("Blur gates")
struct BlurGateTests {
    private let left = DisplayID(1)
    private let right = DisplayID(2)
    private var all: Set<DisplayID> { [left, right] }

    @Test("A locked screen and a disabled app are never blurred")
    func gatesBeatEverything() {
        var settings = AppSettings()

        #expect(AppCoordinator.blurredDisplays(
            settings: settings, gaze: .away, allDisplays: all, awayResponse: .lock, isLocked: true
        ).isEmpty)

        settings.isEnabled = false
        #expect(AppCoordinator.blurredDisplays(
            settings: settings, gaze: .away, allDisplays: all, awayResponse: .blur, isLocked: false
        ).isEmpty)
    }

    @Test("An away escalation covers every display whatever the blur mode says")
    func awayEscalationOverridesTheMode() {
        var settings = AppSettings()
        settings.blurMode = .unfocusedDisplays

        #expect(AppCoordinator.blurredDisplays(
            settings: settings, gaze: .looking(left), allDisplays: all, awayResponse: .blur, isLocked: false
        ) == all)

        settings.blurMode = .off
        #expect(AppCoordinator.blurredDisplays(
            settings: settings, gaze: .looking(left), allDisplays: all, awayResponse: .lock, isLocked: false
        ) == all)
    }

    @Test("The status line reports the gates before the sensors")
    func statusLinePrefersTheCoarsestTruth() {
        let away = Date(timeIntervalSince1970: 1_000_000)

        #expect(line(isEnabled: false, presence: .present) == "Disabled")
        #expect(line(presence: .away(since: away)) == "Away")
        #expect(line(wear: .unknown(.sampleGap), gaze: .unknown, presence: .unknown) == "No head data")
        #expect(line(presence: .present) == "Looking at: Built-in Display")
    }

    @Test("A lock that did not take effect outranks the away line that asked for it")
    func aFailedLockIsTheHeadline() {
        let away = Date(timeIntervalSince1970: 1_000_000)

        #expect(line(presence: .away(since: away), didFailToLock: true) == "Could not lock the screen")
        // Disabled still wins: the escalation that failed belongs to a session that is over.
        #expect(line(isEnabled: false, presence: .away(since: away), didFailToLock: true) == "Disabled")
    }

    @Test("Every unknown wear reason gets its own line")
    func unknownWearReasonsAreDistinct() {
        let reasons: [WearState.Reason] = [.noHeadphonesConnected, .sampleGap, .motionUnavailable, .permissionDenied]
        let lines = reasons.map { line(wear: .unknown($0), gaze: .unknown, presence: .present) }

        #expect(Set(lines).count == reasons.count)
    }

    private func line(
        isEnabled: Bool = true,
        wear: WearState = .worn,
        gaze: GazeState = .looking(DisplayID(1)),
        presence: PresenceState,
        didFailToLock: Bool = false
    ) -> String {
        AppCoordinator.statusLine(
            isEnabled: isEnabled,
            wearState: wear,
            gazeState: gaze,
            presenceState: presence,
            didFailToLock: didFailToLock,
            displayName: { _ in "Built-in Display" }
        )
    }
}
