import Foundation

struct SustainedInputDetector {
    enum Kind: Hashable, Sendable {
        case key
        case pointer
    }

    private let window: TimeInterval = 1
    private let keystrokes = 3
    private let pointerMotion: TimeInterval = 0.3
    /// A gap longer than this is a pause, not motion.
    private let pointerContinuity: TimeInterval = 0.1

    private var recent: [(kind: Kind, at: Date)] = []

    /// Returns true when the window amounts to sustained input, and clears it.
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

    private var pointerMotionDuration: TimeInterval {
        let moments = recent.filter { $0.kind == .pointer }.map(\.at)
        return zip(moments, moments.dropFirst()).reduce(0) { total, pair in
            let gap = pair.1.timeIntervalSince(pair.0)
            return gap <= pointerContinuity ? total + gap : total
        }
    }
}
