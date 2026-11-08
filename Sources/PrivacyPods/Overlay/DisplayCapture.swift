import CoreMedia
import Foundation
import ScreenCaptureKit
import os

/// One ScreenCaptureKit stream for one display, running only while that display is blurred.
///
/// Every launch carries a generation, and `stop()`, `resize(to:)` and each retry bump it. That one
/// counter closes two races: a `startCapture()` that returns after the capture was stopped hands
/// back a live stream, which is stopped instead of left running for the lifetime of the process;
/// and a frame blurred on the capture queue before the bump is dropped instead of painted into a
/// window that has since been cleared.
///
/// A stream that fails, or that ScreenCaptureKit stops on us, is relaunched with a growing delay up
/// to `maxLaunchAttempts` times per blur session. Once those are spent the capture reports itself
/// unavailable and the overlay says so rather than freezing on a stale frame.
@MainActor
final class DisplayCapture {
    /// Frames are downscaled to at most this many pixels wide before blurring. A blur applied at a
    /// fraction of the resolution and stretched back up is both cheaper and harder to read than the
    /// same blur at native size, so the sigma is scaled to match.
    private static let maxCaptureWidth: CGFloat = 960
    /// Enough to keep the blur honest when a window moves, low enough to stay off the power graph.
    private static let framesPerSecond: Int32 = 4
    /// One launch plus two retries. A stream that will not stay up three times running is not
    /// coming back on its own, and retrying forever would hide the failure from the user.
    private static let maxLaunchAttempts = 3
    private static let firstRetryDelay: Duration = .milliseconds(500)

    private let display: DisplayID
    private let renderer: BlurRenderer
    private let queue: DispatchQueue
    private let onFrame: @MainActor @Sendable (CGImage) -> Void
    private let onAvailability: @MainActor @Sendable (CaptureAvailability) -> Void

    private var pointSize: CGSize
    private var radius: Double = 0
    private var isRunning = false
    private var stream: SCStream?
    private var relay: FrameRelay?
    private var launchTask: Task<Void, Never>?
    private var generation = 0
    private var failures = 0
    private var availability: CaptureAvailability = .available

    init(
        display: DisplayID,
        pointSize: CGSize,
        renderer: BlurRenderer,
        onFrame: @escaping @MainActor @Sendable (CGImage) -> Void,
        onAvailability: @escaping @MainActor @Sendable (CaptureAvailability) -> Void
    ) {
        self.display = display
        self.pointSize = pointSize
        self.renderer = renderer
        self.onFrame = onFrame
        self.onAvailability = onAvailability
        queue = DispatchQueue(label: "dev.wesley.privacypods.capture.\(display.rawValue)", qos: .userInitiated)
    }

    /// Idempotent: calling it again while running only updates the blur strength. A session that
    /// has already spent its attempts stays unavailable until it is stopped and started again.
    func start(radius: Double) {
        self.radius = radius
        relay?.sigma = capturedSigma
        guard !isRunning else { return }
        isRunning = true
        failures = 0
        launch(after: nil)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        launchTask?.cancel()
        launchTask = nil
        relay = nil
        report(.available)
        guard let running = stream else { return }
        stream = nil
        Task { try? await running.stopCapture() }
    }

    /// The display was rearranged or changed resolution, so the capture geometry is stale.
    func resize(to pointSize: CGSize) {
        guard pointSize != self.pointSize else { return }
        self.pointSize = pointSize
        guard isRunning else { return }
        let radius = self.radius
        stop()
        start(radius: radius)
    }

    private var captureScale: CGFloat {
        min(1, Self.maxCaptureWidth / max(pointSize.width, 1))
    }

    private var capturedSigma: Double {
        radius * Double(captureScale)
    }

    /// True while `generation` is still the one the caller was launched under.
    private func isCurrent(_ generation: Int) -> Bool {
        isRunning && generation == self.generation
    }

