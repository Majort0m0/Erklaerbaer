import AppKit
import CoreImage
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - Capture

enum ScreenshotCapture {
    /// A still image of a display, a window or a region. macOS's capture service sometimes fails
    /// for a moment ("Error in creating screenshot", e.g. while a window is still moving to the
    /// front): it is tried three times, then the same part of the screen is taken directly.
    static func capture(_ target: CaptureTarget, excluding apps: [SCRunningApplication]) async throws -> CGImage {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await captureOnce(target, excluding: apps)
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
            }
        }
        if #available(macOS 15.2, *), let rect = screenRect(target),
           let image = try? await SCScreenshotManager.captureImage(in: rect) {
            return image
        }
        throw lastError ?? CocoaError(.featureUnsupported)
    }

    /// The target in global screen coordinates (points, origin top-left of the main display).
    private static func screenRect(_ target: CaptureTarget) -> CGRect? {
        switch target {
        case .display(let d): return d.frame
        case .window(let w): return w.isOnScreen ? w.frame : nil
        case .region(let d, let r): return r.offsetBy(dx: d.frame.minX, dy: d.frame.minY)
        }
    }

    /// A message for the user (the system's text for -3811 talks about a "stream").
    static func explain(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain {
            return "macOS konnte das Bildschirmfoto gerade nicht erstellen (Bildschirmaufnahme-Dienst, Fehler \(ns.code)). "
                + "Bitte noch einmal versuchen – bei einem Fenster hilft es, es vorher einmal anzuklicken. Tritt der Fehler immer wieder auf, hilft meist ein Neustart des Macs."
        }
        return "Screenshot fehlgeschlagen: \(error.localizedDescription)"
    }

    private static func captureOnce(_ target: CaptureTarget, excluding apps: [SCRunningApplication]) async throws -> CGImage {
        let filter: SCContentFilter
        var region: CGRect?
        switch target {
        case .display(let d): filter = SCContentFilter(display: d, excludingApplications: apps, exceptingWindows: [])
        case .window(let w): filter = SCContentFilter(desktopIndependentWindow: w)
        case .region(let d, let r):
            filter = SCContentFilter(display: d, excludingApplications: apps, exceptingWindows: [])
            region = r
        }
        let scale = CGFloat(filter.pointPixelScale)
        let rect = region ?? filter.contentRect
        let config = SCStreamConfiguration()
        config.width = max(2, Int(rect.width * scale))
        config.height = max(2, Int(rect.height * scale))
        if let region { config.sourceRect = region }
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

// MARK: - Document

enum ShotTool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, ellipse, highlight, text, number, blur, pixelate, crop
    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: return "Auswählen"
        case .arrow: return "Pfeil"
        case .rectangle: return "Rahmen"
        case .ellipse: return "Ellipse"
        case .highlight: return "Marker"
        case .text: return "Text"
        case .number: return "Nummer"
        case .blur: return "Weichzeichnen"
        case .pixelate: return "Verpixeln"
        case .crop: return "Zuschneiden"
        }
    }

    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .number: return "1.circle.fill"
        case .blur: return "drop.halffull"
        case .pixelate: return "square.grid.3x3.fill"
        case .crop: return "crop"
        }
    }

    var key: String {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .highlight: return "h"
        case .text: return "t"
        case .number: return "n"
        case .blur: return "b"
        case .pixelate: return "p"
        case .crop: return "c"
        }
    }
}

/// One drawn item. Points are image pixels (origin top-left); `a`→`b` spans the item.
struct ShotItem: Identifiable, Equatable {
    var id = UUID()
    var kind: ShotTool
    var a: CGPoint
    var b: CGPoint
    var color: AnnotationColor
    var width: Double
    var text: String = ""
    var number: Int = 0

    var rect: CGRect { CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)) }
    var isEffect: Bool { kind == .blur || kind == .pixelate }
}

