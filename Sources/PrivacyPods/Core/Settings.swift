import Foundation

enum BlurMode: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case off
    case whenLookingAway
    /// Every display except the one being looked at; all of them while away.
    case unfocusedDisplays

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "Off"
        case .whenLookingAway: "When you look away"
        case .unfocusedDisplays: "Displays you're not looking at"
        }
    }

    var menuTitle: String {
        switch self {
        case .off: "Off"
        case .whenLookingAway: "When You Look Away"
        case .unfocusedDisplays: "Displays You're Not Looking At"
        }
    }
}

/// Governs blur only. A sensor gap never produces an away state or a lock in either mode.
enum FailMode: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case open
    case closed

    var id: Self { self }

    var title: String {
        switch self {
        case .open: "Stay readable"
        case .closed: "Blur"
        }
    }
}

enum AwayPolicy: Hashable, Sendable, Codable {
    case doNothing
    case blurThenLock(blurAfter: TimeInterval, lockAfter: TimeInterval)
    case lockImmediately

    static let `default` = AwayPolicy.blurThenLock(blurAfter: 5, lockAfter: 30)

    func response(awayFor elapsed: TimeInterval) -> AwayResponse {
        switch self {
        case .doNothing:
            .idle
        case .lockImmediately:
            .lock
        case .blurThenLock(let blurAfter, let lockAfter):
            if elapsed >= lockAfter { .lock } else if elapsed >= blurAfter { .blur } else { .idle }
        }
    }
}

/// In the units Carbon's `RegisterEventHotKey` wants.
struct Hotkey: Hashable, Sendable, Codable {
    struct Modifiers: OptionSet, Hashable, Sendable, Codable {
        var rawValue: UInt32

        static let command = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)

        /// `cmdKey`, `shiftKey`, `optionKey`, `controlKey`.
        var carbonFlags: UInt32 {
            var flags: UInt32 = 0
            if contains(.command) { flags |= 1 << 8 }
            if contains(.shift) { flags |= 1 << 9 }
            if contains(.option) { flags |= 1 << 11 }
            if contains(.control) { flags |= 1 << 12 }
            return flags
        }

        var symbols: String {
            var result = ""
            if contains(.control) { result += "⌃" }
            if contains(.option) { result += "⌥" }
            if contains(.shift) { result += "⇧" }
            if contains(.command) { result += "⌘" }
            return result
        }
    }

    /// A virtual key code, e.g. `kVK_ANSI_R`.
    var keyCode: UInt32
    var modifiers: Modifiers

    /// ⌃⌥⌘R
    static let reanchorDefault = Hotkey(keyCode: 0x0F, modifiers: [.control, .option, .command])
}

struct AppSettings: Hashable, Sendable, Codable {
    var isEnabled: Bool = true
    /// `nil` with `isEnabled` off is a pause until the user resumes.
    var resumeAt: Date?
    var blurMode: BlurMode = .whenLookingAway
    var awayPolicy: AwayPolicy = .default
    var failMode: FailMode = .open
    var acceptanceCone: AcceptanceCone = .default
    /// Only leaving a display is damped; switching back is immediate.
    var awayGrace: TimeInterval = 0.7
    var reanchorHotkey: Hotkey = .reanchorDefault
    var launchAtLogin: Bool = false
    /// In points.
    var blurRadius: Double = 70
    var lockTested: Bool = false
    var launchAtLoginOffered: Bool = false
    var failModeChosen: Bool = false
    /// Latched: a later failed lock clears `lockTested` but does not send the owner back through setup.
    var setupFinished: Bool = false

    static let defaultsKey = "dev.wesley.privacypods.settings"
}

extension AppSettings {
    enum CodingKeys: String, CodingKey {
        case isEnabled, resumeAt, blurMode, awayPolicy, failMode, acceptanceCone
        case awayGrace, reanchorHotkey, launchAtLogin, blurRadius, lockTested, launchAtLoginOffered
        case failModeChosen, setupFinished
    }

    /// Field by field, so adding a setting does not invalidate stored preferences.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? fallback.isEnabled
        resumeAt = try container.decodeIfPresent(Date.self, forKey: .resumeAt)
        blurMode = try container.decodeIfPresent(BlurMode.self, forKey: .blurMode) ?? fallback.blurMode
        awayPolicy = try container.decodeIfPresent(AwayPolicy.self, forKey: .awayPolicy) ?? fallback.awayPolicy
        failMode = try container.decodeIfPresent(FailMode.self, forKey: .failMode) ?? fallback.failMode
        acceptanceCone = try container.decodeIfPresent(AcceptanceCone.self, forKey: .acceptanceCone) ?? fallback.acceptanceCone
        awayGrace = try container.decodeIfPresent(TimeInterval.self, forKey: .awayGrace) ?? fallback.awayGrace
        reanchorHotkey = try container.decodeIfPresent(Hotkey.self, forKey: .reanchorHotkey) ?? fallback.reanchorHotkey
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? fallback.launchAtLogin
        blurRadius = try container.decodeIfPresent(Double.self, forKey: .blurRadius) ?? fallback.blurRadius
        lockTested = try container.decodeIfPresent(Bool.self, forKey: .lockTested) ?? fallback.lockTested
        launchAtLoginOffered = try container.decodeIfPresent(Bool.self, forKey: .launchAtLoginOffered) ?? fallback.launchAtLoginOffered
        // Stored settings without these keys come from a build that had no first-run setup. That
        // owner is past it, so these count as done rather than sending them back through it.
        failModeChosen = try container.decodeIfPresent(Bool.self, forKey: .failModeChosen) ?? true
        setupFinished = try container.decodeIfPresent(Bool.self, forKey: .setupFinished) ?? true
    }

    mutating func choose(failMode: FailMode) {
        self.failMode = failMode
        failModeChosen = true
    }

    var hasDoneSetupSteps: Bool {
        failModeChosen && (lockTested || awayPolicy == .doNothing)
    }
}

extension BlurMode {
    /// The caller still owns the gates above this: a disabled app, a locked screen and an away
    /// escalation all bypass it.
    func displaysToBlur(gaze: GazeState, allDisplays: Set<DisplayID>, failMode: FailMode) -> Set<DisplayID> {
        switch self {
        case .off:
            []
        case .whenLookingAway:
            switch gaze {
            case .looking: []
            case .away: allDisplays
            case .unknown: failMode == .closed ? allDisplays : []
            }
        case .unfocusedDisplays:
            switch gaze {
            case .looking(let focused): allDisplays.subtracting([focused])
            case .away: allDisplays
            case .unknown: failMode == .closed ? allDisplays : []
            }
        }
    }
}
