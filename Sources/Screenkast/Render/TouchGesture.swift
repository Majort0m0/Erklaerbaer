import AppKit
import CoreGraphics
import CoreImage

/// Where the fingers of a gesture are at a moment (pixels of the picture).
struct TouchPose {
    struct Finger { var at: CGPoint; var scale: CGFloat; var alpha: CGFloat }
    struct Ripple { var at: CGPoint; var progress: CGFloat }
    var fingers: [Finger] = []
    var ripples: [Ripple] = []
    /// The way the fingers have come.
    var trails: [[CGPoint]] = []
    /// Tap and hold: how far the ring around the finger has run (0…1).
    var hold: CGFloat?
}

enum TouchAnimation {
    private static let arrive = 0.18, leave = 0.22, ripple = 0.5, pressed: CGFloat = 0.82

    /// Length of one performance of a short gesture; the others use the whole block.
    private static func natural(_ g: TouchGesture) -> Double? {
        switch g {
        case .tap: return arrive + 0.12 + ripple + leave
        case .doubleTap: return arrive + 0.1 + 0.16 + 0.1 + ripple + leave
        case .swipe: return arrive + 0.4 + 0.35
        default: return nil
        }
    }

    private static func smooth(_ x: Double) -> Double {
        let t = max(0, min(1, x))
        return t * t * (3 - 2 * t)
    }

    /// Size of the finger: settling at the start, smaller while it presses.
    private static func scale(_ t: Double, down: Double, up: Double) -> CGFloat {
        if t < arrive { return 1.3 - 0.3 * CGFloat(smooth(t / arrive)) }
        let press = CGFloat(smooth((t - down) / 0.08)) - CGFloat(smooth((t - up) / 0.1))
        return 1 - (1 - pressed) * press
    }

    /// - Parameters:
    ///   - from: first touch, or the middle of a two-finger gesture.
    ///   - to: where a drag ends, or one finger of a pinch (the other lies opposite).
    ///   - gap: distance of two fingers side by side.
    static func pose(_ g: TouchGesture, from: CGPoint, to: CGPoint, gap: CGFloat, age: Double, length: Double, repeats: Bool) -> TouchPose {
        var t = age
        if let n = natural(g) {
            if length < n { t = age * n / max(0.01, length) }
            else if repeats, g.canRepeat { t = age.truncatingRemainder(dividingBy: n + 0.25) }
        }
        switch g {
        case .tap: return taps(at: from, t: t, count: 1, length: natural(g) ?? length)
        case .doubleTap: return taps(at: from, t: t, count: 2, length: natural(g) ?? length)
        case .hold: return hold(at: from, t: t, length: length)
        case .swipe:
            return moving(g, t: t, start: arrive, end: arrive + 0.4, fadeFrom: arrive + 0.3, fadeLength: 0.4) { s in [lerp(from, to, s)] }
        case .drag:
            let end = max(arrive + 0.2, length - leave - 0.05)
            return moving(g, t: t, start: arrive + 0.1, end: end, fadeFrom: end, fadeLength: leave) { s in [lerp(from, to, s)] }
        case .twoFingerDrag:
            let end = max(arrive + 0.2, length - leave - 0.05)
            let d = hypot(to.x - from.x, to.y - from.y)
            let side = d > 0 ? CGPoint(x: -(to.y - from.y) / d * gap / 2, y: (to.x - from.x) / d * gap / 2) : CGPoint(x: gap / 2, y: 0)
            return moving(g, t: t, start: arrive + 0.1, end: end, fadeFrom: end, fadeLength: leave) { s in
                let p = lerp(from, to, s)
                return [CGPoint(x: p.x + side.x, y: p.y + side.y), CGPoint(x: p.x - side.x, y: p.y - side.y)]
            }
        case .pinchIn, .pinchOut, .rotate:
            let end = max(arrive + 0.2, length - leave - 0.05)
            let v = CGPoint(x: to.x - from.x, y: to.y - from.y)
            return moving(g, t: t, start: arrive + 0.1, end: end, fadeFrom: end, fadeLength: leave) { s in
                var factor: CGFloat = 1, turn: CGFloat = 0
                if g == .pinchIn { factor = 1 - 0.72 * s } else if g == .pinchOut { factor = 0.28 + 0.72 * s } else { turn = s * 1.25 }
                let u = CGPoint(x: (v.x * cos(turn) - v.y * sin(turn)) * factor, y: (v.x * sin(turn) + v.y * cos(turn)) * factor)
                return [CGPoint(x: from.x + u.x, y: from.y + u.y), CGPoint(x: from.x - u.x, y: from.y - u.y)]
            }
        }
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ s: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * s, y: a.y + (b.y - a.y) * s) }

    private static func taps(at p: CGPoint, t: Double, count: Int, length: Double) -> TouchPose {
        var pose = TouchPose()
        var size = t < arrive ? scale(t, down: 1, up: 2) : CGFloat(1)
        var down = arrive
        for _ in 0..<count {
            let up = down + (count == 1 ? 0.12 : 0.1)
            if t >= arrive { size = min(size, scale(t, down: down, up: up)) }
            if t >= up, t < up + ripple { pose.ripples.append(.init(at: p, progress: CGFloat((t - up) / ripple))) }
            down = up + 0.16
        }
        let alpha = min(smooth(t / arrive), 1 - smooth((t - (length - leave)) / leave))
        if alpha > 0 { pose.fingers = [.init(at: p, scale: size, alpha: CGFloat(alpha))] }
        return pose
    }

    private static func hold(at p: CGPoint, t: Double, length: Double) -> TouchPose {
        var pose = TouchPose()
        let up = max(arrive + 0.3, length - leave - 0.1)
        let alpha = min(smooth(t / arrive), 1 - smooth((t - up) / max(0.05, length - up)))
        if alpha > 0 { pose.fingers = [.init(at: p, scale: scale(t, down: arrive, up: up), alpha: CGFloat(alpha))] }
        if t >= arrive, t < up { pose.hold = CGFloat((t - arrive) / (up - arrive)) }
        return pose
    }

    /// Fingers that press, travel along `positions` (0…1) and lift.
    private static func moving(_ g: TouchGesture, t: Double, start: Double, end: Double, fadeFrom: Double, fadeLength: Double,
                               positions: (CGFloat) -> [CGPoint]) -> TouchPose {
        var pose = TouchPose()
        let s = CGFloat(smooth((t - start) / max(0.01, end - start)))
        let alpha = CGFloat(min(smooth(t / arrive), 1 - smooth((t - fadeFrom) / fadeLength)))
        guard alpha > 0 else { return pose }
        let size = scale(t, down: arrive, up: end)
        pose.fingers = positions(s).map { .init(at: $0, scale: size, alpha: alpha) }
        if s > 0.01 {
            let steps = (0...24).map { positions(CGFloat($0) / 24 * s) }
            pose.trails = pose.fingers.indices.map { i in steps.map { $0[i] } }
        }
        return pose
    }
}

