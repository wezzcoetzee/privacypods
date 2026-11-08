import Foundation

/// The one thing the menu bar says about the app right now. The status line, the icon, the
/// icon's VoiceOver label and the headline of the Status window all come from here, so they
/// cannot disagree.
///
/// Cases are listed in the order they win: a closed gate beats a failure, a failure beats a
/// sensor problem, and only a fully working sensor gets to talk about gaze.
enum AppStatus: Hashable, Sendable {
    /// `until` is when a timed pause ends; `nil` waits for the user.
    case paused(until: Date?)
    /// Blur is off and walking away does nothing, so nothing the sensors say has any effect.
    case protectionOff
    /// The away policy asked for a lock and nothing took effect.
    case lockFailed
    case away
    /// No usable head data. `coversScreens` is "If head data stops: Blur" at work; otherwise
    /// nothing is being protected, and the title says so.
    case headTracking(WearState.Reason, coversScreens: Bool)
    /// Worn, but no display has an anchor to compare the head against yet.
    case notAnchored(coversScreens: Bool)
    case looking(display: String)
    /// `unanchoredDisplay`: some display has no anchor yet, so "away" may really be the user
    /// looking at it. It happens after every unlock on a multi-display Mac until each display has
    /// been anchored again.
    case lookingAway(unanchoredDisplay: Bool)

    /// Whether PrivacyPods is doing its job.
    enum Health: Hashable, Sendable {
        case protecting
        /// Not watching or not able to: nothing will blur or lock until this changes.
        case inactive
        /// Broken in a way only the user can fix.
        case needsAction
    }

    static func current(
        settings: AppSettings,
        wearState: WearState,
        gazeState: GazeState,
        presenceState: PresenceState,
        didFailToLock: Bool,
        hasUnanchoredDisplay: Bool = false,
        displayName: (DisplayID) -> String
    ) -> AppStatus {
        guard settings.isEnabled else { return .paused(until: settings.resumeAt) }
        if settings.blurMode == .off, settings.awayPolicy == .doNothing { return .protectionOff }
        if didFailToLock { return .lockFailed }
        // With no response to walking away, being away changes nothing worth a headline.
        if presenceState.isAway, settings.awayPolicy != .doNothing { return .away }
        let coversScreens = settings.failMode == .closed && settings.blurMode != .off
        if case .unknown(let reason) = wearState { return .headTracking(reason, coversScreens: coversScreens) }
        return switch gazeState {
        case .looking(let id): .looking(display: displayName(id))
        case .away: .lookingAway(unanchoredDisplay: hasUnanchoredDisplay)
        case .unknown: .notAnchored(coversScreens: coversScreens)
        }
    }

    var title: String {
        switch self {
        case .paused(let until):
            until.map {
                // A time alone is ambiguous across midnight.
                let day = Calendar.current.isDateInToday($0) ? Date.FormatStyle.DateStyle.omitted : .abbreviated
                return "Paused until \($0.formatted(date: day, time: .shortened))"
            } ?? "Paused"
        case .protectionOff: "Blur and lock are both off"
        case .lockFailed: "Could not lock the screen"
        case .away: "Away"
        case .headTracking(let reason, let covers): "\(reason.title) (\(Self.gapEffect(covers)))"
        case .notAnchored(let covers): "Not anchored (\(Self.gapEffect(covers)))"
        case .looking(let display): "Looking at \(display)"
        case .lookingAway(let unanchored): unanchored ? "Looking away, or at a display not yet anchored" : "Looking away"
        }
    }

    private static func gapEffect(_ coversScreens: Bool) -> String {
        // "Readable" rather than "not protecting": walking away can still blur and lock.
        coversScreens ? "screens blurred" : "screens readable"
    }

    /// Off because the user said so, as opposed to off because something stopped working.
    var isSwitchedOff: Bool {
        if case .paused = self { true } else { self == .protectionOff }
    }

    var health: Health {
        switch self {
        case .lockFailed, .headTracking(.permissionDenied, _): .needsAction
        case .headTracking(_, coversScreens: true), .notAnchored(coversScreens: true): .protecting
        case .paused, .protectionOff, .headTracking, .notAnchored: .inactive
        case .away, .looking, .lookingAway: .protecting
        }
    }

