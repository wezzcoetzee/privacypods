import Foundation

/// The per-display anchor table.
///
/// Anchors are session-scoped. The headphones' reference frame is established when the motion
/// stream starts and drifts from then on, so an anchor only means anything against poses from
/// the same run.
struct DisplayAnchorStore: Hashable, Sendable {
    private(set) var anchors: [DisplayID: DisplayAnchor] = [:]

    /// Records `pose` as what looking at `display` feels like.
    ///
    /// Newer readings win, so sustained input keeps correcting the drift. A tie goes to the
    /// hotkey: pressing the re-anchor hotkey is itself keyboard input, and the burst it produces
    /// must not overwrite the anchor it just set.
    mutating func record(_ pose: HeadPose, for display: DisplayID, source: DisplayAnchor.Source, at instant: Date) {
        if source != .hotkey, let existing = anchors[display], existing.capturedAt >= instant { return }
        anchors[display] = DisplayAnchor(display: display, pose: pose, capturedAt: instant, source: source)
    }

    /// Forgets displays that are no longer attached.
    mutating func retainOnly(_ displays: Set<DisplayID>) {
        anchors = anchors.filter { displays.contains($0.key) }
    }

    mutating func removeAll() {
        anchors.removeAll()
    }
}