/// The pictures of a touch: drawn once, then scaled.
enum TouchArt {
    private static func context(_ size: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func finish(_ c: CGContext) -> CIImage { c.makeImage().map { CIImage(cgImage: $0) } ?? .empty() }

    /// Centered on the origin; `r` is the radius of the dot.
    static func dot(r: CGFloat, color: (CGFloat, CGFloat, CGFloat)) -> CIImage {
        let size = Int(r * 3.2)
        guard let c = context(size) else { return .empty() }
        let m = CGFloat(size) / 2
        let circle = CGRect(x: m - r, y: m - r, width: 2 * r, height: 2 * r)
        c.setShadow(offset: CGSize(width: 0, height: -r * 0.08), blur: r * 0.35, color: CGColor(gray: 0, alpha: 0.4))
        c.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 0.62))
        c.fillEllipse(in: circle)
        c.setShadow(offset: .zero, blur: 0)
        c.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        c.setLineWidth(r * 0.11)
        c.strokeEllipse(in: circle.insetBy(dx: r * 0.06, dy: r * 0.06))
        c.setStrokeColor(CGColor(gray: 0, alpha: 0.28))
        c.setLineWidth(r * 0.04)
        c.strokeEllipse(in: circle)
        return finish(c).transformed(by: CGAffineTransform(translationX: -m, y: -m))
    }

    /// A numbered step, centered on the origin.
    static func step(_ number: Int, r: CGFloat, color: (CGFloat, CGFloat, CGFloat)) -> CIImage {
        let size = Int(r * 2.8)
        guard let c = context(size) else { return .empty() }
        let m = CGFloat(size) / 2
        let circle = CGRect(x: m - r, y: m - r, width: 2 * r, height: 2 * r)
        c.setShadow(offset: CGSize(width: 0, height: -r * 0.1), blur: r * 0.35, color: CGColor(gray: 0, alpha: 0.45))
        c.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
        c.fillEllipse(in: circle)
        c.setShadow(offset: .zero, blur: 0)
        c.setStrokeColor(CGColor(gray: 1, alpha: 1))
        c.setLineWidth(r * 0.12)
        c.strokeEllipse(in: circle.insetBy(dx: r * 0.06, dy: r * 0.06))
        let light = color.0 * 0.3 + color.1 * 0.6 + color.2 * 0.1 > 0.75
        let text = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: r * (number > 9 ? 1.0 : 1.2), weight: .bold),
            .foregroundColor: light ? NSColor.black : NSColor.white,
        ])
        let bounds = text.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
        text.draw(at: NSPoint(x: m - bounds.width / 2, y: m - bounds.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        return finish(c).transformed(by: CGAffineTransform(translationX: -m, y: -m))
    }

    static func ring(r: CGFloat, color: (CGFloat, CGFloat, CGFloat)) -> CIImage {
        let size = Int(r * 2.5)
        guard let c = context(size) else { return .empty() }
        let m = CGFloat(size) / 2
        c.setStrokeColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
        c.setLineWidth(r * 0.11)
        c.strokeEllipse(in: CGRect(x: m - r, y: m - r, width: 2 * r, height: 2 * r))
        c.setStrokeColor(CGColor(gray: 1, alpha: 0.75))
        c.setLineWidth(r * 0.04)
        c.strokeEllipse(in: CGRect(x: m - r, y: m - r, width: 2 * r, height: 2 * r))
        return finish(c).transformed(by: CGAffineTransform(translationX: -m, y: -m))
    }

    /// A stylized fingertip: the tip is at the origin, the finger runs towards -y and fades out.
    static func finger(r: CGFloat) -> CIImage {
        let width = r * 2.05, length = r * 5.6
        let size = Int(length + r * 1.2)
        guard let c = context(size) else { return .empty() }
        let cx = CGFloat(size) / 2, tip = CGFloat(size) - r * 0.6
        let body = CGRect(x: cx - width / 2, y: tip - length, width: width, height: length)
        let path = CGPath(roundedRect: body, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -r * 0.12), blur: r * 0.5, color: CGColor(gray: 0, alpha: 0.4))
        c.setFillColor(CGColor(srgbRed: 0.96, green: 0.8, blue: 0.69, alpha: 1))
        c.addPath(path)
        c.fillPath()
        c.restoreGState()
        // Light skin, a little darker at the sides so the finger looks round.
        if let space = CGColorSpace(name: CGColorSpace.sRGB) {
            let side = CGColor(srgbRed: 0.87, green: 0.66, blue: 0.54, alpha: 1), middle = CGColor(srgbRed: 0.98, green: 0.85, blue: 0.76, alpha: 1)
            if let round = CGGradient(colorsSpace: space, colors: [side, middle, side] as CFArray, locations: [0, 0.48, 1]) {
                c.saveGState()
                c.addPath(path)
                c.clip()
                c.drawLinearGradient(round, start: CGPoint(x: body.minX, y: 0), end: CGPoint(x: body.maxX, y: 0), options: [])
                c.restoreGState()
            }
        }
        c.setStrokeColor(CGColor(srgbRed: 0.42, green: 0.26, blue: 0.19, alpha: 0.75))
        c.setLineWidth(r * 0.1)
        c.addPath(path)
        c.strokePath()
        // Nail and the lines of the first joint.
        let nail = CGRect(x: cx - width * 0.25, y: tip - width * 0.66, width: width * 0.5, height: width * 0.5)
        c.setFillColor(CGColor(srgbRed: 1, green: 0.91, blue: 0.87, alpha: 1))
        c.addPath(CGPath(roundedRect: nail, cornerWidth: width * 0.24, cornerHeight: width * 0.24, transform: nil))
        c.fillPath()
        c.setStrokeColor(CGColor(srgbRed: 0.5, green: 0.32, blue: 0.25, alpha: 0.45))
        c.setLineWidth(r * 0.07)
        c.addPath(CGPath(roundedRect: nail, cornerWidth: width * 0.24, cornerHeight: width * 0.24, transform: nil))
        c.strokePath()
        for y in [tip - width * 1.2] {
            c.move(to: CGPoint(x: cx - width * 0.26, y: y))
            c.addQuadCurve(to: CGPoint(x: cx + width * 0.26, y: y), control: CGPoint(x: cx, y: y - r * 0.1))
            c.strokePath()
        }
        // The hand end disappears softly.
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let fade = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0), CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)] as CFArray, locations: [0, 1]) {
            c.setBlendMode(.destinationIn)
            c.drawLinearGradient(fade, start: CGPoint(x: cx, y: tip - length), end: CGPoint(x: cx, y: tip - length * 0.45),
                                 options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        return finish(c).transformed(by: CGAffineTransform(translationX: -cx, y: -tip))
    }
}
