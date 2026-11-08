// Writes the SF Symbols the App Store slides draw in their mock menu bar, white on transparent.
// Usage: swift symbols.swift <output-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let names = ["eye", "eye.slash", "eye.half.closed", "pause.circle", "eye.trianglebadge.exclamationmark",
             "wifi", "battery.75percent"]
for name in names {
    let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
        print("missing \(name)"); continue
    }
    let size = symbol.size
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    symbol.draw(in: NSRect(origin: .zero, size: size))
    NSColor.white.set()
    NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: out.appending(path: "\(name).png"))
}