    /// What to do about this status, if anything. `canType` is whether typing reaches the app
    /// (Input Monitoring), so no instruction names an input that would do nothing.
    func nextStep(hotkey: String?, canType: Bool) -> String? {
        switch self {
        case .paused(let until):
            until == nil ? "Resume from the menu bar to protect your screens." : nil
        case .protectionOff:
            "Turn on Blur, or a response for when you walk away, in Settings."
        case .lockFailed:
            nil // The Lock section below says what to do, next to the buttons that do it.
        case .headTracking(.noHeadphonesConnected, _):
            "Connect AirPods Pro, AirPods (3rd generation or later), AirPods Max or Beats Fit Pro to this Mac and put them in."
        case .headTracking(.motionUnavailable, _):
            "Restart head tracking below. If it keeps stopping, these AirPods may not support it: you need AirPods Pro, AirPods (3rd generation or later), AirPods Max or Beats Fit Pro."
        case .headTracking(.sampleGap, _):
            "Put your AirPods back in. If your iPhone keeps taking them, set them to connect to it only when last connected."
        case .headTracking(.permissionDenied, _):
            "Allow Motion below."
        case .notAnchored, .lookingAway(unanchoredDisplay: true):
            Self.anchoringAdvice(hotkey: hotkey, canType: canType)
        case .away, .looking, .lookingAway:
            nil
        }
    }

    /// How to anchor a display with whatever inputs actually work right now.
    static func anchoringAdvice(hotkey: String?, canType: Bool) -> String {
        let input = canType ? "type" : "move the pointer around"
        return "Put the pointer on a display, look at it, and \(input)"
            + (hotkey.map { ", or press \($0)." } ?? ", or choose Anchor This Display in the PrivacyPods menu.")
    }
}

/// The status item's look: one eye throughout, so the app keeps a single silhouette in the menu
/// bar, with one variant per thing the user needs to tell apart at a glance.
///
/// - `eye`: protecting, and what you are looking at is readable.
/// - `eye.slash`: what you are looking at, or every display, is covered right now.
/// - `eye.half.closed`: running, but it cannot see you (no AirPods, no head data, no anchor).
/// - `pause.circle`, dimmed: you paused it. `eye.slash.circle`, dimmed: blur and lock are both
///   off. Dimming is kept for these alone, so a dim icon always means "you chose this".
/// - `eye.trianglebadge.exclamationmark`: something needs fixing.
struct StatusIcon: Hashable, Sendable {
    let symbolName: String
    let isDimmed: Bool

    /// `coversView` is whether the display being looked at, or every display, is covered; a
    /// display blurred by design in "Displays you're not looking at" mode does not count.
    init(status: AppStatus, issues: [Issue], coversView: Bool) {
        if case .paused = status {
            // Its own shape, so "you paused it" can never be read as "it is blurring you", and it
            // wins over the badge: while paused, the menu still lists what needs fixing.
            (symbolName, isDimmed) = ("pause.circle", true)
        } else if status.health == .needsAction || issues.contains(where: \.badgesIcon) {
            (symbolName, isDimmed) = ("eye.trianglebadge.exclamationmark", false)
        } else if status == .protectionOff {
            (symbolName, isDimmed) = ("eye.slash.circle", true)
        } else if coversView {
            (symbolName, isDimmed) = ("eye.slash", false)
        } else {
            (symbolName, isDimmed) = (status.health == .protecting ? "eye" : "eye.half.closed", false)
        }
    }
}

extension WearState.Reason {
    var title: String {
        switch self {
        case .noHeadphonesConnected: "No head-tracking AirPods connected"
        case .sampleGap: "No head data from AirPods"
        case .motionUnavailable: "Head tracking stopped"
        case .permissionDenied: "Motion not allowed"
        }
    }
}

/// Something that keeps the app from working fully and that the user can fix. Shown as its own
/// line in the menu, under the status, and in its own section of the Status window, until
/// resolved.
enum Issue: Hashable, Sendable, Identifiable {
    /// A lock that did not take, kept until a lock works or the owner dismisses it in Status: by
    /// the time they are back to read anything, the away state that produced it is long over.
    case lockFailed(at: Date)
    /// The response to walking away locks, and no lock PrivacyPods started has been seen to work
    /// yet, so the first real absence would also be the first test.
    case lockUntested
    case permission(Permission)
    case captureFailed
    case hotkeyTaken(String)