    private func launch(after delay: Duration?) {
        generation &+= 1
        let generation = self.generation
        launchTask?.cancel()
        launchTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.run(generation: generation)
        }
    }

    private func run(generation: Int) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard isCurrent(generation) else { return }
            guard let target = content.displays.first(where: { DisplayID($0.displayID) == display }) else {
                Log.overlay.error("No shareable display for \(self.display, privacy: .public).")
                retry(reason: .captureFailed)
                return
            }

            // `sharingType = .none` already keeps the overlay out of the frame; excluding the app
            // outright also keeps the settings and Status windows out of the blur.
            let ownApplications = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let filter = SCContentFilter(
                display: target,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )

            let relay = FrameRelay(
                display: display,
                renderer: renderer,
                generation: generation,
                onFrame: { [weak self] generation, image in self?.deliver(image, generation: generation) },
                onStopped: { [weak self] generation, message in self?.streamStopped(message, generation: generation) }
            )
            relay.sigma = capturedSigma

            let stream = SCStream(filter: filter, configuration: configuration(), delegate: relay)
            try stream.addStreamOutput(relay, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()

            // A stop or a relaunch that landed while `startCapture` was in flight would otherwise
            // leave this stream running with nobody holding it.
            guard isCurrent(generation) else {
                try? await stream.stopCapture()
                return
            }
            self.relay = relay
            self.stream = stream
            report(.available)
        } catch {
            Log.overlay.error("Capture of \(self.display, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            guard isCurrent(generation) else { return }
            retry(reason: currentReason())
        }
    }

    private func deliver(_ image: CGImage, generation: Int) {
        guard isCurrent(generation) else { return }
        onFrame(image)
    }

    private func streamStopped(_ message: String, generation: Int) {
        guard isCurrent(generation) else { return }
        Log.overlay.error("Capture of \(self.display, privacy: .public) stopped: \(message, privacy: .public)")
        retry(reason: currentReason())
    }

    private func retry(reason: CaptureAvailability.Reason) {
        stream = nil
        relay = nil
        failures += 1
        guard failures < Self.maxLaunchAttempts else {
            Log.overlay.error("Giving up on capture of \(self.display, privacy: .public) after \(Self.maxLaunchAttempts, privacy: .public) attempts.")
            report(.unavailable(reason))
            return
        }
        launch(after: Self.firstRetryDelay * (1 << (failures - 1)))
    }

    /// ScreenCaptureKit reports a revoked or missing grant as an ordinary stream error, so the
    /// permission itself is the only reliable way to tell the two failures apart.
    private func currentReason() -> CaptureAvailability.Reason {
        ScreenRecordingPermission.status == .granted ? .captureFailed : .screenRecordingDenied
    }

    private func report(_ availability: CaptureAvailability) {
        guard availability != self.availability else { return }
        self.availability = availability
        onAvailability(availability)
    }

    private func configuration() -> SCStreamConfiguration {
        let scale = captureScale
        let configuration = SCStreamConfiguration()
        configuration.width = Int((pointSize.width * scale).rounded())
        configuration.height = Int((pointSize.height * scale).rounded())
        configuration.scalesToFit = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return configuration
    }
}

/// The only object that lives on the capture queue, and it belongs to exactly one `SCStream`.
///
/// It blurs each frame there and hands on a `CGImage`, which is `Sendable` unlike the pixel buffer
/// it was rendered from. One relay per stream is what lets it carry its launch generation as a
/// constant, so a frame or a stop from a stream that has already been replaced is recognisable as
/// stale on the main actor. Safe to share: every stored property is immutable except the blur
/// sigma, which the main actor writes and the capture queue reads under a lock.
private final class FrameRelay: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let display: DisplayID
    private let renderer: BlurRenderer
    private let generation: Int
    private let onFrame: @MainActor @Sendable (Int, CGImage) -> Void
    private let onStopped: @MainActor @Sendable (Int, String) -> Void
    private let sigmaStorage = OSAllocatedUnfairLock(initialState: 0.0)

    var sigma: Double {
        get { sigmaStorage.withLock { $0 } }
        set { sigmaStorage.withLock { $0 = newValue } }
    }

    init(
        display: DisplayID,
        renderer: BlurRenderer,
        generation: Int,
        onFrame: @escaping @MainActor @Sendable (Int, CGImage) -> Void,
        onStopped: @escaping @MainActor @Sendable (Int, String) -> Void
    ) {
        self.display = display
        self.renderer = renderer
        self.generation = generation
        self.onFrame = onFrame
        self.onStopped = onStopped
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // An idle display sends a status-only buffer with no image; the last frame stays on screen.
        guard type == .screen, let frame = sampleBuffer.imageBuffer else { return }
        guard let image = renderer.blur(frame, sigma: sigma) else { return }
        let deliver = onFrame
        let generation = generation
        Task { @MainActor in deliver(generation, image) }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        // The error is not `Sendable`; its description is all the main actor needs, since the
        // reason worth acting on is read from the permission rather than from the error.
        let notify = onStopped
        let generation = generation
        let message = error.localizedDescription
        Task { @MainActor in notify(generation, message) }
    }
}
