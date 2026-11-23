import CoreMedia
import Foundation
import ScreenCaptureKit
import os

/// `generation` is bumped on stop, resize and retry so a late `startCapture()` result or an in-flight
/// frame from a replaced launch is dropped.
@MainActor
final class DisplayCapture {
    /// Blurring downscaled frames is cheaper and harder to read than at native size; sigma is scaled to match.
    private static let maxCaptureWidth: CGFloat = 960
    private static let framesPerSecond: Int32 = 4
    /// One launch plus two retries; retrying forever would hide the failure from the user.
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

            // Excluding the app also keeps the Settings and Status windows out of the blur.
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

            // A stop or relaunch during `startCapture` would leave this stream running unowned.
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

    /// ScreenCaptureKit reports a revoked grant as a plain stream error, so read the permission instead.
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

/// One relay per `SCStream`, so it carries its launch generation as a constant. Only `sigma` is mutable, under a lock.
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
        let notify = onStopped
        let generation = generation
        let message = error.localizedDescription
        Task { @MainActor in notify(generation, message) }
    }
}
