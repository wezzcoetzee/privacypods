import Foundation

/// When the blur is applied.
enum BlurMode: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case off
    /// Blur every display while the user is not looking at any of them.
    case whenLookingAway
    /// Blur every display except the one being looked at. Blurs all of them while away.
    case unfocusedDisplays

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "Off"
        case .whenLookingAway: "When looking away"
        case .unfocusedDisplays: "Unfocused displays"
        }
    }
}

/// What to do about blur while head data is missing.
///
/// This governs blur only. A sensor gap never produces an away state and never locks the
/// screen, whichever mode is selected.
enum FailMode: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    /// Leave the screens readable during a gap.
    case open
    /// Blur during a gap.
    case closed

    var id: Self { self }

    var title: String {
        switch self {
        case .open: "Stay readable"
        case .closed: "Blur"
        }
    }
}

/// What happens once the user is confirmed away.
enum AwayPolicy: Hashable, Sendable, Codable {
    case doNothing
    case blurThenLock(blurAfter: TimeInterval, lockAfter: TimeInterval)
    case lockImmediately

    static let `default` = AwayPolicy.blurThenLock(blurAfter: 5, lockAfter: 30)

    /// The response for an away state that began `elapsed` seconds ago.
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

/// A global hotkey, in the units Carbon's `RegisterEventHotKey` wants.
struct Hotkey: Hashable, Sendable, Codable {
    struct Modifiers: OptionSet, Hashable, Sendable, Codable {
        var rawValue: UInt32

        static let command = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)

        /// The mask `RegisterEventHotKey` expects (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
        var carbonFlags: UInt32 {
            var flags: UInt32 = 0
            if contains(.command) { flags |= 1 << 8 }
            if contains(.shift) { flags |= 1 << 9 }
            if contains(.option) { flags |= 1 << 11 }
            if contains(.control) { flags |= 1 << 12 }
            return flags
        }

        /// Menu-order symbols, e.g. `⌃⌥⌘`.
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

/// Everything the user can change. Persisted whole as JSON in `UserDefaults`.
struct AppSettings: Hashable, Sendable, Codable {
    var isEnabled: Bool = true
    var blurMode: BlurMode = .whenLookingAway
    var awayPolicy: AwayPolicy = .default
    var failMode: FailMode = .open
    var acceptanceCone: AcceptanceCone = .default
    /// Seconds the gaze must stay outside every cone before the app calls it away. Switching
    /// back to a display is immediate; only the exit is damped.
    var awayGrace: TimeInterval = 0.7
    var reanchorHotkey: Hotkey = .reanchorDefault
    var launchAtLogin: Bool = false
    /// `CIGaussianBlur` radius in points.
    var blurRadius: Double = 70

    /// The `UserDefaults` key the settings store reads and writes.
    static let defaultsKey = "dev.wesley.privacypods.settings"
}

extension AppSettings {
    enum CodingKeys: String, CodingKey {
        case isEnabled, blurMode, awayPolicy, failMode, acceptanceCone
        case awayGrace, reanchorHotkey, launchAtLogin, blurRadius
    }

    /// Decodes field by field so that adding a setting does not invalidate a user's stored
    /// preferences. A field that is present but malformed still throws; the settings store
    /// treats that as "fall back to defaults".
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? fallback.isEnabled
        blurMode = try container.decodeIfPresent(BlurMode.self, forKey: .blurMode) ?? fallback.blurMode
        awayPolicy = try container.decodeIfPresent(AwayPolicy.self, forKey: .awayPolicy) ?? fallback.awayPolicy
        failMode = try container.decodeIfPresent(FailMode.self, forKey: .failMode) ?? fallback.failMode
        acceptanceCone = try container.decodeIfPresent(AcceptanceCone.self, forKey: .acceptanceCone) ?? fallback.acceptanceCone
        awayGrace = try container.decodeIfPresent(TimeInterval.self, forKey: .awayGrace) ?? fallback.awayGrace
        reanchorHotkey = try container.decodeIfPresent(Hotkey.self, forKey: .reanchorHotkey) ?? fallback.reanchorHotkey
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? fallback.launchAtLogin
        blurRadius = try container.decodeIfPresent(Double.self, forKey: .blurRadius) ?? fallback.blurRadius
    }
}

extension BlurMode {
    /// The displays that should be blurred right now.
    ///
    /// This lives on the mode rather than in the engine so the overlay and the menu bar cannot
    /// disagree about what is blurred. The caller is still responsible for the gates that sit
    /// above it: a disabled app, a locked screen, or an away escalation all bypass this.
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
