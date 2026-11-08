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

    @Test("The status reports the gates before the sensors")
    func statusPrefersTheCoarsestTruth() {
        let away = Date(timeIntervalSince1970: 1_000_000)

        #expect(status(isEnabled: false, presence: .present) == .paused(until: nil))
        #expect(status(presence: .away(since: away)) == .away)
        #expect(status(wear: .unknown(.sampleGap), gaze: .unknown, presence: .unknown)
            == .headTracking(.sampleGap, coversScreens: false))
        #expect(status(gaze: .unknown, presence: .present) == .notAnchored(coversScreens: false))
        #expect(status(presence: .present) == .looking(display: "Built-in Display"))
    }

    @Test("Being away is only the headline when something happens about it")
    func awayNeedsAResponse() {
        var settings = AppSettings()
        settings.awayPolicy = .doNothing
        #expect(status(presence: .away(since: Date()), settings: settings) == .looking(display: "Built-in Display"))
    }

    @Test("Turning off both blur and lock is reported as protection off, whatever the sensors say")
    func bothOffIsNotProtecting() {
        var settings = AppSettings()
        settings.blurMode = .off
        settings.awayPolicy = .doNothing
        let off = status(presence: .present, settings: settings)
        #expect(off == .protectionOff)
        #expect(StatusIcon(status: off, issues: [], coversView: false).isDimmed)
    }

    @Test("A lock that did not take effect outranks the away line that asked for it")
    func aFailedLockIsTheHeadline() {
        let away = Date(timeIntervalSince1970: 1_000_000)

        #expect(status(presence: .away(since: away), didFailToLock: true) == .lockFailed)
        // Paused still wins: the escalation that failed belongs to a session that is over.
        #expect(status(isEnabled: false, presence: .away(since: away), didFailToLock: true) == .paused(until: nil))
    }

    @Test("A sensor gap says whether anything is still being protected")
    func sensorGapsSayWhatTheyCost() {
        var closed = AppSettings()
        closed.failMode = .closed
        let open = status(wear: .unknown(.noHeadphonesConnected), gaze: .unknown, presence: .unknown)
        let covered = status(wear: .unknown(.noHeadphonesConnected), gaze: .unknown, presence: .unknown, settings: closed)

        #expect(open.title.contains("screens readable"))
        #expect(open.health == .inactive)
        #expect(covered.title.contains("screens blurred"))
        #expect(covered.health == .protecting)
    }

    @Test("The icon tells chosen-off, can't-see, covering and broken apart")
    func iconTellsTheTruth() {
        let looking = AppStatus.looking(display: "DELL")
        let noAirPods = AppStatus.headTracking(.noHeadphonesConnected, coversScreens: false)
        func icon(_ status: AppStatus, _ issues: [PrivacyPods.Issue] = [], covers: Bool = false) -> StatusIcon {
            StatusIcon(status: status, issues: issues, coversView: covers)
        }

        #expect(icon(.lockFailed, covers: true).symbolName == "eye.trianglebadge.exclamationmark")
        #expect(icon(looking, [.hotkeyTaken("⌃⌥⌘R")]).symbolName == "eye.trianglebadge.exclamationmark")
        // Degrading permissions and setup steps are listed but do not badge.
        #expect(icon(looking, [.permission(.inputMonitoring), .permission(.screenRecording), .lockUntested]).symbolName == "eye")
        #expect(icon(.lookingAway(unanchoredDisplay: false), covers: true).symbolName == "eye.slash")
        #expect(icon(noAirPods).symbolName == "eye.half.closed")
        // Dimming is kept for what the user switched off, so a dim icon always means "you chose this".
        #expect(icon(.paused(until: nil)).isDimmed)
        #expect(icon(.paused(until: nil)).symbolName != icon(noAirPods).symbolName)
        #expect(!icon(noAirPods).isDimmed)
    }

    @Test("Every status reads differently")
    func statusesAreDistinct() {
        let statuses: [AppStatus] = [
            .paused(until: nil), .protectionOff, .lockFailed, .away,
            .headTracking(.noHeadphonesConnected, coversScreens: false), .headTracking(.sampleGap, coversScreens: false),
            .headTracking(.permissionDenied, coversScreens: false),
            .notAnchored(coversScreens: false), .looking(display: "DELL"),
            .lookingAway(unanchoredDisplay: false), .lookingAway(unanchoredDisplay: true),
        ]
        #expect(Set(statuses.map(\.title)).count == statuses.count)
    }

    @Test("Issues list what the user can fix, and leave an unasked Motion to the tracker")
    func issuesNameWhatToFix() {
        let statuses: [Permission: PermissionStatus] = [
            .motion: .notDetermined, .screenRecording: .notDetermined, .inputMonitoring: .denied, .bluetooth: .notDetermined,
        ]
        let failedAt = Date(timeIntervalSince1970: 1_000_000)
        let issues = Issue.current(
            lockFailedAt: failedAt,
            lockUntested: true,
            permissions: { statuses[$0]! },
            capture: .unavailable(.captureFailed),
            isCovering: false,
            isHotkeyAvailable: false,
            hotkey: .reanchorDefault
        )
        // While Motion is unasked, first run asks for nothing optional. A declined Input Monitoring
        // is the user's answer, and an unasked Bluetooth is asked by macOS itself. A failed lock
        // replaces the "untested" step.
        #expect(issues == [.lockFailed(at: failedAt), .captureFailed, .hotkeyTaken("⌃⌥⌘R")])

        // Once head tracking can work, the optional permission is offered, and the lock test comes
        // last: it is a setup step, not a fault.
        var ready = statuses
        ready[.motion] = .granted
        let untested = Issue.current(
            lockFailedAt: nil, lockUntested: true, permissions: { ready[$0]! },
            capture: .available, isCovering: false, isHotkeyAvailable: true, hotkey: .reanchorDefault
        )
        #expect(untested == [.permission(.screenRecording), .lockUntested])
        #expect(untested.allSatisfy { $0.isSetupStep })
    }

    @Test("A declined Screen Recording is listed again while it is why a covered display is blind")
    func blindSheetHasAMenuLineToPointAt() {
        func issues(covering: Bool) -> [PrivacyPods.Issue] {
            Issue.current(
                lockFailedAt: nil,
                lockUntested: false,
                permissions: { $0 == .screenRecording ? .denied : .granted },
                capture: .unavailable(.screenRecordingDenied),
                isCovering: covering,
                isHotkeyAvailable: true,
                hotkey: .reanchorDefault
            )
        }
        #expect(issues(covering: false).isEmpty)
        #expect(issues(covering: true) == [.permission(.screenRecording)])
    }

    @Test("Instructions only name inputs that work")
    func adviceNamesWorkingInputs() {
        #expect(!Issue.awayRule(canType: false).contains("typing or"))
        #expect(Issue.awayRule(canType: true).contains("typing or pointer"))
        #expect(AppStatus.anchoringAdvice(hotkey: "⌃⌥⌘R", canType: true).contains("type"))
        #expect(!AppStatus.anchoringAdvice(hotkey: nil, canType: false).contains("type"))
        #expect(!AppStatus.anchoringAdvice(hotkey: nil, canType: false).contains("press"))
    }

    @Test("A blurred display explains itself only when looking at it would not clear it")
    func overlayNoticeExplainsStuckBlurs() {
        func notice(_ gaze: GazeState, _ wear: WearState, _ away: AwayResponse = .idle) -> String? {
            AppCoordinator.overlayNotice(gaze: gaze, wearState: wear, awayResponse: away, hotkey: "⌃⌥⌘R", canType: true)
        }
        #expect(notice(.unknown, .unknown(.sampleGap))?.contains("Put them back in") == true)
        #expect(notice(.unknown, .unknown(.noHeadphonesConnected))?.contains("Connect them") == true)
        #expect(notice(.unknown, .worn)?.contains("⌃⌥⌘R") == true)
        // Looking back clears a normal look-away blur; it needs no words.
        #expect(notice(.away, .worn) == nil)
        // Unless a display has no anchor: then "away" may be the user looking at it.
        let unanchored = AppCoordinator.overlayNotice(
            gaze: .away, wearState: .worn, awayResponse: .idle, hotkey: "⌃⌥⌘R", canType: true, displayIsAnchored: false
        )
        #expect(unanchored?.contains("not anchored") == true)
        // An away blur is read by whoever walked up, not by the owner.
        #expect(notice(.unknown, .unknown(.sampleGap), .blur) == nil)
    }

    private func status(
        isEnabled: Bool = true,
        wear: WearState = .worn,
        gaze: GazeState = .looking(DisplayID(1)),
        presence: PresenceState,
        didFailToLock: Bool = false,
        settings: AppSettings = AppSettings()
    ) -> AppStatus {
        var settings = settings
        settings.isEnabled = isEnabled
        return AppStatus.current(
            settings: settings,
            wearState: wear,
            gazeState: gaze,
            presenceState: presence,
            didFailToLock: didFailToLock,
            displayName: { _ in "Built-in Display" }
        )
    }
}
