import CoreImage
import CoreVideo
import Metal

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

    /// Returns a `CGImage` because the pixel buffer is not `Sendable` and is recycled on return.
    /// Clamping first stops the edges bleeding into transparency (a dark frame).
    func blur(_ frame: CVPixelBuffer, sigma: Double) -> CGImage? {
        let source = CIImage(cvPixelBuffer: frame)
        let blurred =
            source
            .clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: source.extent)
        return context.createCGImage(blurred, from: source.extent)
    }
}
