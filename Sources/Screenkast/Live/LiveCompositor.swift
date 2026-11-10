import AppKit
import CoreImage
import CoreGraphics

/// What the live picture shows.
struct LiveConfig: Codable, Equatable {
    enum Scene: String, Codable { case webcam, source }
    var scene: Scene = .source
    var bubble = true
    /// Center of the webcam bubble (0…1, origin top left) and its diameter as a part of the picture height.
    var bubbleX = 0.86
    var bubbleY = 0.76
    var bubbleSize = 0.36
    var clicks = true
    var trail = false
    /// Where memes appear and their height as a part of the picture.
    var memeSpot: MemeSpot = .center
    var memeSize = 0.6
    /// Picture behind the person in the webcam.
    var background: Bool? = nil
    /// How far the outline lies inside the person, and how much it is calmed over time (0…1, nil: 0.5).
    var backgroundEdge: Double? = nil
    var backgroundCalm: Double? = nil
    /// Show keyboard shortcuts pressed on the Mac.
    var keys: Bool? = nil
    /// Scene around the source (laptop, television …), nil: none.
    var mockup: MockupKind? = nil
    /// Logo in a corner (`file` is a full path) and whether it is shown.
    var logo: Watermark? = nil
    var logoOn: Bool? = nil
}

enum MemeSpot: String, Codable, CaseIterable, Identifiable {
    case center, topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .center: return "Mitte"
        case .topLeft: return "Oben links"
        case .topRight: return "Oben rechts"
        case .bottomLeft: return "Unten links"
        case .bottomRight: return "Unten rechts"
        }
    }
}

/// Mouse marks in the source (0…1, origin top left); `age` in seconds.
struct LiveEffects {
    var trail: [(at: CGPoint, age: Double)] = []
    var clicks: [(at: CGPoint, age: Double)] = []
    /// The keyboard shortcut pressed last.
    var key: (label: String, age: Double)?
}

/// Builds the live picture from its parts. Everything is cut to the canvas, so it always has the same size.
enum LiveCompositor {
    static let canvas = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    static let trailLife = 0.7
    static let clickLife = 0.6
    static let keyLife = 1.8
    nonisolated(unsafe) private static var keyPill: (label: String, image: CIImage)?
    private static let background = CIImage(color: CIColor(red: 0.07, green: 0.08, blue: 0.1)).cropped(to: canvas)
    private static let markColor: (CGFloat, CGFloat, CGFloat) = (1, 0.78, 0.1)
    private static let clickRing = TouchArt.ring(r: 64, color: markColor)

    static func fit(_ size: CGSize, in area: CGRect) -> CGRect {
        let scale = min(area.width / max(1, size.width), area.height / max(1, size.height))
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    /// Distance of the white edge from the webcam picture (pixels of the live picture).
    static let bubbleRim: CGFloat = 3

    /// Where the bubble lies (Core Image coordinates); it always stays completely in the picture.
    static func bubbleRect(_ c: LiveConfig) -> CGRect {
        let d = canvas.height * CGFloat(min(0.9, max(0.1, c.bubbleSize)))
        let x = min(canvas.width - d / 2, max(d / 2, CGFloat(c.bubbleX) * canvas.width))
        let y = min(canvas.height - d / 2, max(d / 2, (1 - CGFloat(c.bubbleY)) * canvas.height))
        return CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)
    }

    private static func place(_ image: CIImage, filling rect: CGRect) -> CIImage {
        let e = image.extent
        let scale = max(rect.width / max(1, e.width), rect.height / max(1, e.height))
        return image.transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
            .cropped(to: rect)
    }

