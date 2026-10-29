import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// Renders the 1024 px app icon to PNG: render <variant> <out.png>. One variant survives from the
// exploration; the others live in git history if the icon is ever revisited.
let size: CGFloat = 1024
let variant = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
let cx = size / 2
let cy = size / 2

func symbol(_ name: String, pt: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor = .white) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: weight).applying(.init(paletteColors: [color]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else {
        fatalError("no symbol \(name)")
    }
    return image
}

func draw(_ s: NSImage, x: CGFloat, y: CGFloat, alpha: CGFloat = 1) {
    let sz = s.size
    s.draw(in: CGRect(x: x - sz.width / 2, y: y - sz.height / 2, width: sz.width, height: sz.height),
           from: .zero, operation: .sourceOver, fraction: alpha)
}

/// Renders `body` into an offscreen 1024 px bitmap and gaussian-blurs it, so a glyph can be shown
/// as it would look behind the app's own overlay. Explicit pixel size: `NSImage.lockFocus` would
/// pick up the display's 2x scale and the blur radius would land at half the intended size.
func blurred(radius: Double, _ body: () -> Void) -> NSImage {
    let px = Int(size)
    guard let bitmap = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
    body()
    NSGraphicsContext.restoreGraphicsState()
    guard let source = bitmap.makeImage() else { fatalError("blur source") }

    let filter = CIFilter.gaussianBlur()
    filter.inputImage = CIImage(cgImage: source)
    filter.radius = Float(radius)
    let extent = CGRect(x: 0, y: 0, width: size, height: size)
    guard let output = filter.outputImage,
          let result = CIContext().createCGImage(output, from: extent) else { fatalError("blur output") }
    return NSImage(cgImage: result, size: NSSize(width: size, height: size))
}

let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let inset = size * 0.1
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.224, yRadius: rect.width * 0.224)
NSColor.black.setFill(); squircle.fill()
ctx.saveGState(); squircle.addClip()

switch variant {
case "half-blur-pods":
    // The eye, sharp on the left and dissolving into blur on the right, with the AirPods beneath
    let sharp = symbol("eye.fill", pt: 470, weight: .medium)
    let eyeY = size * 0.6
    draw(blurred(radius: 34) { draw(sharp, x: cx, y: eyeY) }, x: cx, y: cy)
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: cx, height: size))
    draw(sharp, x: cx, y: eyeY)
    ctx.restoreGState()
    draw(symbol("airpods.pro", pt: 230, weight: .regular), x: cx, y: size * 0.27)
default:
    fatalError("unknown variant \(variant)")
}
ctx.restoreGState()
img.unlockFocus()

guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode") }
try! png.write(to: URL(fileURLWithPath: out))
