import Foundation

/// Anchors are session-scoped: the headphones' reference frame is reset each time the motion stream starts.
struct DisplayAnchorStore: Hashable, Sendable {
    private(set) var anchors: [DisplayID: DisplayAnchor] = [:]

    /// Newer wins. A tie goes to the hotkey: its own keyboard burst must not overwrite the anchor it set.
    mutating func record(_ pose: HeadPose, for display: DisplayID, source: DisplayAnchor.Source, at instant: Date) {
        if source != .hotkey, let existing = anchors[display], existing.capturedAt >= instant { return }
        anchors[display] = DisplayAnchor(display: display, pose: pose, capturedAt: instant, source: source)
    }

    mutating func retainOnly(_ displays: Set<DisplayID>) {
        anchors = anchors.filter { displays.contains($0.key) }
    }

    mutating func removeAll() {
        anchors.removeAll()
    }
}
