// Renders the app icon (a rounded-square tile with a sunburst) into an .iconset.
// Usage: swift scripts/make_icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func hue(_ f: Double) -> Double { (0.98 + f * 0.85).truncatingRemainder(dividingBy: 1) }

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 tile with continuous corners.
    let inset = s * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.14, alpha: 1).setFill()
    tilePath.fill()
    ctx.restoreGState()
    tilePath.addClip()
    let grad = NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.24, alpha: 1),
                                   NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.09, alpha: 1)])!
    grad.draw(in: tilePath, angle: -90)

    let c = CGPoint(x: s / 2, y: s / 2)
    let R = tile.width * 0.40, hole = R * 0.32
    let ringW = (R - hole) / 3
    // Hand-tuned slices so the icon reads as a sunburst at any size.
    let rings: [[(Double, Double)]] = [
        [(0, 0.42), (0.42, 0.68), (0.68, 0.86), (0.86, 1)],
        [(0, 0.25), (0.25, 0.40), (0.42, 0.60), (0.68, 0.80), (0.86, 0.95)],
        [(0, 0.14), (0.25, 0.34), (0.42, 0.52), (0.68, 0.75)],
    ]
    let gap = max(1, s * 0.006)
    for (d, ring) in rings.enumerated() {
        let inner = hole + CGFloat(d) * ringW + gap / 2, outer = hole + CGFloat(d + 1) * ringW - gap / 2
        for (a0, a1) in ring {
            let mid = (inner + outer) / 2
            let pad = Double(gap / 2 / mid)
            let start = 90 - (a0 * 360 + pad * 180 / .pi), end = 90 - (a1 * 360 - pad * 180 / .pi)
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: outer, startAngle: start, endAngle: end, clockwise: true)
            p.appendArc(withCenter: c, radius: inner, startAngle: end, endAngle: start, clockwise: false)
            p.close()
            NSColor(calibratedHue: hue((a0 + a1) / 2), saturation: 0.72 - Double(d) * 0.12,
                    brightness: 0.96 - Double(d) * 0.02, alpha: 1).setFill()
            p.fill()
        }
    }
    // Glassy centre.
    let dot = NSBezierPath(ovalIn: CGRect(x: c.x - hole + gap, y: c.y - hole + gap,
                                          width: 2 * (hole - gap), height: 2 * (hole - gap)))
    NSColor.white.withAlphaComponent(0.14).setFill(); dot.fill()
    // Top sheen.
    let sheen = NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
    sheen.draw(in: CGRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * scale).write(to: out.appending(path: name))
    }
}
