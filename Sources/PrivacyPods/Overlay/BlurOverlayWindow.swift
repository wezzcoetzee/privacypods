import AppKit

@MainActor
final class BlurOverlayWindow: NSWindow {
    private let sheetView = OverlaySheet()
    private var captureNotice: String?
    private var reason: String?

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)

        level = Self.level
        sharingType = .none
        // `.transient` is mutually exclusive with `.stationary`, which the sheet needs.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        // Opaque is a privacy property: nothing behind the window shows before a capture arrives.
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

    /// Below the menu bar so Pause stays reachable when every display is covered, with one level
    /// spare for the app's own windows to rise above the sheet.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 2)

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func render(_ image: CGImage) {
        sheetView.render(image)
    }

    func show(notice: String?) {
        captureNotice = notice
        updateNotice()
    }

    func show(reason: String?) {
        self.reason = reason
        updateNotice()
    }

    private func updateNotice() {
        let lines = [reason, captureNotice].compactMap(\.self)
        sheetView.show(notice: lines.isEmpty ? nil : lines.joined(separator: "\n\n"))
    }

    func clear() {
        sheetView.render(nil)
        captureNotice = nil
        reason = nil
        updateNotice()
    }
}

/// The flat scrim replaces `NSGlassEffectView`, which refracts the backdrop behind the window (a leak).
@MainActor
private final class OverlaySheet: NSView {
    static let glass = NSColor(white: 0.06, alpha: 1)
    private static let scrim = NSColor(white: 0.06, alpha: 0.35)
    private static let noticeScrim = NSColor(white: 0.06, alpha: 0.6)

    private let frameView = CapturedFrameView()
    private let scrimView = NSView()
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private var lastAnnounced: String?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.glass.cgColor

        addSubview(frameView)
        addSubview(scrimView)
        scrimView.wantsLayer = true
        scrimView.layer?.backgroundColor = Self.scrim.cgColor

        noticeLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        noticeLabel.textColor = .white
        noticeLabel.alignment = .center
        noticeLabel.maximumNumberOfLines = 0
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.8)
        shadow.shadowBlurRadius = 6
        noticeLabel.shadow = shadow
        noticeLabel.isHidden = true
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(noticeLabel)
        NSLayoutConstraint.activate([
            noticeLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            noticeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            noticeLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        frameView.frame = bounds
        scrimView.frame = bounds
        noticeLabel.preferredMaxLayoutWidth = newSize.width * 0.8
    }

    func render(_ image: CGImage?) {
        frameView.render(image)
    }

    func show(notice: String?) {
        let isNew = notice != nil && notice != lastAnnounced
        if isNew { lastAnnounced = notice }
        noticeLabel.stringValue = notice ?? ""
        noticeLabel.isHidden = notice == nil
        if isNew, let notice {
            NSAccessibility.post(
                element: NSApp as Any, notification: .announcementRequested,
                userInfo: [
                    .announcement: notice,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
        scrimView.layer?.backgroundColor = (notice == nil ? Self.scrim : Self.noticeScrim).cgColor
    }
}

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
