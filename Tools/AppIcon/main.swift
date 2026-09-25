import AppKit

// Renders the 1024 px app icon: a dark macOS tile with the UnderPressure glyph (same
// geometry as the menubar icon) filled with an amber → orange liquid. Run through
// `Tools/render-app-icon.sh`; the output path is the first argument.

let canvas: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)   // Apple icon grid
let corner: CGFloat = 185

func srgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let c = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// Tile with a soft drop shadow.
let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)
c.saveGState()
c.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: srgb(0x000000, 0.35))
c.addPath(tilePath); c.setFillColor(srgb(0x1B1F27)); c.fillPath()
c.restoreGState()

// Tile gradient (lighter top → darker bottom) + faint top highlight.
c.saveGState()
c.addPath(tilePath); c.clip()
let bg = CGGradient(colorsSpace: space, colors: [srgb(0x323845), srgb(0x14171D)] as CFArray, locations: [0, 1])!
c.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
c.restoreGState()

// Glyph: same geometry as the menubar icon, scaled to 560 px, stroke tuned for the size.
let side: CGFloat = 560
let origin = CGPoint(x: (canvas - side) / 2, y: (canvas - side) / 2)
let g = UnderPressureIconRenderer.geometry(side: side, lineWidth: 34)
let oval = g.oval.offsetBy(dx: origin.x, dy: origin.y)
let fill: CGFloat = 0.55

c.saveGState()
c.addEllipse(in: oval); c.clip()
// Back wave: lighter, phase-shifted, slightly higher — gives the liquid depth.
func wave(amplitudeScale: CGFloat, choppiness: CGFloat, shift: CGFloat, lift: CGFloat) -> CGPath {
    var t = CGAffineTransform(translationX: origin.x - shift, y: origin.y + g.surfaceY(fill: fill) + lift)
    let path = UnderPressureIconRenderer.liquidPath(
        minX: g.oval.minX, maxX: g.oval.maxX + g.waveLength, waveLength: g.waveLength,
        amplitude: g.waveAmplitude(fill: fill, amplitudeScale: amplitudeScale),
        choppiness: choppiness, depth: g.oval.height + 10, step: 2)
    return path.copy(using: &t)!
}
c.addPath(wave(amplitudeScale: 1.5, choppiness: 0.4, shift: g.waveLength * 0.45, lift: 14))
c.setFillColor(srgb(0xC4621A)); c.fillPath()
// Front wave with amber → orange gradient.
c.addPath(wave(amplitudeScale: 1.4, choppiness: 0.6, shift: 0, lift: 0)); c.clip()
let liquid = CGGradient(colorsSpace: space, colors: [srgb(0xFFBD2E), srgb(0xFF6A1F)] as CFArray, locations: [0, 1])!
c.drawLinearGradient(liquid, start: CGPoint(x: 0, y: origin.y + g.surfaceY(fill: fill) + 20), end: CGPoint(x: 0, y: oval.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
c.restoreGState()

// Ring.
c.addEllipse(in: oval); c.setStrokeColor(srgb(0xF5F6F8)); c.setLineWidth(g.lineWidth); c.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
