import Foundation

/// The menu bar line, icon, VoiceOver label and Status headline all come from here, so they
/// cannot disagree. Cases are listed in the order they win.
enum AppStatus: Hashable, Sendable {
    case paused(until: Date?)
    /// Blur is off and walking away does nothing.
    case protectionOff
    case lockFailed
    case away
    /// `coversScreens` is fail-closed at work.
    case headTracking(WearState.Reason, coversScreens: Bool)
    case notAnchored(coversScreens: Bool)
    case looking(display: String)
    /// `unanchoredDisplay`: "away" may really be the user looking at a display with no anchor yet.
    case lookingAway(unanchoredDisplay: Bool)

    enum Health: Hashable, Sendable {
        case protecting
        case inactive
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
        case .headTracking(let reason, _): reason.title
        case .notAnchored: "Not anchored"
        case .looking(let display): "Looking at \(display)"
        case .lookingAway(let unanchored): unanchored ? "Looking away, or at a display not yet anchored" : "Looking away"
        }
    }

    /// `nil` for statuses where it is not the open question.
    var coversScreensMeanwhile: Bool? {
        switch self {
        case .headTracking(_, let covers), .notAnchored(let covers): covers
        default: nil
        }
    }

    /// "Readable" rather than "not protecting": walking away can still blur and lock.
    var effect: String? {
        coversScreensMeanwhile.map { $0 ? "Screens blurred." : "Screens readable." }
    }

    var summary: String {
        effect.map { "\(title). \($0)" } ?? title
    }

    var isAboutAnchoring: Bool {
        switch self {
        case .notAnchored, .lookingAway(unanchoredDisplay: true): true
        default: false
        }
    }

    var health: Health {
        switch self {
        case .lockFailed, .headTracking(.permissionDenied, _): .needsAction
        case .headTracking(_, coversScreens: true), .notAnchored(coversScreens: true): .protecting
        case .paused, .protectionOff, .headTracking, .notAnchored: .inactive
        case .away, .looking, .lookingAway: .protecting
        }
    }

    /// `canType` is whether typing reaches the app, so no instruction names a dead input.
    func nextStep(hotkey: String?, canType: Bool) -> String? {
        switch self {
        case .paused(let until):
            until == nil ? "Resume from the menu bar to protect your screens." : nil
        case .protectionOff:
            "Turn on Blur, or a response for when you walk away, in Settings."
        case .lockFailed:
            nil  // The Lock section says what to do, next to its buttons.
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

    static func anchoringAdvice(for display: String? = nil, hotkey: String?, canType: Bool) -> String {
        let input = canType ? "type" : "move the pointer around"
        let start = display.map { "To anchor \($0), put the pointer on it" } ?? "Put the pointer on a display"
        return "\(start), look at it, and \(input)"
            + (hotkey.map { ", or press \($0)." } ?? ", or choose Anchor This Display in the PrivacyPods menu.")
    }
}

/// Dimming is reserved for what the user switched off, so a dim icon always means "you chose this".
struct StatusIcon: Hashable, Sendable {
    let symbolName: String
    let isDimmed: Bool

    init(status: AppStatus, issues: [Issue], coversView: Bool) {
        if case .paused = status {
            // Wins over the badge: while paused, the menu still lists what needs fixing.
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

/// Something the user can fix, shown in the menu and the Status window until resolved.
enum Issue: Hashable, Sendable {
    case lockFailed(at: Date)
    case lockUntested
    case failModeUnchosen
    case permission(Permission)
    case captureFailed
    case hotkeyTaken(String)

    static func awayRule(canType: Bool) -> String {
        "You are away once the AirPods show you walking off, or 30 seconds after they disconnect with no \(canType ? "typing or pointer movement" : "pointer movement (typing is not seen without Input Monitoring)")."
    }

    static let lockAdvice = "Set Require password to Immediately in Lock Screen settings, or the next lock may fail too."

    /// Worst first. A declined Screen Recording or Input Monitoring is the user's answer, so the
    /// menu stops asking for it.
    static func current(
        lockFailedAt: Date?,
        lockUntested: Bool,
        failModeUnchosen: Bool,
        permissions: (Permission) -> PermissionStatus,
        capture: CaptureAvailability,
        isCovering: Bool,
        isHotkeyAvailable: Bool,
        hotkey: Hotkey
    ) -> [Issue] {
        var issues: [Issue] = lockFailedAt.map { [.lockFailed(at: $0)] } ?? []
        // The blind sheet points the user at this menu line, so it must exist.
        let blindNow = isCovering && capture == .unavailable(.screenRecordingDenied)
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
        // Setup steps last, in the Status window's step order.
        if failModeUnchosen { issues.append(.failModeUnchosen) }
        if lockFailedAt == nil, lockUntested { issues.append(.lockUntested) }
        return issues
    }

    var title: String {
        switch self {
        case .lockFailed(let at): "Review Failed Lock (\(at.formatted(date: .omitted, time: .shortened)))…"
        case .permission(let permission): "Allow \(permission.title)…"
        case .lockUntested: "Test Screen Lock…"
        case .failModeUnchosen: "Choose What Happens If Head Data Stops…"
        case .captureFailed: "Retry Display Capture"
        case .hotkeyTaken: "Change Re-anchor Shortcut…"
        }
    }

    static func hotkeyTakenText(_ hotkey: String) -> String {
        "\(hotkey) is taken by another app."
    }

    var isSetupStep: Bool {
        !badgesIcon
    }

    /// Screen Recording, Input Monitoring and Bluetooth only degrade the app, so they do not badge.
    var badgesIcon: Bool {
        switch self {
        case .permission(let permission): permission == .motion
        case .lockFailed, .captureFailed, .hotkeyTaken: true
        case .lockUntested, .failModeUnchosen: false
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
