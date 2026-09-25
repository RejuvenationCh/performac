// Scripts/make-icon.swift: draws Resources/AppIcon.icns. Run from PerformacApp/:
//
//     swift Scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
//
// The mark is the rail's gauge.with.needle on a graphite tile, on Apple's icon grid (an 824pt
// body inside 1024 with room for the shadow). Graphite, not a colour: DESIGN.md gives the app
// no brand colour, and an icon cannot follow the user's accent the way the UI does.
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tile = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    // A faint top light and a hairline edge, so the tile reads as an object on a dark Dock.
    NSGradient(starting: NSColor.white.withAlphaComponent(0.10), ending: .clear)!
        .draw(in: tile, angle: -90)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    tile.lineWidth = 2 * s
    tile.stroke()

    let config = NSImage.SymbolConfiguration(pointSize: 470 * s, weight: .medium)
        .applying(.init(hierarchicalColor: .white))
    let mark = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    let m = mark.size
    mark.draw(in: NSRect(x: body.midX - m.width / 2, y: body.midY - m.height / 2 - 8 * s,
                         width: m.width, height: m.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try render(pt).write(to: dir.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try render(pt * 2).write(to: dir.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
print("wrote \(dir.path)")
