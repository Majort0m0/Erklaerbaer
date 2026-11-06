// Draws the app icon ("Fokus": zoom frame, cursor with click rings, record dot) and writes
// Resources/AppIcon.icns. Run: swift scripts/make-icon.swift Resources/AppIcon.icns
// (scripts/build-app.sh does this when the .icns is missing). `--png <file>` writes a 1024 px PNG.
import AppKit
import CoreGraphics

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

/// The icon at `px` pixels (drawn on a 1024 grid, scaled).
func icon(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(px) / 1024
    // Top-left origin on the 1024 grid.
    ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: k, y: -k)
    let space = CGColorSpace(name: CGColorSpace.sRGB)

    // Body (macOS grid: 824 × 824 at 100, corner radius 185) with drop shadow and gradient.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(shape); ctx.setFillColor(rgb(0.11, 0.13, 0.32)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: [rgb(0.11, 0.13, 0.32), rgb(0.42, 0.22, 0.75)] as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])
    let light = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(light, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.midY), options: [])
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 183.5, cornerHeight: 183.5, transform: nil))
    ctx.setStrokeColor(rgb(1, 1, 1, 0.18)); ctx.setLineWidth(3); ctx.strokePath()

    // Zoom frame: four yellow corner brackets.
    let frame = CGRect(x: 230, y: 250, width: 564, height: 470)
    ctx.setStrokeColor(rgb(1, 0.82, 0.18)); ctx.setLineWidth(30); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    let L: CGFloat = 120
    for (p, dx, dy) in [(CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0), (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0),
                        (CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0), (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0)] {
        ctx.move(to: CGPoint(x: p.x, y: p.y + CGFloat(dy) * L))
        ctx.addLine(to: p)
        ctx.addLine(to: CGPoint(x: p.x + CGFloat(dx) * L, y: p.y))
        ctx.strokePath()
    }

    // Click rings and the cursor.
    let c = CGPoint(x: 470, y: 450)
    for (r, a) in [(120.0, 0.18), (82.0, 0.35)] as [(CGFloat, CGFloat)] {
        ctx.setStrokeColor(rgb(1, 1, 1, a)); ctx.setLineWidth(14)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
    let pts: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 20), CGPoint(x: 5, y: 15.5), CGPoint(x: 8.5, y: 23.5),
                          CGPoint(x: 11.8, y: 22), CGPoint(x: 8.4, y: 14.2), CGPoint(x: 14.5, y: 14.2)]
    let cursor = CGMutablePath()
    cursor.addLines(between: pts.map { CGPoint(x: c.x + $0.x * 11, y: c.y + $0.y * 11) })
    cursor.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 14, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(cursor); ctx.setFillColor(rgb(1, 1, 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(cursor); ctx.setStrokeColor(rgb(0.1, 0.1, 0.2)); ctx.setLineWidth(1.7 * 11); ctx.setLineJoin(.round); ctx.strokePath()

    // Record dot with a white ring.
    let d = CGPoint(x: frame.maxX - 70, y: frame.minY + 70), r: CGFloat = 30
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 12, color: rgb(1, 0.2, 0.2, 0.6))
    ctx.setFillColor(rgb(1, 0.23, 0.23)); ctx.fillEllipse(in: CGRect(x: d.x - r, y: d.y - r, width: 2 * r, height: 2 * r))
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(1, 1, 1, 0.9)); ctx.setLineWidth(r * 0.22)
    ctx.strokeEllipse(in: CGRect(x: d.x - r, y: d.y - r, width: 2 * r, height: 2 * r).insetBy(dx: -r * 0.11, dy: -r * 0.11))
    return ctx.makeImage()!
}

func png(_ image: CGImage) -> Data { NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])! }

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--png" {
    try! png(icon(1024)).write(to: URL(fileURLWithPath: args[2]))
    exit(0)
}
let out = args[1]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! png(icon(px)).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run()
p.waitUntilExit()
exit(p.terminationStatus)
