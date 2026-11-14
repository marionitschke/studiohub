// Draws the app icon and writes an .iconset.
// Usage: ./build.sh --icon
//
// Same layout as the WatchDiary logo and the other hub icons (PhotoHub, TakeoutHub, FileHub,
// BackupHub, ClearHub, MusicHub): a tile in the main color at 18 % opacity over white, inside it
// a square in the full main color, and inside that only the glyph in white. VideoHub's main color
// is green; the glyph is two film frames split by a cut marker.
// Drawn in the logo's coordinates (viewBox 512, y pointing down); the logo's tile (8…504) sits on
// Apple's icon grid (824 × 824 with a 100 px margin at 1024).
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// VideoHub's main color: green.
let mainColor: UInt32 = 0x2A9D5C

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

    // Two film frames with sprocket holes, split by a cut marker.
    for left: CGFloat in [116, 276] {
        let frame = NSRect(x: left, y: 160, width: 120, height: 192)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: frame, xRadius: 16, yRadius: 16).fill()
        color(mainColor).setFill()
        // The picture window and a row of holes above and below it.
        NSBezierPath(roundedRect: NSRect(x: left + 16, y: 206, width: 88, height: 100), xRadius: 8, yRadius: 8).fill()
        for index in 0..<3 {
            let x = left + 18 + CGFloat(index) * 32
            NSBezierPath(roundedRect: NSRect(x: x, y: 174, width: 20, height: 18), xRadius: 4, yRadius: 4).fill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 320, width: 20, height: 18), xRadius: 4, yRadius: 4).fill()
        }
    }

    // Cut marker: a line with a triangle at each end.
    NSColor.white.setFill()
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