@MainActor
final class ShotDocument: ObservableObject {
    @Published private(set) var image: CGImage
    @Published var items: [ShotItem] = []
    @Published var selectedID: UUID?
    @Published var tool: ShotTool = .arrow
    @Published var color: AnnotationColor = .red
    @Published var lineWidth: Double = 1
    @Published var editingTextID: UUID?
    @Published var crop: CGRect?
    // Frame around the shot
    @Published var styled: Bool = UserDefaults.standard.object(forKey: "shotStyled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(styled, forKey: "shotStyled") }
    }
    @Published var background: Int = UserDefaults.standard.integer(forKey: "shotBackground") {
        didSet { UserDefaults.standard.set(background, forKey: "shotBackground") }
    }
    @Published var padding: Double = UserDefaults.standard.object(forKey: "shotPadding") as? Double ?? 0.07 {
        didSet { UserDefaults.standard.set(padding, forKey: "shotPadding") }
    }
    @Published var cornerRadius: Double = 12
    @Published var shadow = true

    private var undoStack: [(CGImage, [ShotItem])] = []
    private var redoStack: [(CGImage, [ShotItem])] = []
    private var baseCache: (key: String, image: CGImage)?
    private var backgroundCache: (key: String, image: CGImage)?
    private let ci = CIContext(options: [.cacheIntermediates: false])
    let name: String

    init(image: CGImage, name: String) {
        self.image = image
        self.name = name
    }

    var size: CGSize { CGSize(width: image.width, height: image.height) }
    var nextNumber: Int { (items.filter { $0.kind == .number }.map(\.number).max() ?? 0) + 1 }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Editing

    func checkpoint() {
        undoStack.append((image, items))
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack = []
        objectWillChange.send()
    }

    func discardCheckpoint() {
        _ = undoStack.popLast()
        objectWillChange.send()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append((image, items))
        (image, items) = last
        selectedID = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append((image, items))
        (image, items) = next
        selectedID = nil
    }

    func update(_ id: UUID, _ change: (inout ShotItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        checkpoint()
        items.removeAll { $0.id == id }
        selectedID = nil
    }

    /// Topmost item under `p` (image pixels).
    func item(at p: CGPoint) -> ShotItem? {
        let slack = max(8, CGFloat(size.width) / 150)
        return items.reversed().first { item in
            switch item.kind {
            case .arrow:
                let d = Self.distance(p, segment: item.a, item.b)
                return d < slack + CGFloat(item.width) * 6
            case .text, .number:
                return Self.textFrame(item, imageWidth: size.width).insetBy(dx: -slack, dy: -slack).contains(p)
            default:
                return item.rect.insetBy(dx: -slack, dy: -slack).contains(p)
            }
        }
    }

    static func distance(_ p: CGPoint, segment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        guard l2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Crops the image to `rect` (items move along).
    func applyCrop() {
        guard let crop, crop.width > 8, crop.height > 8,
              let cropped = image.cropping(to: crop.integral.intersection(CGRect(origin: .zero, size: size))) else { self.crop = nil; return }
        checkpoint()
        let o = crop.integral.origin
        image = cropped
        items = items.map { var i = $0; i.a.x -= o.x; i.a.y -= o.y; i.b.x -= o.x; i.b.y -= o.y; return i }
        self.crop = nil
        tool = .select
    }

    // MARK: Rendering

    /// Unit for line widths and text (scales with the image).
    static func unit(_ imageWidth: CGFloat) -> CGFloat { max(2, max(imageWidth, 600) / 400) }

    /// Layout of the output: the shot inside the frame.
    var layout: (out: CGSize, imageRect: CGRect) {
        let s = size
        guard styled else { return (s, CGRect(origin: .zero, size: s)) }
        let pad = CGFloat(padding) * max(s.width, s.height)
        return (CGSize(width: s.width + 2 * pad, height: s.height + 2 * pad), CGRect(x: pad, y: pad, width: s.width, height: s.height))
    }

    /// The shot with its blur/pixelate areas applied (cached).
    func baseImage() -> CGImage {
        let effects = items.filter(\.isEffect)
        let key = "\(ObjectIdentifier(image))|" + effects.map { "\($0.kind.rawValue)\($0.rect)" }.joined(separator: ";")
        if let baseCache, baseCache.key == key { return baseCache.image }
        guard !effects.isEmpty else { baseCache = (key, image); return image }
        var img = CIImage(cgImage: image)
        let H = CGFloat(image.height)
        for e in effects {
            // CI's origin is bottom-left.
            let r = CGRect(x: e.rect.minX, y: H - e.rect.maxY, width: e.rect.width, height: e.rect.height).integral.intersection(img.extent)
            guard r.width > 2, r.height > 2 else { continue }
            let effect: CIImage = e.kind == .pixelate
                ? img.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(8, min(r.width, r.height) / 7),
                                                                                   kCIInputCenterKey: CIVector(x: r.minX, y: r.minY)])
                : img.cropped(to: r).clampedToExtent().applyingGaussianBlur(sigma: max(8, CGFloat(image.width) / 120))
            img = effect.cropped(to: r).composited(over: img)
        }
        let out = ci.createCGImage(img, from: CGRect(x: 0, y: 0, width: image.width, height: image.height)) ?? image
        baseCache = (key, out)
        return out
    }