    var id: Self { self }

    /// What counts as away, said the same way in Settings and Status. Without Input Monitoring
    /// typing is invisible, so the sentence does not promise that it counts.
    static func awayRule(canType: Bool) -> String {
        "You are away once the AirPods show you walking off, or 30 seconds after they disconnect with no \(canType ? "typing or pointer movement" : "pointer movement (typing is not seen without Input Monitoring)")."
    }

    /// The one setting that makes the display-sleep fallback lock.
    static let lockAdvice = "Set Require password to Immediately in Lock Screen settings, or the next lock may fail too."

    /// Every issue, worst first. Motion is left out while it is still undetermined: it is asked
    /// for by the tracker itself, and the Status window explains that. Screen Recording and Input
    /// Monitoring only degrade the app, so once the user has said no to either, that is their
    /// answer: the Status window still shows the row, but the menu stops asking.
    static func current(
        lockFailedAt: Date?,
        lockUntested: Bool,
        permissions: (Permission) -> PermissionStatus,
        capture: CaptureAvailability,
        isCovering: Bool,
        isHotkeyAvailable: Bool,
        hotkey: Hotkey
    ) -> [Issue] {
        var issues: [Issue] = lockFailedAt.map { [.lockFailed(at: $0)] } ?? []
        // While a covered display is blind for want of Screen Recording, the sheet sends the user
        // to the menu, so the line has to be there whatever else applies.
        let blindNow = isCovering && capture == .unavailable(.screenRecordingDenied)
        // The optional permissions wait until head tracking can work: first run asks only for
        // what gets the app going.
        let headTrackingReady = permissions(.motion) == .granted
        issues += Permission.allCases.compactMap { permission in
            switch permissions(permission) {
            case .granted: nil
            case _ where permission == .screenRecording && blindNow: .permission(permission)
            // Motion and Bluetooth are asked by macOS itself the first time their sensor starts.
            case .notDetermined where permission == .motion || permission == .bluetooth: nil
            case .notDetermined where !headTrackingReady: nil
            case .denied where permission != .motion: nil
            case .denied, .notDetermined, .unavailable: .permission(permission)
            }
        }
        if capture == .unavailable(.captureFailed) { issues.append(.captureFailed) }
        if !isHotkeyAvailable { issues.append(.hotkeyTaken(hotkey.label)) }
        // Last: a setup step comes after everything that keeps the app from working.
        if lockFailedAt == nil, lockUntested { issues.append(.lockUntested) }
        return issues
    }

    /// The menu line. Each one opens the window where it is fixed.
    var title: String {
        switch self {
        case .lockFailed(let at): "Review Failed Lock (\(at.formatted(date: .omitted, time: .shortened)))…"
        case .permission(let permission): "Allow \(permission.title)…"
        case .lockUntested: "Test Screen Lock…"
        case .captureFailed: "Retry Display Capture"
        case .hotkeyTaken: "Change Re-anchor Shortcut…"
        }
    }

    static func hotkeyTakenText(_ hotkey: String) -> String {
        "\(hotkey) is taken by another app."
    }

    /// Something to do, not something wrong: listed, but not counted, coloured or badged. The same
    /// rule as the icon's badge, so the window and the menu bar never disagree about severity.
    var isSetupStep: Bool {
        !badgesIcon
    }

    /// Only Motion, a failed lock or capture, and a taken shortcut stop the app doing its job.
    /// Screen Recording, Input Monitoring and Bluetooth only degrade it (a blind cover still hides
    /// the screen; the pointer and shortcut still anchor), so they are listed without a warning.
    var badgesIcon: Bool {
        switch self {
        case .permission(let permission): permission == .motion
        case .lockFailed, .captureFailed, .hotkeyTaken: true
        // A setup step: listed until done, but it does not alarm.
        case .lockUntested: false
        }
    }
}

extension PermissionStatus {
    var title: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not asked yet"
        case .unavailable: "Unavailable"
        }
    }
}

extension PresenceState {
    var title: String {
        switch self {
        case .present: "At the Mac"
        case .unknown: "Unknown"
        case .away(let since): "Away since \(since.formatted(date: .omitted, time: .shortened))"
        }
    }
}
