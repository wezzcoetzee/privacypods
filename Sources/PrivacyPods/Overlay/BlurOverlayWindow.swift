import AppKit

/// The click-through sheet that covers one display.
///
/// Every property here is chosen so the window hides content without becoming content: it never
/// takes focus, never shows up in Mission Control or the window cycle, follows the user between
/// spaces, and excludes itself from screen capture so the stream feeding it cannot photograph its
/// own output.
///
/// The window is opaque, and that is a privacy property rather than a drawing detail. Nothing it
/// draws samples what is behind it, so a capture that has not started yet, or that never will,
/// shows the app's own dark glass instead of the screen it was asked to hide.
@MainActor
final class BlurOverlayWindow: NSWindow {
    private let sheetView = OverlaySheet()

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)

        level = .screenSaver
        sharingType = .none
        // `.transient` is documented as mutually exclusive with `.stationary`, and the sheet has to
        // be stationary: it covers one display in place, on every space, including over a
        // full-screen app.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = true
        backgroundColor = OverlaySheet.glass
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        alphaValue = 0

        sheetView.frame = CGRect(origin: .zero, size: frame.size)
        sheetView.autoresizingMask = [.width, .height]
        contentView = sheetView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Swaps in the newest blurred frame. Called about four times a second while visible.
    func render(_ image: CGImage) {
        sheetView.render(image)
    }

    /// The one line the sheet shows while there is nothing to blur, or `nil` once there is.
    func show(notice: String?) {
        sheetView.show(notice: notice)
    }

    /// Drops the frame and the notice, so a re-show never flashes a stale screenshot or a stale
    /// message.
    func clear() {
        sheetView.render(nil)
        sheetView.show(notice: nil)
    }
}

/// What the sheet is made of: the blurred capture, a scrim over it, and the notice that explains an
/// empty sheet.
///
/// The scrim is where `NSGlassEffectView` used to be. Glass refracts the backdrop behind the
/// window, and AppKit offers no way to confine it to the window's own content, so on an overlay
/// whose whole job is to hide the screen behind it the effect is a leak waiting to happen. A flat
/// tint over the blurred frame cannot leak, costs nothing to composite, and repaints only when a
/// frame does.
@MainActor
private final class OverlaySheet: NSView {
    /// Not black: a dead-black display reads as a broken one, and this sheet is often all the user
    /// can see.
    static let glass = NSColor(white: 0.06, alpha: 1)
    private static let scrim = NSColor(white: 0.06, alpha: 0.35)

    private let frameView = CapturedFrameView()
    private let scrimView = NSView()
    private let noticeLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.glass.cgColor

        addSubview(frameView)
        addSubview(scrimView)
        scrimView.wantsLayer = true
        scrimView.layer?.backgroundColor = Self.scrim.cgColor

        noticeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        noticeLabel.textColor = .white
        noticeLabel.alignment = .center
        noticeLabel.isHidden = true
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(noticeLabel)
        NSLayoutConstraint.activate([
            noticeLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            noticeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The two fills always cover the sheet exactly, whatever the display does to its size.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        frameView.frame = bounds
        scrimView.frame = bounds
    }

    func render(_ image: CGImage?) {
        frameView.render(image)
    }

    func show(notice: String?) {
        noticeLabel.stringValue = notice ?? ""
        noticeLabel.isHidden = notice == nil
    }
}

/// Draws the blurred capture, and nothing else.
///
/// The layer's contents are replaced wholesale from the main actor; implicit animation is off so
/// frames succeed each other instead of cross-fading, and the layer is never asked to redraw
/// itself between frames. With no frame it is transparent, and the sheet's glass shows through.
@MainActor
private final class CapturedFrameView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func render(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }
}
