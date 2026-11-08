import AppKit

/// Overlay's implementation of `OverlayControlling`: one blur window per display, created the
/// first time that display is asked for and torn down when it is unplugged.
///
/// `setBlurred` is absolute rather than incremental, so the whole controller is a projection of the
/// last request onto the currently attached displays. A display that disappears while blurred takes
/// its window with it; if it comes back, the next request rebuilds it.
///
/// It also aggregates what each display's capture reports about itself, because "the screen is
/// covered but not blurred" is a state the user has to be able to see from the menu bar.
@MainActor
final class BlurOverlayController: NSObject, OverlayControlling {
    /// Single-consumer, in the house style: emits on change only. Read `captureAvailability` for
    /// the value at subscribe time.
    let captureEvents: AsyncStream<CaptureAvailability>
    private(set) var captureAvailability: CaptureAvailability = .available

    private let captureContinuation: AsyncStream<CaptureAvailability>.Continuation
    private let renderer = BlurRenderer()
    private var displays: [DisplayID: DisplayInfo]
    private var surfaces: [DisplayID: DisplaySurface] = [:]
    private var surfaceAvailability: [DisplayID: CaptureAvailability] = [:]
    /// The last request from the engine. `nil` until the first `setBlurred`, which is the only
    /// thing that can establish a radius.
    private var request: (displays: Set<DisplayID>, radius: Double, notices: [DisplayID: String])?

    override init() {
        (captureEvents, captureContinuation) = AsyncStream.makeStream()
        displays = Self.attachedDisplays()
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        captureContinuation.finish()
    }

    func setBlurred(_ displays: Set<DisplayID>, radius: Double, notices: [DisplayID: String]) {
        request = (displays, radius, notices)
        apply()
    }

    func teardown() {
        request = nil
        for surface in surfaces.values {
            surface.teardown()
        }
        surfaces.removeAll()
        surfaceAvailability.removeAll()
        publishAvailability()
    }

    private func apply() {
        let wanted = request.map { $0.displays.intersection(displays.keys) } ?? []
        let radius = request?.radius ?? 0

        for id in wanted {
            surface(for: id)?.show(radius: radius, notice: request?.notices[id])
        }
        for (id, surface) in surfaces where !wanted.contains(id) {
            surface.hide()
        }
    }

    private func surface(for id: DisplayID) -> DisplaySurface? {
        if let existing = surfaces[id] { return existing }
        guard let display = displays[id] else { return nil }
        let surface = DisplaySurface(display: display, renderer: renderer) { [weak self] reporter, availability in
            self?.surfaceAvailability[reporter] = availability
            self?.publishAvailability()
        }
        surfaces[id] = surface
        return surface
    }

    private func publishAvailability() {
        let combined = Self.combined(surfaceAvailability.values)
        guard combined != captureAvailability else { return }
        captureAvailability = combined
        captureContinuation.yield(combined)
    }

    /// The worst news any display has. A missing permission outranks a failed stream because it is
    /// the one the user can do something about.
    nonisolated static func combined(_ availabilities: some Sequence<CaptureAvailability>) -> CaptureAvailability {
        var anyFailed = false
        for availability in availabilities {
            switch availability {
            case .unavailable(.screenRecordingDenied): return .unavailable(.screenRecordingDenied)
            case .unavailable(.captureFailed): anyFailed = true
            case .available: continue
            }
        }
        return anyFailed ? .unavailable(.captureFailed) : .available
    }

    @objc private func screenParametersChanged() {
        displays = Self.attachedDisplays()
        for (id, surface) in surfaces {
            if let display = displays[id] {
                surface.update(with: display)
            } else {
                surface.teardown()
                surfaces[id] = nil
                surfaceAvailability[id] = nil
            }
        }
        publishAvailability()
        apply()
    }

    private static func attachedDisplays() -> [DisplayID: DisplayInfo] {
        Dictionary(DisplayInfo.current().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
