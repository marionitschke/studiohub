// Draws the app icon and writes an .iconset.
// Usage: ./build.sh --icon
//
// Same layout as the WatchDiary logo and the other hub icons (PhotoHub, TakeoutHub, FileHub,
// BackupHub, ClearHub): a tile in the main color at 18 % opacity over white, inside it a square in
// the full main color, and inside that only the glyph in white. MusicHub's main color is magenta;
// the glyph is a waveform split by a cut marker.
// Drawn in the logo's coordinates (viewBox 512, y pointing down); the logo's tile (8…504) sits on
// Apple's icon grid (824 × 824 with a 100 px margin at 1024).
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// MusicHub's main color: magenta.
let mainColor: UInt32 = 0xB23BB0

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let s = CGFloat(pixels) / 1024
    let k = 824 / 496 * s
    let transform = NSAffineTransform()
    transform.translateX(by: 100 * s - 8 * k, yBy: CGFloat(pixels) - 100 * s + 8 * k)
    transform.scaleX(by: k, yBy: -k)
    transform.concat()

    // Tile: white with a shadow, the main color at 18 % opacity on top.
    let tile = NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 496, height: 496), xRadius: 112, yRadius: 112)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 16 * s
    shadow.shadowOffset = NSSize(width: 0, height: -6 * s)
    shadow.set()
    NSColor.white.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(mainColor, 0.18).setFill()
    tile.fill()

    // Square in the full main color: 86…426 with radius 68.
    color(mainColor).setFill()
    NSBezierPath(roundedRect: NSRect(x: 86, y: 86, width: 340, height: 340), xRadius: 68, yRadius: 68).fill()

    NSColor.white.setFill()

    // Waveform: three bars on each side of the cut, centred vertically.
    let bars: [(x: CGFloat, height: CGFloat)] = [
        (128, 110), (168, 200), (208, 140),
        (304, 180), (344, 120), (384, 76),
    ]
    let barWidth: CGFloat = 24
    for bar in bars {
        let rect = NSRect(x: bar.x - barWidth / 2, y: 256 - bar.height / 2, width: barWidth, height: bar.height)
        NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }

    // Cut marker: a line with a triangle at each end.
    NSBezierPath(rect: NSRect(x: 252, y: 132, width: 8, height: 248)).fill()
    let marker = NSBezierPath()
    marker.move(to: NSPoint(x: 232, y: 116))
    marker.line(to: NSPoint(x: 280, y: 116))
    marker.line(to: NSPoint(x: 256, y: 146))
    marker.close()
    marker.move(to: NSPoint(x: 232, y: 396))
    marker.line(to: NSPoint(x: 280, y: 396))
    marker.line(to: NSPoint(x: 256, y: 366))
    marker.close()
    marker.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for entry in sizes {
    try render(pixels: entry.pixels).write(to: output.appendingPathComponent("\(entry.name).png"))
}
print("Icon set written: \(output.path)")
