import Foundation

/// Turns a trickle of raw input events into "the user is engaged with whatever is under the
/// cursor", which is the one moment the app is allowed to assume where they are looking.
///
/// A single keystroke or a nudge of the mouse proves nothing: people type while turned away and
/// mice get knocked. A burst does.
struct SustainedInputDetector {
    enum Kind: Hashable, Sendable {
        case key
        case pointer
    }

    /// Everything is judged over this sliding window.
    private let window: TimeInterval = 1
    /// Three keystrokes inside the window is typing rather than a stray key.
    private let keystrokes = 3
    /// How much of the window pointer motion has to fill to count.
    private let pointerMotion: TimeInterval = 0.3
    /// A quiet spell longer than this splits one movement into two; it is not motion itself.
    private let pointerContinuity: TimeInterval = 0.1

    private var recent: [(kind: Kind, at: Date)] = []

    /// Records an event and answers whether the window now amounts to sustained input.
    /// Answering yes clears the window, so the next burst has to earn its own.
    mutating func record(_ kind: Kind, at instant: Date) -> Bool {
        recent.removeAll { instant.timeIntervalSince($0.at) > window }
        recent.append((kind, instant))
        guard keystrokeCount >= keystrokes || pointerMotionDuration >= pointerMotion else { return false }
        recent.removeAll()
        return true
    }

    mutating func reset() {
        recent.removeAll()
    }

    private var keystrokeCount: Int {
        recent.filter { $0.kind == .key }.count
    }

    /// How long the pointer was actually moving inside the window: the gaps between consecutive
    /// pointer events, ignoring any gap long enough to be a pause.
    private var pointerMotionDuration: TimeInterval {
        let moments = recent.filter { $0.kind == .pointer }.map(\.at)
        return zip(moments, moments.dropFirst()).reduce(0) { total, pair in
            let gap = pair.1.timeIntervalSince(pair.0)
            return gap <= pointerContinuity ? total + gap : total
        }
    }
}
