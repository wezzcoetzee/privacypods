import AppKit
import CoreGraphics

struct DisplayID: Hashable, Sendable, CustomStringConvertible {
    var rawValue: CGDirectDisplayID

    init(_ rawValue: CGDirectDisplayID) { self.rawValue = rawValue }

    var description: String { "display:\(rawValue)" }
}

/// Valid until the next `NSApplication.didChangeScreenParametersNotification`.
struct DisplayInfo: Hashable, Sendable, Identifiable {
    var id: DisplayID
    var name: String
    /// Global AppKit coordinates, origin bottom-left of the main display.
    var frame: CGRect
}

extension DisplayInfo {
    /// `NSScreenNumber` is the only supported bridge from `NSScreen` to `CGDirectDisplayID`;
    /// go through here rather than re-deriving it.
    @MainActor
    static func current() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return DisplayInfo(
                id: DisplayID(number.uint32Value),
                name: screen.localizedName,
                frame: screen.frame
            )
        }
    }

    @MainActor
    static func containing(_ point: CGPoint) -> DisplayInfo? {
        current().first { $0.frame.contains(point) }
    }
}

/// Session-scoped: discarded when the motion stream restarts (new reference frame) or the
/// display is disconnected.
struct DisplayAnchor: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case sustainedInput
        /// Overrides `sustainedInput` unconditionally.
        case hotkey
    }

    var display: DisplayID
    var pose: HeadPose
    var capturedAt: Date
    var source: Source
}
