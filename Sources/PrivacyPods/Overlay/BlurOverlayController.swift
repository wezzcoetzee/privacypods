import AppKit

@MainActor
final class BlurOverlayController: NSObject, OverlayControlling {
    let captureEvents: AsyncStream<CaptureAvailability>
    private(set) var captureAvailability: CaptureAvailability = .available

    private let captureContinuation: AsyncStream<CaptureAvailability>.Continuation
    private let renderer = BlurRenderer()
    private var displays: [DisplayID: DisplayInfo]
    private var surfaces: [DisplayID: DisplaySurface] = [:]
    private var surfaceAvailability: [DisplayID: CaptureAvailability] = [:]
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