    /// A person mask as plain numbers: without color management, 50 % stays 50 %.
    static func maskImage(_ buffer: CVPixelBuffer) -> CIImage { CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]) }

    /// Moves the outline of a person mask: high values cut closer to the person, low ones keep more around it.
    static func sharpened(_ mask: CIImage, edge: Double) -> CIImage {
        let threshold = CGFloat(min(0.9, max(0.1, edge))), reach: CGFloat = 0.18
        let gain = 1 / (2 * reach), bias = -(threshold - reach) * gain
        return mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ]).applyingFilter("CIColorClamp")
    }

    /// The person of a camera picture in front of a picture. `mask` is white where the person is.
    static func person(_ camera: CIImage, mask: CIImage, background: CIImage, edge: Double = 0.5) -> CIImage {
        let e = camera.extent, m = mask.extent
        let fittedMask = mask.transformed(by: CGAffineTransform(translationX: -m.minX, y: -m.minY)
            .concatenating(CGAffineTransform(scaleX: e.width / max(1, m.width), y: e.height / max(1, m.height)))
            .concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
        return camera.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: place(background, filling: e),
            kCIInputMaskImageKey: sharpened(fittedMask, edge: edge).clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: e),
        ]).cropped(to: e)
    }

    private static func disc(center: CGPoint, inner: CGFloat, outer: CGFloat, color: CIColor) -> CIImage {
        let filter = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(cgPoint: center), "inputRadius0": inner, "inputRadius1": outer,
            "inputColor0": color, "inputColor1": CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0),
        ])
        return (filter?.outputImage ?? .empty()).cropped(to: CGRect(x: center.x - outer, y: center.y - outer, width: 2 * outer, height: 2 * outer))
    }

    private static func bubble(_ camera: CIImage, over base: CIImage, config: LiveConfig) -> CIImage {
        let rect = bubbleRect(config), r = rect.width / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let shadow = disc(center: CGPoint(x: center.x, y: center.y - 6), inner: r, outer: r + 22, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.4))
        let edge = disc(center: center, inner: r + bubbleRim - 0.5, outer: r + bubbleRim + 0.5, color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        let mask = disc(center: center, inner: r - 1, outer: r, color: .white)
        let round = place(camera, filling: rect).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
        ])
        return round.composited(over: edge.composited(over: shadow.composited(over: base)))
    }

    private static func trailImage(_ points: [(at: CGPoint, age: Double)]) -> CIImage? {
        guard points.count > 1, let x0 = points.map(\.at.x).min(), let x1 = points.map(\.at.x).max(),
              let y0 = points.map(\.at.y).min(), let y1 = points.map(\.at.y).max() else { return nil }
        let box = CGRect(x: x0 - 24, y: y0 - 24, width: x1 - x0 + 48, height: y1 - y0 + 48).integral.intersection(canvas)
        guard !box.isNull, box.width > 1, box.height > 1, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.translateBy(x: -box.minX, y: -box.minY)
        c.setLineCap(.round)
        for (a, b) in zip(points, points.dropFirst()) {
            let life = 1 - CGFloat(min(1, max(0, b.age / trailLife)))
            c.setStrokeColor(CGColor(srgbRed: markColor.0, green: markColor.1, blue: markColor.2, alpha: 0.8 * life))
            c.setLineWidth(3 + 12 * life)
            c.move(to: a.at)
            c.addLine(to: b.at)
            c.strokePath()
        }
        return c.makeImage().map { CIImage(cgImage: $0).transformed(by: CGAffineTransform(translationX: box.minX, y: box.minY)) }
    }

    private struct DrawnScene {
        let key: String
        let image: CIImage
        let mask: CIImage?
    }
    nonisolated(unsafe) private static var drawnScene: DrawnScene?
    private static let sceneLock = NSLock()

    /// The scene for a source of this shape, drawn once. `mask` rounds the corners of its screen.
    private static func scene(_ kind: MockupKind, screen: CGRect) -> DrawnScene? {
        let key = "\(kind.rawValue)|\(Int(screen.minX)),\(Int(screen.minY)),\(Int(screen.width)),\(Int(screen.height))"
        if let kept = sceneLock.withLock({ drawnScene }), kept.key == key { return kept }
        guard let picture = MockupScene.image(kind, size: canvas.size, screen: screen) else { return nil }
        var mask: CIImage?
        let radius = kind.cornerRadius(screen: screen)
        if radius > 0, let c = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            c.addPath(CGPath(roundedRect: screen, cornerWidth: radius, cornerHeight: radius, transform: nil))
            c.setFillColor(CGColor(gray: 1, alpha: 1))
            c.fillPath()
            mask = c.makeImage().map { CIImage(cgImage: $0) }
        }
        let drawn = DrawnScene(key: key, image: CIImage(cgImage: picture), mask: mask)
        sceneLock.withLock { drawnScene = drawn }
        return drawn
    }

    /// The shortcut as a dark pill with large letters. The last one is kept.
    private static func keyImage(_ label: String) -> CIImage {
        if let kept = keyPill, kept.label == label { return kept.image }
        let text = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 54, weight: .semibold), .foregroundColor: NSColor.white])
        let size = text.size()
        let w = Int(size.width.rounded(.up)) + 72, h = Int(size.height.rounded(.up)) + 36
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .empty() }
        let box = CGRect(x: 0, y: 0, width: w, height: h)
        c.addPath(CGPath(roundedRect: box.insetBy(dx: 1, dy: 1), cornerWidth: 20, cornerHeight: 20, transform: nil))
        c.setFillColor(CGColor(gray: 0.08, alpha: 0.82))
        c.fillPath()
        let graphics = NSGraphicsContext(cgContext: c, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        text.draw(at: NSPoint(x: 36, y: 18))
        NSGraphicsContext.restoreGraphicsState()
        let image = c.makeImage().map { CIImage(cgImage: $0) } ?? .empty()
        keyPill = (label, image)
        return image
    }

    nonisolated(unsafe) private static var logoPicture: (path: String, image: CIImage)?

    private static func logoImage(_ path: String) -> CIImage? {
        if let kept = sceneLock.withLock({ logoPicture }), kept.path == path { return kept.image }
        guard let image = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else { return nil }
        let placed = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        sceneLock.withLock { logoPicture = (path, placed) }
        return placed
    }

    /// Where the logo lies: like in the editor, a part of the shorter side wide, in its corner.
    static func logoRect(_ logo: Watermark, size: CGSize) -> CGRect {
        let short = min(canvas.width, canvas.height)
        let width = CGFloat(logo.size) * short, height = width * size.height / max(1, size.width)
        let margin = 0.035 * short
        let left = logo.corner == .topLeft || logo.corner == .bottomLeft
        let bottom = logo.corner == .bottomLeft || logo.corner == .bottomRight
        return CGRect(x: left ? margin : canvas.width - margin - width, y: bottom ? margin : canvas.height - margin - height, width: width, height: height)
    }

    /// Where the shortcut is shown: at the bottom in the middle.
    static func keyRect(size: CGSize) -> CGRect { CGRect(x: canvas.midX - size.width / 2, y: 56, width: size.width, height: size.height) }

    /// Where a meme of this size lies.
    static func memeRect(_ c: LiveConfig, size: CGSize) -> CGRect {
        let margin: CGFloat = 40
        let area = canvas.insetBy(dx: margin, dy: margin)
        let boxHeight = min(area.height, canvas.height * CGFloat(c.memeSize))
        let rect = fit(size, in: CGRect(x: 0, y: 0, width: area.width, height: boxHeight))
        let x: CGFloat, y: CGFloat
        switch c.memeSpot {
        case .center: x = canvas.midX - rect.width / 2; y = canvas.midY - rect.height / 2
        case .topLeft: x = area.minX; y = area.maxY - rect.height
        case .topRight: x = area.maxX - rect.width; y = area.maxY - rect.height
        case .bottomLeft: x = area.minX; y = area.minY
        case .bottomRight: x = area.maxX - rect.width; y = area.minY
        }
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    private static func memeLayer(_ meme: CIImage, alpha: Double, transparent: Bool, config: LiveConfig, over base: CIImage) -> CIImage {
        let rect = memeRect(config, size: meme.extent.size)
        let picture = place(meme, filling: rect)
        let border = CIImage(color: .white).cropped(to: rect.insetBy(dx: -4, dy: -4))
        return faded(transparent ? picture : picture.composited(over: border), alpha).composited(over: base)
    }

    static func compose(config: LiveConfig, source: CIImage?, camera: CIImage?, effects: LiveEffects = LiveEffects(),
                        meme: (image: CIImage, alpha: Double, transparent: Bool)? = nil) -> CIImage {
        var image = background
        switch config.scene {
        case .webcam:
            if let camera { image = place(camera, filling: canvas).composited(over: image) }
        case .source:
            // In a scene the source lies on the screen of the device, otherwise it fills the picture.
            let shape = source.map { $0.extent.width / max(1, $0.extent.height) } ?? canvas.width / canvas.height
            let screen = config.mockup.map { $0.screen(out: canvas.size, aspect: shape, placement: MockupPlacement()) }
            let drawn = config.mockup.flatMap { kind in screen.flatMap { scene(kind, screen: $0) } }
            if let drawn { image = drawn.image.composited(over: image) }
            if let source {
                let e = source.extent
                let rect = fit(e.size, in: screen ?? canvas)
                var video = source.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
                    .concatenating(CGAffineTransform(scaleX: rect.width / max(1, e.width), y: rect.height / max(1, e.height)))
                    .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
                    .cropped(to: rect)
                if let mask = drawn?.mask {
                    video = video.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
                }
                image = video.composited(over: image)
                func onCanvas(_ n: CGPoint) -> CGPoint { CGPoint(x: rect.minX + n.x * rect.width, y: rect.maxY - n.y * rect.height) }
                if config.trail, let trail = trailImage(effects.trail.map { (onCanvas($0.at), $0.age) }) {
                    image = trail.composited(over: image)
                }
                if config.clicks {
                    for click in effects.clicks where click.age < clickLife {
                        let p = CGFloat(click.age / clickLife)
                        let at = onCanvas(click.at), scale = 0.45 + 1.1 * p
                        let ring = clickRing.transformed(by: CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: at.x, y: at.y)))
                        image = faded(ring, Double(pow(1 - p, 1.3))).composited(over: image)
                    }
                }
            }
            if config.bubble, let camera { image = bubble(camera, over: image, config: config) }
        }
        if config.logoOn == true, let logo = config.logo, let picture = logoImage(logo.file) {
            let rect = logoRect(logo, size: picture.extent.size)
            let placed = picture.transformed(by: CGAffineTransform(scaleX: rect.width / max(1, picture.extent.width), y: rect.height / max(1, picture.extent.height))
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
            image = faded(placed, logo.opacity).composited(over: image)
        }
        if let key = effects.key, key.age < keyLife {
            let pill = keyImage(key.label)
            let rect = keyRect(size: pill.extent.size)
            let alpha = min(1, key.age / 0.1, (keyLife - key.age) / 0.25)
            image = faded(pill.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY)), alpha).composited(over: image)
        }
        if let meme { image = memeLayer(meme.image, alpha: meme.alpha, transparent: meme.transparent, config: config, over: image) }
        return image.cropped(to: canvas)
    }

    static func faded(_ image: CIImage, _ alpha: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(alpha), y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: CGFloat(alpha), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(alpha), w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha)),
        ])
    }
}
