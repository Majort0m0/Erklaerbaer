import CoreGraphics
import CoreImage

/// Hand-drawn lines for arrows and frames: slightly unsteady strokes that can be drawn step by step.
enum Sketch {
    typealias Stroke = [CGPoint]

    /// A repeatable number from an id: the same marking wobbles the same way in every frame.
    static func seed(_ id: UUID) -> CGFloat {
        let u = id.uuid
        return CGFloat(Int(u.0) + Int(u.5) * 3 + Int(u.11) * 7) / 37
    }

    private static func noise(_ s: CGFloat, _ seed: CGFloat) -> CGFloat {
        sin(s + seed) * 0.75 + sin(s * 2.3 + seed * 1.7) * 0.25
    }

    private static func length(_ points: Stroke) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// Evenly spaced points along a line.
    private static func resampled(_ points: Stroke, step: CGFloat) -> Stroke {
        guard points.count > 1, let first = points.first else { return points }
        var out = [first]
        var carry: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) {
            let d = hypot(b.x - a.x, b.y - a.y)
            guard d > 0 else { continue }
            var at = step - carry
            while at <= d {
                out.append(CGPoint(x: a.x + (b.x - a.x) * at / d, y: a.y + (b.y - a.y) * at / d))
                at += step
            }
            carry = d - (at - step)
        }
        if let last = points.last { out.append(last) }
        return out
    }

    /// Moves each point a little sideways along the line. The ends stay near their places.
    private static func wobbled(_ points: Stroke, amplitude: CGFloat, wavelength: CGFloat, seed: CGFloat) -> Stroke {
        guard amplitude > 0, points.count > 2 else { return points }
        var travelled: CGFloat = 0
        return points.indices.map { i in
            let a = points[max(0, i - 1)], b = points[min(points.count - 1, i + 1)]
            if i > 0 { travelled += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y) }
            let d = max(0.001, hypot(b.x - a.x, b.y - a.y))
            let n = noise(travelled / wavelength * 2 * .pi, seed) * amplitude
            return CGPoint(x: points[i].x - (b.y - a.y) / d * n, y: points[i].y + (b.x - a.x) / d * n)
        }
    }

    /// Slightly bent shaft, then the two strokes of the head.
    static func arrow(from: CGPoint, to: CGPoint, line: CGFloat, handDrawn: Bool, seed: CGFloat) -> [Stroke] {
        let dx = to.x - from.x, dy = to.y - from.y, d = max(1, hypot(dx, dy))
        let bow = handDrawn ? d * 0.06 * (sin(seed * 3) >= 0 ? 1 : -1) : 0
        let middle = CGPoint(x: (from.x + to.x) / 2 - dy / d * bow, y: (from.y + to.y) / 2 + dx / d * bow)
        var curve: Stroke = []
        for i in 0...40 {
            let t = CGFloat(i) / 40, u = 1 - t
            curve.append(CGPoint(x: u * u * from.x + 2 * u * t * middle.x + t * t * to.x, y: u * u * from.y + 2 * u * t * middle.y + t * t * to.y))
        }
        let step = max(2, line * 0.8)
        let amplitude = handDrawn ? min(line * 0.4, d * 0.008) : 0
        let shaft = wobbled(resampled(curve, step: step), amplitude: amplitude, wavelength: max(80, d * 0.8), seed: seed)
        let end = shaft[max(0, shaft.count - 5)]
        let angle = atan2(to.y - end.y, to.x - end.x)
        let size = line * 5
        func barb(_ turn: CGFloat, _ scale: CGFloat) -> Stroke {
            let tip = shaft.last ?? to
            let a = angle + .pi - turn
            let back = CGPoint(x: tip.x + cos(a) * size * scale, y: tip.y + sin(a) * size * scale)
            return wobbled(resampled([back, tip], step: step), amplitude: amplitude * 0.5, wavelength: size, seed: seed + turn * 4)
        }
        let spread: CGFloat = handDrawn ? 0.46 + sin(seed) * 0.05 : 0.46
        return [shaft, barb(spread, 1), barb(-spread, handDrawn ? 0.9 : 1)]
    }

    /// The outline drawn in one go; by hand the pen overshoots where it began.
    static func outline(_ rect: CGRect, shape: AnnotationShape, line: CGFloat, handDrawn: Bool, seed: CGFloat) -> [Stroke] {
        var base: Stroke = []
        let overshoot: CGFloat = handDrawn ? 0.05 : 0
        switch shape {
        case .ellipse:
            let turns = 2 * CGFloat.pi * (1 + overshoot * 1.6)
            for i in 0...160 {
                let a = .pi * 0.72 - turns * CGFloat(i) / 160
                let grow = handDrawn ? 1 + 0.018 * CGFloat(i) / 160 : 1
                base.append(CGPoint(x: rect.midX + cos(a) * rect.width / 2 * grow, y: rect.midY + sin(a) * rect.height / 2 * grow))
            }
        case .rectangle, .rounded:
            let r = shape == .rectangle ? min(line, min(rect.width, rect.height) * 0.02) : min(rect.width, rect.height) * 0.08
            func corner(_ c: CGPoint, from: CGFloat) {
                for i in 0...10 {
                    let a = from - CGFloat(i) / 10 * (.pi / 2)
                    base.append(CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
                }
            }
            corner(CGPoint(x: rect.minX + r, y: rect.maxY - r), from: .pi)
            corner(CGPoint(x: rect.maxX - r, y: rect.maxY - r), from: .pi / 2)
            corner(CGPoint(x: rect.maxX - r, y: rect.minY + r), from: 0)
            corner(CGPoint(x: rect.minX + r, y: rect.minY + r), from: -.pi / 2)
            base.append(CGPoint(x: rect.minX, y: rect.maxY - r))
            base.append(CGPoint(x: rect.minX + r, y: rect.maxY))
            if overshoot > 0 { base.append(CGPoint(x: rect.minX + rect.width * overshoot * 2, y: rect.maxY + line * 0.5)) }
        }
        let size = max(rect.width, rect.height)
        let amplitude = handDrawn ? min(line * 0.5, size * 0.005) : 0
        return [wobbled(resampled(base, step: max(2, line * 0.8)), amplitude: amplitude, wavelength: max(120, size * 0.7), seed: seed)]
    }

    /// The strokes up to `progress` (0…1 of their whole length), as an image in place.
    static func image(_ strokes: [Stroke], progress: CGFloat, line: CGFloat, color: (CGFloat, CGFloat, CGFloat), halo: Bool) -> CIImage {
        let all = strokes.flatMap { $0 }
        guard let x0 = all.map(\.x).min(), let x1 = all.map(\.x).max(), let y0 = all.map(\.y).min(), let y1 = all.map(\.y).max() else { return .empty() }
        let margin = line * 4
        let box = CGRect(x: x0 - margin, y: y0 - margin, width: x1 - x0 + 2 * margin, height: y1 - y0 + 2 * margin).integral
        // Enough for a line drawing, and little memory even for a frame around the whole picture.
        let scale = min(1, 1600 / max(box.width, box.height))
        let w = Int((box.width * scale).rounded(.up)), h = Int((box.height * scale).rounded(.up))
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .empty() }
        c.scaleBy(x: scale, y: scale)
        c.translateBy(x: -box.minX, y: -box.minY)
        c.setLineCap(.round)
        c.setLineJoin(.round)

        var left = strokes.reduce(0) { $0 + length($1) } * min(1, max(0, progress))
        var paths: [CGPath] = []
        for stroke in strokes where left > 0 {
            let path = CGMutablePath()
            guard let first = stroke.first else { continue }
            path.move(to: first)
            for (a, b) in zip(stroke, stroke.dropFirst()) {
                let d = hypot(b.x - a.x, b.y - a.y)
                if d <= left {
                    path.addLine(to: b)
                    left -= d
                } else {
                    path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * left / max(0.001, d), y: a.y + (b.y - a.y) * left / max(0.001, d)))
                    left = 0
                    break
                }
            }
            paths.append(path)
        }
        func stroke(width: CGFloat, _ color: CGColor) {
            c.setLineWidth(width)
            c.setStrokeColor(color)
            for path in paths {
                c.addPath(path)
                c.strokePath()
            }
        }
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -line * 0.3 * scale), blur: line * scale, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.42))
        if halo { stroke(width: line * 1.7, CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92)) } else { stroke(width: line, CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1)) }
        c.restoreGState()
        stroke(width: line, CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))

        guard let cg = c.makeImage() else { return .empty() }
        return CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .transformed(by: CGAffineTransform(translationX: box.minX, y: box.minY))
    }
}
