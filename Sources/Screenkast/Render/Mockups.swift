import AppKit
import CoreImage

/// Where the screen lies in a scene and which part of the video it shows.
struct MockupPlacement: Codable, Equatable {
    /// Screen (with its device): shift as a fraction of the picture (right and up are positive), size.
    var x = 0.0
    var y = 0.0
    var scale = 1.0
    /// Video inside the screen: enlargement (1: all of it) and which part shows (−1 … 1, right and up).
    var videoScale = 1.0
    var videoX = 0.0
    var videoY = 0.0
}

/// Scenes the video can be shown in instead of a background. All drawn here, without pictures,
/// to fit any output format and any shape of video: the device is built around the screen.
enum MockupKind: String, Codable, CaseIterable, Identifiable {
    case laptop, tablet, tv, theater, cinema, frame
    var id: String { rawValue }

    var label: String {
        switch self {
        case .laptop: return "Laptop"
        case .tablet: return "Tablet"
        case .tv: return "Fernseher"
        case .theater: return "Theater"
        case .cinema: return "Kino"
        case .frame: return "Bilderrahmen"
        }
    }

    /// The part of the output the screen may use (fractions, origin bottom-left).
    private func area(portrait: Bool) -> CGRect {
        // The screen is the main thing: little margin, and around the middle of the picture.
        switch (self, portrait) {
        case (.laptop, false): return CGRect(x: 0.11, y: 0.13, width: 0.78, height: 0.80)
        case (.laptop, true): return CGRect(x: 0.04, y: 0.31, width: 0.92, height: 0.42)
        case (.tablet, false): return CGRect(x: 0.08, y: 0.06, width: 0.84, height: 0.88)
        case (.tablet, true): return CGRect(x: 0.05, y: 0.18, width: 0.90, height: 0.64)
        case (.tv, false): return CGRect(x: 0.08, y: 0.19, width: 0.84, height: 0.73)
        case (.tv, true): return CGRect(x: 0.04, y: 0.34, width: 0.92, height: 0.38)
        case (.theater, false): return CGRect(x: 0.14, y: 0.18, width: 0.72, height: 0.66)
        case (.theater, true): return CGRect(x: 0.12, y: 0.34, width: 0.76, height: 0.36)
        case (.cinema, false): return CGRect(x: 0.05, y: 0.17, width: 0.90, height: 0.79)
        case (.cinema, true): return CGRect(x: 0.03, y: 0.35, width: 0.94, height: 0.36)
        case (.frame, false): return CGRect(x: 0.10, y: 0.13, width: 0.80, height: 0.74)
        case (.frame, true): return CGRect(x: 0.09, y: 0.24, width: 0.82, height: 0.52)
        }
    }

    /// Where the video goes in an output of this size (origin bottom-left).
    /// The shape of the screen for a video of this shape.
    func screenAspect(video: CGFloat) -> CGFloat { self == .tablet ? (video >= 1 ? 4.0 / 3.0 : 3.0 / 4.0) : video }

    /// Enlargement of the video at which it fills the screen without bars.
    func fillScale(video: CGFloat) -> Double {
        let screen = screenAspect(video: video)
        return Double(max(screen / video, video / screen))
    }

    /// Where the screen goes, moved and sized as the user placed it (always inside the picture).
    func screen(out: CGSize, aspect video: CGFloat, placement p: MockupPlacement) -> CGRect {
        let base = screen(out: out, aspect: video)
        let k = min(max(0.4, CGFloat(p.scale)), min(out.width * 0.98 / base.width, out.height * 0.98 / base.height))
        let w = base.width * k, h = base.height * k
        let cx = min(max(w / 2 + 2, base.midX + CGFloat(p.x) * out.width), out.width - w / 2 - 2)
        let cy = min(max(h / 2 + 2, base.midY + CGFloat(p.y) * out.height), out.height - h / 2 - 2)
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// The area the video is fitted into: the screen, or more of it when the video is enlarged.
    func videoRegion(screen: CGRect, placement p: MockupPlacement) -> CGRect {
        let k = max(1, CGFloat(p.videoScale))
        let w = screen.width * k, h = screen.height * k
        return CGRect(x: screen.midX - w / 2 + CGFloat(p.videoX) * (w - screen.width) / 2,
                      y: screen.midY - h / 2 + CGFloat(p.videoY) * (h - screen.height) / 2, width: w, height: h)
    }

    func screen(out: CGSize, aspect videoAspect: CGFloat) -> CGRect {
        // A tablet has its own 4:3 screen, turned the way the video is; other devices fit the video.
        let aspect = screenAspect(video: videoAspect)
        let a = area(portrait: out.height > out.width)
        let box = CGRect(x: a.minX * out.width, y: a.minY * out.height, width: a.width * out.width, height: a.height * out.height)
        let k = min(box.width / max(0.01, aspect), box.height)
        let w = k * aspect, h = k
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    /// One drawing unit of a scene: everything grows with the screen.
    static func unit(_ screen: CGRect) -> CGFloat { sqrt(screen.width * screen.height) / 760 }

    func cornerRadius(screen: CGRect) -> CGFloat {
        let u = Self.unit(screen)
        switch self {
        case .laptop: return 5 * u
        case .tablet: return 12 * u
        case .tv: return 2 * u
        case .theater, .cinema, .frame: return 0
        }
    }
}

/// Draws the scenes.
enum MockupScene {
    static func image(_ kind: MockupKind, size: CGSize, screen: CGRect, placeholder: Bool = false) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let p = Painter(c: c, size: size, screen: screen)
        switch kind {
        case .laptop: p.laptop()
        case .tablet: p.tablet()
        case .tv: p.tv()
        case .theater: p.theater()
        case .cinema: p.cinema()
        case .frame: p.pictureFrame()
        }
        // The screen itself: black under the video (a clip of another shape leaves bars).
        let radius = kind.cornerRadius(screen: screen)
        c.addPath(CGPath(roundedRect: screen, cornerWidth: radius, cornerHeight: radius, transform: nil))
        c.setFillColor(placeholder ? rgb(0.30, 0.42, 0.72) : rgb(0, 0, 0))
        c.fillPath()
        return c.makeImage()
    }

    /// Small picture for the inspector.
    @MainActor
    static func thumbnail(_ kind: MockupKind) -> NSImage? {
        if let cached = thumbnails[kind] { return cached }
        let size = CGSize(width: 320, height: 180)
        guard let cg = image(kind, size: size, screen: kind.screen(out: size, aspect: 16.0 / 10), placeholder: true) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: 160, height: 90))
        thumbnails[kind] = image
        return image
    }
    @MainActor private static var thumbnails: [MockupKind: NSImage] = [:]

    fileprivate static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