    /// Background, framed shot, then the drawn items: the image that is copied or saved.
    func render() -> CGImage? {
        let (out, imageRect) = layout
        guard let ctx = CGContext(data: nil, width: Int(out.width), height: Int(out.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Top-left origin like the items.
        ctx.translateBy(x: 0, y: out.height)
        ctx.scaleBy(x: 1, y: -1)
        drawBackground(in: ctx, out: out, imageRect: imageRect)
        ctx.saveGState()
        ctx.translateBy(x: imageRect.minX, y: imageRect.minY)
        for item in items { Self.draw(item, in: ctx, imageWidth: size.width) }
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// Frame background and the (rounded, shadowed) base image. `ctx` has a top-left origin.
    func drawBackground(in ctx: CGContext, out: CGSize, imageRect: CGRect) {
        let base = baseImage()
        if styled {
            let key = "\(background)|\(Int(out.width))x\(Int(out.height))"
            if backgroundCache?.key != key {
                let bg = Backgrounds.gradientImage(index: background, size: out)
                backgroundCache = ci.createCGImage(bg, from: CGRect(origin: .zero, size: out)).map { (key, $0) }
            }
            if let cg = backgroundCache?.image {
                ctx.draw(cg, in: CGRect(origin: .zero, size: out))
            }
            let radius = CGFloat(cornerRadius) * max(1, size.width / 1200)
            let path = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            if shadow {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: size.width / 160), blur: size.width / 40,
                              color: CGColor(gray: 0, alpha: 0.45))
                ctx.addPath(path)
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fillPath()
                ctx.restoreGState()
            }
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            drawFlipped(base, in: imageRect, ctx: ctx)
            ctx.restoreGState()
        } else {
            drawFlipped(base, in: imageRect, ctx: ctx)
        }
    }

    /// CGContext.draw puts images upside down in a flipped context.
    private func drawFlipped(_ img: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    static func textFont(_ item: ShotItem, imageWidth: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: unit(imageWidth) * 9 * CGFloat(item.width), weight: .bold)
    }

    static func textFrame(_ item: ShotItem, imageWidth: CGFloat) -> CGRect {
        if item.kind == .number {
            let r = unit(imageWidth) * 7 * CGFloat(item.width)
            return CGRect(x: item.a.x - r, y: item.a.y - r, width: 2 * r, height: 2 * r)
        }
        let s = NSAttributedString(string: item.text.isEmpty ? " " : item.text, attributes: [.font: textFont(item, imageWidth: imageWidth)])
        let size = s.boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin]).size
        return CGRect(origin: item.a, size: CGSize(width: ceil(size.width), height: ceil(size.height)))
    }

    /// Draws one item (vector) into a context with a top-left origin, in image pixels.
    static func draw(_ item: ShotItem, in ctx: CGContext, imageWidth: CGFloat) {
        let u = unit(imageWidth)
        let (r, g, b) = item.color.rgb
        let color = CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
        let outline = item.color == .white ? CGColor(gray: 0, alpha: 0.8) : CGColor(gray: 1, alpha: 0.95)
        let line = u * 1.6 * CGFloat(item.width)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch item.kind {
        case .arrow:
            let from = item.a, to = item.b
            guard hypot(to.x - from.x, to.y - from.y) > 2 else { return }
            let head = line * 4.2
            let angle = atan2(to.y - from.y, to.x - from.x)
            let shaftEnd = CGPoint(x: to.x - cos(angle) * head * 0.8, y: to.y - sin(angle) * head * 0.8)
            let headPath = CGMutablePath()
            headPath.move(to: to)
            headPath.addLine(to: CGPoint(x: to.x - cos(angle - 0.45) * head, y: to.y - sin(angle - 0.45) * head))
            headPath.addLine(to: CGPoint(x: to.x - cos(angle + 0.45) * head, y: to.y - sin(angle + 0.45) * head))
            headPath.closeSubpath()
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for (stroke, w) in [(outline, line * 1.9), (color, line)] {
                ctx.setStrokeColor(stroke); ctx.setFillColor(stroke); ctx.setLineWidth(w)
                ctx.move(to: from); ctx.addLine(to: shaftEnd); ctx.strokePath()
                ctx.addPath(headPath); ctx.drawPath(using: .fillStroke)
            }
        case .rectangle, .ellipse:
            let rect = item.rect
            guard rect.width > 1, rect.height > 1 else { return }
            let path = item.kind == .ellipse ? CGPath(ellipseIn: rect, transform: nil)
                : CGPath(roundedRect: rect, cornerWidth: min(rect.width, rect.height) * 0.06, cornerHeight: min(rect.width, rect.height) * 0.06, transform: nil)
            ctx.setShadow(offset: .zero, blur: line * 1.2, color: CGColor(gray: 0, alpha: 0.35))
            ctx.addPath(path); ctx.setStrokeColor(color); ctx.setLineWidth(line); ctx.strokePath()
        case .highlight:
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: item.color == .white ? 0.3 : 0.42))
            ctx.fill(item.rect)
        case .text:
            let font = textFont(item, imageWidth: imageWidth)
            let frame = textFrame(item, imageWidth: imageWidth)
            let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            let text = item.text.isEmpty ? " " : item.text
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: outline) ?? .white,
                                                        .strokeColor: NSColor(cgColor: outline) ?? .white, .strokeWidth: 8])
                .draw(with: frame, options: [.usesLineFragmentOrigin])
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .red])
                .draw(with: frame, options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
        case .number:
            let frame = textFrame(item, imageWidth: imageWidth)
            ctx.setShadow(offset: CGSize(width: 0, height: u * 0.6), blur: u * 2, color: CGColor(gray: 0, alpha: 0.4))
            ctx.setFillColor(color)
            ctx.fillEllipse(in: frame)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(outline); ctx.setLineWidth(u * 0.9 * CGFloat(item.width)); ctx.strokeEllipse(in: frame.insetBy(dx: u * 0.45, dy: u * 0.45))
            let font = NSFont.systemFont(ofSize: frame.height * 0.55, weight: .heavy)
            let s = NSAttributedString(string: "\(item.number)", attributes: [.font: font, .foregroundColor: item.color == .white || item.color == .yellow ? NSColor.black : NSColor.white])
            let size = s.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            s.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        case .blur, .pixelate, .select, .crop:
            break   // effects are part of the base image
        }
    }

    // MARK: Output

    func pngData() -> Data? {
        guard let cg = render() else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    func copyToPasteboard() {
        guard let data = pngData() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        if let image = NSImage(data: data) { pb.writeObjects([image]) }
    }

    /// Writes a PNG into ~/Pictures/Erklärbär (for dragging out and quick saving).
    func savedFile() -> URL? {
        guard let data = pngData() else { return nil }
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Erklärbär")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".png")
        do { try data.write(to: url); return url } catch { return nil }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = name + ".png"
        guard panel.runModal() == .OK, let url = panel.url, let cg = render() else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        let data = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg"
            ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) : rep.representation(using: .png, properties: [:])
        try? data?.write(to: url)
    }
}
