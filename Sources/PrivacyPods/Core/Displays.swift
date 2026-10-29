import AppKit
import CoreGraphics

/// A display, identified the one way that survives a sleep/wake cycle and a cable swap.
struct DisplayID: Hashable, Sendable, Codable, CustomStringConvertible {
    var rawValue: CGDirectDisplayID

    init(_ rawValue: CGDirectDisplayID) { self.rawValue = rawValue }

    var description: String { "display:\(rawValue)" }
}

/// A snapshot of one attached display. Values are only valid until the next
/// `NSApplication.didChangeScreenParametersNotification`.
struct DisplayInfo: Hashable, Sendable, Identifiable {
    var id: DisplayID
    var name: String
    /// Global AppKit coordinates, origin bottom-left of the main display.
    var frame: CGRect
}

extension DisplayInfo {
    /// The attached displays, in `NSScreen.screens` order.
    ///
    /// The `NSScreenNumber` device-description lookup is the only supported bridge from an
    /// `NSScreen` to the `CGDirectDisplayID` that anchors and overlays are keyed by; every
    /// module must go through here rather than re-deriving it.
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

    /// The display containing `point` in global AppKit coordinates, e.g. `NSEvent.mouseLocation`.
    @MainActor
    static func containing(_ point: CGPoint) -> DisplayInfo? {
        current().first { $0.frame.contains(point) }
    }
}

/// The head pose recorded as "this is what looking at this display feels like".
///
/// Anchors are per-session and per-display. They are discarded when the motion stream restarts
/// (the reference frame changes) and when the display is disconnected.
struct DisplayAnchor: Hashable, Sendable, Codable, Identifiable {
    /// Why this anchor was trusted, which is also how strongly to trust it.
    enum Source: String, Hashable, Sendable, Codable {
        /// Sustained keyboard or pointer input happened with the cursor on this display.
        case sustainedInput
        /// The user pressed the re-anchor hotkey. Overrides `sustainedInput` unconditionally.
        case hotkey
    }

    var display: DisplayID
    var pose: HeadPose
    var capturedAt: Date
    var source: Source

    var id: DisplayID { display }
}
