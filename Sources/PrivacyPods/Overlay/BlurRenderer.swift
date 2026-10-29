import CoreImage
import CoreVideo
import Metal

/// Turns a captured frame into an unreadable one.
///
/// `CIContext` is thread-safe and expensive to build, so one renderer is shared by every display's
/// capture queue. The blur itself runs on the GPU; reading the result back as a `CGImage` is what
/// lets it cross to the main actor, since the pixel buffer it came from is not `Sendable` and is
/// recycled the moment this returns.
struct BlurRenderer: Sendable {
    private let context: CIContext

    init() {
        if let queue = MTLCreateSystemDefaultDevice()?.makeCommandQueue() {
            context = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
        } else {
            Log.overlay.error("No Metal command queue; falling back to the default CIContext.")
            context = CIContext()
        }
    }

    /// `sigma` is in captured pixels, so callers scale the user's point radius by however far the
    /// capture was downscaled. Clamping before the blur stops the edges bleeding into transparency,
    /// which would otherwise draw a dark frame around the display.
    func blur(_ frame: CVPixelBuffer, sigma: Double) -> CGImage? {
        let source = CIImage(cvPixelBuffer: frame)
        let blurred = source
            .clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: source.extent)
        return context.createCGImage(blurred, from: source.extent)
    }
}
