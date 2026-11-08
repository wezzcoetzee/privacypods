import AppKit

/// One display's worth of overlay: the window, the capture feeding it, and the fade between them.
///
/// The fade generation is what makes show and hide safe to interleave. A hide that is still fading
/// out when the user looks away and straight back gets its completion dropped, so the window is
/// never ordered out from under a capture that has just restarted.
@MainActor
final class DisplaySurface {
    private static let fadeDuration: TimeInterval = 0.15

    private let window: BlurOverlayWindow
    private let capture: DisplayCapture
    private var isShown = false
    private var fadeGeneration = 0

    init(
        display: DisplayInfo,
        renderer: BlurRenderer,
        onAvailability: @escaping @MainActor @Sendable (DisplayID, CaptureAvailability) -> Void
    ) {
        let window = BlurOverlayWindow(frame: display.frame)
        let id = display.id
        self.window = window
        capture = DisplayCapture(
            display: id,
            pointSize: display.frame.size,
            renderer: renderer,
            onFrame: { [weak window] image in window?.render(image) },
            onAvailability: { [weak window] availability in
                window?.show(notice: availability.notice)
                onAvailability(id, availability)
            }
        )
    }

    func show(radius: Double, notice: String?) {
        window.show(reason: notice)
        capture.start(radius: radius)
        fadeGeneration += 1
        if !isShown {
            isShown = true
            window.orderFrontRegardless()
        }
        fade(to: 1)
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        fadeGeneration += 1
        let generation = fadeGeneration
        fade(to: 0) { [weak self] in
            guard let self, self.fadeGeneration == generation else { return }
            // Stopping first is what makes clearing stick: the capture drops every frame blurred
            // before the stop, so none of them can land on the window after it has been cleared.
            self.capture.stop()
            self.window.orderOut(nil)
            self.window.clear()
        }
    }

    func update(with display: DisplayInfo) {
        window.setFrame(display.frame, display: isShown)
        capture.resize(to: display.frame.size)
    }

    func teardown() {
        fadeGeneration += 1
        isShown = false
        capture.stop()
        window.orderOut(nil)
        window.clear()
        window.close()
    }

    private func fade(to alpha: CGFloat, then completion: @escaping @MainActor @Sendable () -> Void = {}) {
        // AppKit runs the completion on the main thread but types it as non-isolated.
        let onFinish: @Sendable () -> Void = { MainActor.assumeIsolated { completion() } }
        NSAnimationContext.runAnimationGroup({ context in
            // A whole display changing opacity is the motion Reduce Motion exists for.
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.window.animator().alphaValue = alpha
        }, completionHandler: onFinish)
    }
}