/// Repeatable random numbers: a scene looks the same in every frame and every export.
private struct Dice {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 2654435761 &+ 88172645463325252 }
    mutating func next() -> CGFloat {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return CGFloat(state % 10_000) / 10_000
    }
}

private struct Painter {
    let c: CGContext
    let size: CGSize
    let screen: CGRect
    var W: CGFloat { size.width }
    var H: CGFloat { size.height }
    var u: CGFloat { MockupKind.unit(screen) }

    private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { MockupScene.rgb(r, g, b, a) }

    // MARK: Tools

    private func fill(_ rect: CGRect, _ color: CGColor) {
        c.setFillColor(color)
        c.fill(rect)
    }

    private func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        let r = min(radius, min(rect.width, rect.height) / 2)
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    private func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
    }

    /// Fills `path` with a gradient from `a` to `b`.
    private func fill(_ path: CGPath, from a: CGPoint, to b: CGPoint, _ colors: [CGColor], _ locations: [CGFloat]? = nil) {
        c.saveGState()
        c.addPath(path)
        c.clip()
        c.drawLinearGradient(gradient(colors, locations), start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }

    private func vertical(_ rect: CGRect, top: CGColor, bottom: CGColor) {
        fill(CGPath(rect: rect, transform: nil), from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.minY), [top, bottom])
    }

    private func glow(at p: CGPoint, radius: CGFloat, _ color: CGColor) {
        c.drawRadialGradient(gradient([color, color.copy(alpha: 0)!]), startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
    }

    private func shadowed(blur: CGFloat, offset: CGSize = .zero, color: CGColor? = nil, _ draw: () -> Void) {
        c.saveGState()
        c.setShadow(offset: offset, blur: blur, color: color ?? rgb(0, 0, 0, 0.45))
        draw()
        c.restoreGState()
    }

    /// A surface of wood: grain lines along the width (or height).
    private func wood(_ rect: CGRect, base: (CGFloat, CGFloat, CGFloat), dark: CGFloat = 0.72, vertical isVertical: Bool = false, seed: UInt64) {
        guard rect.width > 0, rect.height > 0 else { return }
        c.saveGState()
        c.clip(to: rect)
        var dice = Dice(seed)
        let (r, g, b) = base
        vertical(rect, top: rgb(r, g, b), bottom: rgb(r * 0.86, g * 0.84, b * 0.82))
        let across = isVertical ? rect.width : rect.height
        let along = isVertical ? rect.height : rect.width
        let lines = min(900, Int(across / max(0.6, 2.4 * u)))
        c.setLineCap(.round)
        for i in 0..<lines {
            let t = CGFloat(i) / CGFloat(max(1, lines)) * across + dice.next() * 3 * u
            let wave = dice.next() * 7 * u, phase = dice.next() * 6, period = (0.6 + dice.next()) * along / 2.2
            let shade = dark + dice.next() * (1.08 - dark)
            let path = CGMutablePath()
            var s: CGFloat = -10
            var first = true
            while s < along + 20 {
                let o = t + sin(s / period * .pi * 2 + phase) * wave
                let q = isVertical ? CGPoint(x: rect.minX + o, y: rect.minY + s) : CGPoint(x: rect.minX + s, y: rect.minY + o)
                if first { path.move(to: q); first = false } else { path.addLine(to: q) }
                s += max(14, along / 40)
            }
            c.addPath(path)
            c.setStrokeColor(rgb(r * shade, g * shade, b * shade, 0.30 + dice.next() * 0.35))
            c.setLineWidth((0.5 + dice.next() * 1.6) * u)
            c.strokePath()
        }
        c.restoreGState()
    }

    /// Darker towards the corners.
    private func vignette(_ strength: CGFloat) {
        let center = CGPoint(x: W / 2, y: H / 2)
        c.drawRadialGradient(gradient([rgb(0, 0, 0, 0), rgb(0, 0, 0, strength)], [0.45, 1]),
                             startCenter: center, startRadius: 0, endCenter: center, endRadius: hypot(W, H) / 2, options: [.drawsAfterEndLocation])
    }

    private func plant(baseX x: CGFloat, baseY y: CGFloat, height: CGFloat, seed: UInt64) {
        var dice = Dice(seed)
        let potW = height * 0.40, potH = height * 0.30
        let leaves = 13
        for i in 0..<leaves {
            let f = CGFloat(i) / CGFloat(leaves - 1)
            let angle = (-1.05 + 2.1 * f + (dice.next() - 0.5) * 0.25)
            let length = height * (0.42 + 0.34 * (1 - abs(f - 0.5) * 1.5) + dice.next() * 0.08)
            c.saveGState()
            c.translateBy(x: x, y: y + potH * 0.9)
            c.rotate(by: -angle)
            let leaf = CGMutablePath()
            leaf.move(to: .zero)
            leaf.addQuadCurve(to: CGPoint(x: 0, y: length), control: CGPoint(x: length * 0.20, y: length * 0.55))
            leaf.addQuadCurve(to: .zero, control: CGPoint(x: -length * 0.20, y: length * 0.55))
            let g = 0.40 + dice.next() * 0.18
            fill(leaf, from: CGPoint(x: -length * 0.2, y: 0), to: CGPoint(x: length * 0.2, y: length), [rgb(0.13, g * 0.8, 0.22), rgb(0.26, g + 0.14, 0.32)])
            c.restoreGState()
        }
        let pot = CGMutablePath()
        pot.move(to: CGPoint(x: x - potW / 2, y: y + potH))
        pot.addLine(to: CGPoint(x: x + potW / 2, y: y + potH))
        pot.addLine(to: CGPoint(x: x + potW * 0.36, y: y))
        pot.addLine(to: CGPoint(x: x - potW * 0.36, y: y))
        pot.closeSubpath()
        fill(pot, from: CGPoint(x: x - potW / 2, y: y), to: CGPoint(x: x + potW / 2, y: y), [rgb(0.86, 0.83, 0.78), rgb(0.97, 0.95, 0.91), rgb(0.72, 0.68, 0.63)], [0, 0.4, 1])
    }

    // MARK: Laptop on a desk

    func laptop() {
        let lid = CGRect(x: screen.minX - 15 * u, y: screen.minY - 30 * u, width: screen.width + 30 * u, height: screen.height + 45 * u)
        let base = CGRect(x: lid.minX - 40 * u, y: lid.minY - 15 * u, width: lid.width + 80 * u, height: 15 * u)
        let deskTop = base.minY + 34 * u

        vertical(CGRect(x: 0, y: deskTop, width: W, height: H - deskTop), top: rgb(0.86, 0.84, 0.80), bottom: rgb(0.76, 0.72, 0.66))
        // Window light across the wall.
        let light = CGMutablePath()
        light.move(to: CGPoint(x: W * 0.05, y: H))
        light.addLine(to: CGPoint(x: W * 0.42, y: H))
        light.addLine(to: CGPoint(x: W * 0.12, y: deskTop))
        light.addLine(to: CGPoint(x: -W * 0.25, y: deskTop))
        light.closeSubpath()
        c.addPath(light)
        c.setFillColor(rgb(1, 0.98, 0.92, 0.20))
        c.fillPath()

        wood(CGRect(x: 0, y: 0, width: W, height: deskTop), base: (0.66, 0.46, 0.29), seed: 11)
        fill(CGRect(x: 0, y: deskTop - 2 * u, width: W, height: 2 * u), rgb(1, 0.92, 0.80, 0.35))

        // Things on the desk, where there is room.
        let room = base.minX
        if room > 70 * u {
            plant(baseX: room * 0.48, baseY: base.minY + 4 * u, height: min(330 * u, screen.height * 0.72, room * 1.7), seed: 3)
        }
        if W - base.maxX > 100 * u { mug(x: base.maxX + (W - base.maxX) * 0.46, y: base.minY + 2 * u) }

        // Contact shadow.
        c.saveGState()
        c.setBlendMode(.multiply)
        glowEllipse(CGRect(x: base.minX - 30 * u, y: base.minY - 26 * u, width: base.width + 60 * u, height: 44 * u), rgb(0.18, 0.11, 0.06, 0.75))
        c.restoreGState()

        // Lid.
        shadowed(blur: 34 * u, offset: CGSize(width: 0, height: 4 * u)) {
            c.addPath(rounded(lid, 18 * u))
            c.setFillColor(rgb(0.07, 0.07, 0.08))
            c.fillPath()
        }
        c.addPath(rounded(lid.insetBy(dx: 0.7 * u, dy: 0.7 * u), 17.5 * u))
        c.setStrokeColor(rgb(0.46, 0.47, 0.50))
        c.setLineWidth(1.4 * u)
        c.strokePath()
        c.setFillColor(rgb(0.20, 0.21, 0.24))
        c.fillEllipse(in: CGRect(x: lid.midX - 3 * u, y: screen.maxY + 5 * u, width: 6 * u, height: 6 * u))

        // Base with the groove for the thumb.
        let body = CGMutablePath()
        body.move(to: CGPoint(x: base.minX, y: base.maxY))
        body.addLine(to: CGPoint(x: base.maxX, y: base.maxY))
        body.addQuadCurve(to: CGPoint(x: base.maxX - 22 * u, y: base.minY), control: CGPoint(x: base.maxX - 2 * u, y: base.minY))
        body.addLine(to: CGPoint(x: base.minX + 22 * u, y: base.minY))
        body.addQuadCurve(to: CGPoint(x: base.minX, y: base.maxY), control: CGPoint(x: base.minX + 2 * u, y: base.minY))
        body.closeSubpath()
        fill(body, from: CGPoint(x: 0, y: base.maxY), to: CGPoint(x: 0, y: base.minY), [rgb(0.90, 0.90, 0.92), rgb(0.70, 0.71, 0.74), rgb(0.48, 0.49, 0.52)], [0, 0.55, 1])
        c.addPath(rounded(CGRect(x: base.midX - 62 * u, y: base.maxY - 7 * u, width: 124 * u, height: 7 * u), 3.5 * u))
        c.setFillColor(rgb(0.55, 0.56, 0.59))
        c.fillPath()
    }

    private func glowEllipse(_ rect: CGRect, _ color: CGColor) {
        c.saveGState()
        c.translateBy(x: rect.midX, y: rect.midY)
        c.scaleBy(x: 1, y: rect.height / max(1, rect.width))
        glow(at: .zero, radius: rect.width / 2, color)
        c.restoreGState()
    }

    private func mug(x: CGFloat, y: CGFloat) {
        let w = 74 * u, h = 84 * u
        c.saveGState()
        c.setBlendMode(.multiply)
        glowEllipse(CGRect(x: x - w * 0.9, y: y - 14 * u, width: w * 1.8, height: 28 * u), rgb(0.2, 0.12, 0.07, 0.65))
        c.restoreGState()
        c.setStrokeColor(rgb(0.86, 0.85, 0.82))
        c.setLineWidth(10 * u)
        c.strokeEllipse(in: CGRect(x: x + w * 0.34, y: y + h * 0.26, width: w * 0.50, height: h * 0.46))
        let body = rounded(CGRect(x: x - w / 2, y: y, width: w, height: h), 12 * u)
        fill(body, from: CGPoint(x: x - w / 2, y: 0), to: CGPoint(x: x + w / 2, y: 0), [rgb(0.80, 0.79, 0.76), rgb(0.99, 0.98, 0.96), rgb(0.72, 0.70, 0.67)], [0, 0.38, 1])
    }

    // MARK: Tablet on a table (seen from above)

    func tablet() {
        wood(CGRect(origin: .zero, size: size), base: (0.58, 0.39, 0.24), seed: 23)
        // Boards.
        var y = H * 0.08
        while y < H {
            fill(CGRect(x: 0, y: y, width: W, height: 1.6 * u), rgb(0.16, 0.09, 0.05, 0.55))
            y += max(150 * u, H * 0.27)
        }
        glow(at: CGPoint(x: W * 0.32, y: H * 0.78), radius: hypot(W, H) * 0.62, rgb(1, 0.92, 0.76, 0.26))

        let body = screen.insetBy(dx: -24 * u, dy: -24 * u)
        if body.minX > 170 * u { cupFromAbove(center: CGPoint(x: body.minX * 0.5, y: min(H - 110 * u, body.maxY - 70 * u))) }
        if W - body.maxX > 170 * u { notebook(x: body.maxX + (W - body.maxX) * 0.5, y: max(170 * u, body.minY + 180 * u)) }

        shadowed(blur: 46 * u, offset: CGSize(width: 10 * u, height: -18 * u), color: rgb(0.09, 0.05, 0.02, 0.62)) {
            c.addPath(rounded(body, 40 * u))
            c.setFillColor(rgb(0.08, 0.08, 0.09))
            c.fillPath()
        }
        c.addPath(rounded(body.insetBy(dx: 1 * u, dy: 1 * u), 39 * u))
        c.setStrokeColor(rgb(0.62, 0.63, 0.66))
        c.setLineWidth(2.2 * u)
        c.strokePath()
        c.setFillColor(rgb(0.20, 0.21, 0.25))
        c.fillEllipse(in: CGRect(x: body.midX - 4 * u, y: screen.maxY + 8 * u, width: 8 * u, height: 8 * u))
    }

    private func cupFromAbove(center p: CGPoint) {
        let r = 64 * u
        shadowed(blur: 24 * u, offset: CGSize(width: 8 * u, height: -12 * u), color: rgb(0.08, 0.04, 0.02, 0.55)) {
            c.setFillColor(rgb(0.96, 0.94, 0.90))
            c.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        c.setFillColor(rgb(0.90, 0.88, 0.84))
        c.fill(CGRect(x: p.x + r - 2 * u, y: p.y - 11 * u, width: 42 * u, height: 22 * u))
        let inner = r * 0.82
        c.setFillColor(rgb(0.27, 0.15, 0.08))
        c.fillEllipse(in: CGRect(x: p.x - inner, y: p.y - inner, width: 2 * inner, height: 2 * inner))
        glow(at: CGPoint(x: p.x - inner * 0.3, y: p.y + inner * 0.3), radius: inner, rgb(0.72, 0.48, 0.26, 0.55))
    }

    private func notebook(x: CGFloat, y: CGFloat) {
        let w = 190 * u, h = 260 * u
        c.saveGState()
        c.translateBy(x: x, y: y)
        c.rotate(by: -0.10)
        let page = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        shadowed(blur: 18 * u, offset: CGSize(width: 6 * u, height: -8 * u), color: rgb(0.08, 0.04, 0.02, 0.5)) {
            c.addPath(rounded(page, 6 * u))
            c.setFillColor(rgb(0.97, 0.96, 0.92))
            c.fillPath()
        }
        c.setStrokeColor(rgb(0.55, 0.65, 0.80, 0.55))
        c.setLineWidth(1.3 * u)
        var line = page.maxY - 36 * u
        while line > page.minY + 16 * u {
            c.move(to: CGPoint(x: page.minX + 14 * u, y: line))
            c.addLine(to: CGPoint(x: page.maxX - 14 * u, y: line))
            line -= 21 * u
        }
        c.strokePath()
        c.rotate(by: 0.5)
        let pencil = CGRect(x: -6 * u, y: -100 * u, width: 12 * u, height: 190 * u)
        fill(CGPath(rect: pencil, transform: nil), from: CGPoint(x: -6 * u, y: 0), to: CGPoint(x: 6 * u, y: 0), [rgb(0.86, 0.58, 0.10), rgb(1, 0.78, 0.26), rgb(0.76, 0.48, 0.08)], [0, 0.5, 1])
        let tip = CGMutablePath()
        tip.move(to: CGPoint(x: -6 * u, y: -100 * u))
        tip.addLine(to: CGPoint(x: 6 * u, y: -100 * u))
        tip.addLine(to: CGPoint(x: 0, y: -124 * u))
        tip.closeSubpath()
        c.addPath(tip)
        c.setFillColor(rgb(0.88, 0.76, 0.60))
        c.fillPath()
        c.restoreGState()
    }

    // MARK: Television in a living room

    func tv() {
        let frame = CGRect(x: screen.minX - 9 * u, y: screen.minY - 14 * u, width: screen.width + 18 * u, height: screen.height + 23 * u)
        let boardTop = frame.minY - 46 * u
        let boardH = min(150 * u, max(44 * u, boardTop * 0.72))
        let boardW = min(W * 0.96, frame.width + 230 * u)
        let board = CGRect(x: W / 2 - boardW / 2, y: boardTop - boardH, width: boardW, height: boardH)
        let floorTop = board.minY - 26 * u

        vertical(CGRect(x: 0, y: floorTop, width: W, height: H - floorTop), top: rgb(0.45, 0.53, 0.50), bottom: rgb(0.35, 0.42, 0.40))
        glow(at: CGPoint(x: screen.midX, y: screen.midY), radius: max(screen.width, screen.height) * 0.92, rgb(0.92, 0.95, 1, 0.20))
        wood(CGRect(x: 0, y: 0, width: W, height: max(0, floorTop)), base: (0.48, 0.33, 0.22), seed: 41)
        fill(CGRect(x: 0, y: floorTop, width: W, height: 12 * u), rgb(0.93, 0.92, 0.88))

        // Sideboard with legs and doors.
        c.setFillColor(rgb(0.18, 0.12, 0.08))
        for legX in [board.minX + 28 * u, board.maxX - 40 * u] { c.fill(CGRect(x: legX, y: floorTop - 3 * u, width: 12 * u, height: board.minY - floorTop + 3 * u)) }
        shadowed(blur: 28 * u, offset: CGSize(width: 0, height: -10 * u), color: rgb(0, 0, 0, 0.42)) {
            c.setFillColor(rgb(0.5, 0.34, 0.21))
            c.fill(board)
        }
        wood(board, base: (0.62, 0.42, 0.26), seed: 43)
        fill(CGRect(x: board.minX, y: board.maxY - 5 * u, width: board.width, height: 5 * u), rgb(1, 0.92, 0.80, 0.35))
        let doors = max(2, Int(board.width / (240 * u)))
        for i in 1..<doors {
            fill(CGRect(x: board.minX + board.width * CGFloat(i) / CGFloat(doors) - u, y: board.minY, width: 2 * u, height: board.height), rgb(0.18, 0.10, 0.06, 0.8))
        }

        // Stand and soundbar.
        let stand = CGRect(x: frame.midX - 92 * u, y: boardTop, width: 184 * u, height: 8 * u)
        c.addPath(rounded(stand, 4 * u))
        c.setFillColor(rgb(0.13, 0.13, 0.15))
        c.fillPath()
        c.setFillColor(rgb(0.10, 0.10, 0.12))
        c.fill(CGRect(x: frame.midX - 24 * u, y: boardTop + 6 * u, width: 48 * u, height: frame.minY - boardTop - 4 * u))

        if W - board.maxX + (board.width - frame.width) / 2 > 150 * u, board.maxX - frame.maxX > 90 * u {
            plant(baseX: board.maxX - (board.maxX - frame.maxX) * 0.45, baseY: boardTop, height: min(250 * u, screen.height * 0.6), seed: 9)
        }

        shadowed(blur: 30 * u, offset: CGSize(width: 0, height: -6 * u)) {
            c.addPath(rounded(frame, 6 * u))
            c.setFillColor(rgb(0.04, 0.04, 0.05))
            c.fillPath()
        }
        c.addPath(rounded(frame.insetBy(dx: 0.6 * u, dy: 0.6 * u), 5.5 * u))
        c.setStrokeColor(rgb(0.26, 0.26, 0.29))
        c.setLineWidth(1.2 * u)
        c.strokePath()
        vignette(0.20)
    }

    // MARK: Theater

    func theater() {
        fill(CGRect(origin: .zero, size: size), rgb(0.05, 0.04, 0.06))
        let stageTop = screen.minY - 44 * u
        glow(at: CGPoint(x: screen.midX, y: screen.midY), radius: max(screen.width, screen.height) * 0.86, rgb(0.98, 0.84, 0.62, 0.34))

        // Stage floor: boards running towards the back. In front of it the dark auditorium.
        let floorBottom = max(0, stageTop - 130 * u)
        let floor = CGRect(x: 0, y: floorBottom, width: W, height: max(0, stageTop - floorBottom))
        wood(floor, base: (0.40, 0.25, 0.14), seed: 61)
        c.saveGState()
        c.clip(to: floor)
        c.setStrokeColor(rgb(0.09, 0.05, 0.03, 0.55))
        c.setLineWidth(1.5 * u)
        let vanish = CGPoint(x: W / 2, y: stageTop + H * 0.5)
        let count = 22
        for i in 0...count {
            let x = W * (CGFloat(i) / CGFloat(count) * 1.8 - 0.4)
            c.move(to: CGPoint(x: x, y: 0))
            c.addLine(to: vanish)
        }
        c.strokePath()
        glow(at: CGPoint(x: screen.midX, y: stageTop), radius: max(W, H) * 0.52, rgb(1, 0.76, 0.42, 0.42))
        c.restoreGState()

        // Screen on stage: a thin dark frame, lit from the front.
        shadowed(blur: 44 * u, color: rgb(1, 0.80, 0.52, 0.45)) {
            c.setFillColor(rgb(0.08, 0.07, 0.08))
            c.fill(screen.insetBy(dx: -7 * u, dy: -7 * u))
        }

        let inner = 42 * u
        curtain(CGRect(x: 0, y: stageTop - 6 * u, width: max(0, screen.minX - inner), height: H - stageTop + 6 * u), seed: 71)
        curtain(CGRect(x: min(W, screen.maxX + inner), y: stageTop - 6 * u, width: max(0, W - screen.maxX - inner), height: H - stageTop + 6 * u), seed: 73)
        valance(from: screen.maxY + 26 * u)

        // Row of footlights at the edge of the stage.
        let lights = max(7, Int(W / (120 * u)))
        for i in 0..<lights {
            let x = W * (CGFloat(i) + 0.5) / CGFloat(lights)
            let p = CGPoint(x: x, y: max(10 * u, floorBottom + 72 * u))
            glow(at: p, radius: 40 * u, rgb(1, 0.82, 0.48, 0.65))
            c.setFillColor(rgb(1, 0.95, 0.78))
            c.fillEllipse(in: CGRect(x: p.x - 4 * u, y: p.y - 3 * u, width: 8 * u, height: 6 * u))
        }
        // The audience: rows of heads, nearer ones larger.
        fill(CGRect(x: 0, y: 0, width: W, height: floorBottom), rgb(0.03, 0.025, 0.035))
        var row: CGFloat = 0
        var y = floorBottom - 56 * u
        repeat {
            let shade = max(0.018, 0.075 - row * 0.012)
            heads(y: max(-20 * u, y), spacing: (112 + row * 16) * u, size: (54 + row * 9) * u, color: rgb(shade * 1.1, shade * 0.9, shade), seed: 5 + UInt64(row))
            row += 1
            y -= (84 + row * 16) * u
        } while y > -40 * u
    }

    /// Velvet in vertical folds.
    private func curtain(_ rect: CGRect, seed: UInt64) {
        guard rect.width > 1 else { return }
        c.saveGState()
        c.clip(to: rect)
        var dice = Dice(seed)
        let folds = max(4, Int(rect.width / (42 * u)))
        let w = rect.width / CGFloat(folds)
        for i in 0...folds {
            let x = rect.minX + CGFloat(i) * w - (dice.next() * 4 * u)
            let band = CGRect(x: x, y: rect.minY, width: w + 5 * u, height: rect.height)
            let shade = 0.82 + dice.next() * 0.3
            fill(CGPath(rect: band, transform: nil), from: CGPoint(x: band.minX, y: 0), to: CGPoint(x: band.maxX, y: 0),
                 [rgb(0.17 * shade, 0.015, 0.035), rgb(0.70 * shade, 0.07, 0.11), rgb(0.48 * shade, 0.04, 0.08), rgb(0.13 * shade, 0.01, 0.03)], [0, 0.38, 0.62, 1])
        }
        c.restoreGState()
    }

    /// Draped top of the curtains with a golden fringe.
    private func valance(from bottom: CGFloat) {
        guard bottom < H else { return }
        // In a tall picture a wall with a golden edge closes the stage above the drapes.
        let top = min(H, bottom + 190 * u)
        if top < H {
            vertical(CGRect(x: 0, y: top, width: W, height: H - top), top: rgb(0.06, 0.03, 0.05), bottom: rgb(0.17, 0.05, 0.07))
            fill(CGRect(x: 0, y: top - 2 * u, width: W, height: 7 * u), rgb(0.91, 0.72, 0.30))
        }
        let swags = max(3, Int(W / (250 * u)))
        let w = W / CGFloat(swags)
        let depth = 52 * u
        let shape = CGMutablePath()
        shape.move(to: CGPoint(x: 0, y: top))
        shape.addLine(to: CGPoint(x: 0, y: bottom))
        for i in 0..<swags {
            let a = CGFloat(i) * w
            shape.addQuadCurve(to: CGPoint(x: a + w, y: bottom), control: CGPoint(x: a + w / 2, y: bottom - depth))
        }
        shape.addLine(to: CGPoint(x: W, y: top))
        shape.closeSubpath()
        shadowed(blur: 30 * u, offset: CGSize(width: 0, height: -14 * u), color: rgb(0, 0, 0, 0.7)) {
            c.addPath(shape)
            c.setFillColor(rgb(0.45, 0.04, 0.08))
            c.fillPath()
        }
        c.saveGState()
        c.addPath(shape)
        c.clip()
        for i in 0..<swags {
            let center = CGPoint(x: (CGFloat(i) + 0.5) * w, y: bottom + (top - bottom) * 0.62)
            glow(at: center, radius: w * 0.62, rgb(0.86, 0.13, 0.18, 0.62))
            if i > 0 { fill(CGRect(x: CGFloat(i) * w - 7 * u, y: bottom - depth, width: 14 * u, height: H), rgb(0.10, 0.008, 0.02, 0.7)) }
        }
        c.restoreGState()
        // Fringe.
        let fringe = CGMutablePath()
        fringe.move(to: CGPoint(x: 0, y: bottom))
        for i in 0..<swags {
            let a = CGFloat(i) * w
            fringe.addQuadCurve(to: CGPoint(x: a + w, y: bottom), control: CGPoint(x: a + w / 2, y: bottom - depth))
        }
        c.addPath(fringe)
        c.setStrokeColor(rgb(0.91, 0.72, 0.30))
        c.setLineWidth(7 * u)
        c.strokePath()
    }

    private func heads(y: CGFloat, spacing: CGFloat, size r: CGFloat, color: CGColor, seed: UInt64) {
        var dice = Dice(seed)
        var x = -spacing * dice.next()
        c.setFillColor(color)
        while x < W + spacing {
            let lift = dice.next() * r * 0.28, s = 0.88 + dice.next() * 0.2
            let head = CGRect(x: x - r * s / 2, y: y + r * 0.72 + lift, width: r * s, height: r * 1.16 * s)
            c.fillEllipse(in: head)
            c.addPath(rounded(CGRect(x: x - r * 1.0, y: -r, width: r * 2.0, height: y + r * 1.75 + lift), r * 0.72))
            c.fillPath()
            x += spacing * (0.86 + dice.next() * 0.3)
        }
    }

    // MARK: Cinema

    func cinema() {
        vertical(CGRect(origin: .zero, size: size), top: rgb(0.055, 0.05, 0.075), bottom: rgb(0.02, 0.018, 0.03))
        // The picture lights up the room.
        glow(at: CGPoint(x: screen.midX, y: screen.midY), radius: max(screen.width, screen.height) * 1.02, rgb(0.42, 0.50, 0.78, 0.42))

        // Wall panels towards the screen.
        c.setStrokeColor(rgb(0.45, 0.50, 0.70, 0.13))
        c.setLineWidth(2 * u)
        let panels = 5
        for i in 1...panels {
            let f = CGFloat(i) / CGFloat(panels + 1)
            for (edge, inner) in [(CGFloat(0), screen.minX), (W, screen.maxX)] {
                let x = edge + (inner - edge) * f
                c.move(to: CGPoint(x: x, y: screen.minY - 90 * u * (1 - f) - 30 * u))
                c.addLine(to: CGPoint(x: x, y: min(H, screen.maxY + 120 * u * (1 - f) + 16 * u)))
            }
        }
        c.strokePath()

        shadowed(blur: 60 * u, color: rgb(0.55, 0.65, 0.95, 0.6)) {
            c.setFillColor(rgb(0.03, 0.03, 0.04))
            c.fill(screen.insetBy(dx: -6 * u, dy: -6 * u))
        }

        // Exit signs and step lights.
        let sign = CGRect(x: min(W - 90 * u, screen.maxX + (W - screen.maxX) * 0.45), y: screen.midY + 40 * u, width: 42 * u, height: 16 * u)
        if W - screen.maxX > 90 * u {
            glow(at: CGPoint(x: sign.midX, y: sign.midY), radius: 56 * u, rgb(0.20, 0.95, 0.45, 0.30))
            c.setFillColor(rgb(0.25, 0.92, 0.48))
            c.fill(sign)
        }

        // Two rows of seats in the room below the screen.
        let room = max(0, screen.minY - 30 * u)
        seats(y: room * 0.56, width: max(52 * u, room * 0.42) * 1.15, height: max(52 * u, room * 0.42), shade: 0.27, seed: 91)
        seats(y: room * 0.04, width: max(72 * u, room * 0.64) * 1.15, height: max(72 * u, room * 0.64), shade: 0.15, seed: 93)
    }

    private func seats(y: CGFloat, width w: CGFloat, height h: CGFloat, shade: CGFloat, seed: UInt64) {
        var dice = Dice(seed)
        var x = -w * dice.next()
        while x < W + w {
            let seat = CGRect(x: x + 3 * u, y: y - h * 2, width: w - 6 * u, height: h * 2 + h * 0.72)
            let path = rounded(seat, w * 0.22)
            fill(path, from: CGPoint(x: 0, y: seat.maxY), to: CGPoint(x: 0, y: y), [rgb(0.62 * shade + 0.04, 0.10 * shade + 0.015, 0.14 * shade + 0.03), rgb(0.03, 0.012, 0.02)])
            c.addPath(rounded(seat.insetBy(dx: 1.5 * u, dy: 1.5 * u), w * 0.21))
            c.setStrokeColor(rgb(0.55, 0.60, 0.85, 0.10 + shade * 0.5))
            c.setLineWidth(1.5 * u)
            c.strokePath()
            if dice.next() < 0.42 {
                let r = w * 0.38
                c.setFillColor(rgb(0.018, 0.018, 0.028))
                c.fillEllipse(in: CGRect(x: seat.midX - r / 2 + (dice.next() - 0.5) * 10 * u, y: seat.maxY - r * 0.42, width: r, height: r * 1.22))
            }
            x += w
        }
    }

    // MARK: Picture frame on a wall

    func pictureFrame() {
        vertical(CGRect(origin: .zero, size: size), top: rgb(0.74, 0.77, 0.78), bottom: rgb(0.60, 0.63, 0.65))
        var dice = Dice(77)
        for _ in 0..<min(2400, Int(W * H / 900)) {
            let a = 0.02 + dice.next() * 0.03
            c.setFillColor(dice.next() > 0.5 ? rgb(1, 1, 1, a) : rgb(0, 0, 0, a))
            c.fill(CGRect(x: dice.next() * W, y: dice.next() * H, width: 2 * u, height: 2 * u))
        }

        let mat = screen.insetBy(dx: -34 * u, dy: -34 * u)
        let outer = mat.insetBy(dx: -27 * u, dy: -27 * u)
        // Light from above.
        glow(at: CGPoint(x: outer.midX, y: outer.maxY - 12 * u), radius: max(outer.width, outer.height) * 0.86, rgb(1, 0.92, 0.72, 0.36))

        shadowed(blur: 50 * u, offset: CGSize(width: 0, height: -26 * u), color: rgb(0.05, 0.05, 0.08, 0.62)) {
            c.setFillColor(rgb(0.3, 0.2, 0.12))
            c.fill(outer)
        }
        func side(_ points: [CGPoint], vertical isVertical: Bool, seed: UInt64, shade: CGFloat) {
            let p = CGMutablePath()
            p.addLines(between: points)
            p.closeSubpath()
            c.saveGState()
            c.addPath(p)
            c.clip()
            wood(outer, base: (0.52 * shade, 0.34 * shade, 0.18 * shade), dark: 0.66, vertical: isVertical, seed: seed)
            c.restoreGState()
        }
        let tl = CGPoint(x: outer.minX, y: outer.maxY), tr = CGPoint(x: outer.maxX, y: outer.maxY)
        let bl = CGPoint(x: outer.minX, y: outer.minY), br = CGPoint(x: outer.maxX, y: outer.minY)
        let itl = CGPoint(x: mat.minX, y: mat.maxY), itr = CGPoint(x: mat.maxX, y: mat.maxY)
        let ibl = CGPoint(x: mat.minX, y: mat.minY), ibr = CGPoint(x: mat.maxX, y: mat.minY)
        side([tl, tr, itr, itl], vertical: false, seed: 81, shade: 1.14)
        side([bl, br, ibr, ibl], vertical: false, seed: 83, shade: 0.80)
        side([tl, bl, ibl, itl], vertical: true, seed: 85, shade: 0.98)
        side([tr, br, ibr, itr], vertical: true, seed: 87, shade: 0.90)
        c.setStrokeColor(rgb(0.13, 0.08, 0.04, 0.8))
        c.setLineWidth(1.5 * u)
        for (a, b) in [(tl, itl), (tr, itr), (bl, ibl), (br, ibr)] {
            c.move(to: a)
            c.addLine(to: b)
        }
        c.strokePath()

        // Passe-partout with the cut around the picture.
        fill(mat, rgb(0.96, 0.95, 0.91))
        c.saveGState()
        c.clip(to: mat)
        c.setStrokeColor(rgb(0, 0, 0, 0.30))
        c.setLineWidth(10 * u)
        c.stroke(mat.insetBy(dx: -3 * u, dy: -3 * u))
        c.restoreGState()
        let cut = screen.insetBy(dx: -3.5 * u, dy: -3.5 * u)
        fill(cut, rgb(0.74, 0.72, 0.67))
        vignette(0.18)
    }
}
