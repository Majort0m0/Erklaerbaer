import AppKit
import CoreImage
import ImageIO

/// A logo kept in the app for the live picture (file in App Support/Screenkast/Logos).
struct LiveLogo: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    /// File name inside the logo folder.
    var file: String
    var corner: CameraCorner = .topRight
    /// Width as a part of the shorter side of the picture.
    var size: Double = 0.14
    var opacity: Double = 0.9

    init(name: String, file: String) {
        self.name = name
        self.file = file
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Logo"
        file = try c.decode(String.self, forKey: .file)
        corner = try c.decodeIfPresent(CameraCorner.self, forKey: .corner) ?? .topRight
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 0.14
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.9
    }
}

/// A strip at the top or bottom of the live picture: text on the left, a logo on the right.
struct LiveBanner: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    /// First line (e.g. the name) and an optional second one (e.g. a role or a web address).
    var title = ""
    var subtitle = ""
    /// A logo of the library on the right (nil: none).
    var logoID: UUID?
    /// Its full path; filled in when the banner is shown.
    var logoPath: String?
    var atTop = false
    /// Height as a part of the picture height.
    var height = 0.11
    var font: TextFont = .system
    var background = RGBAColor(r: 0.11, g: 0.13, b: 0.32, a: 0.9)
    var text = RGBAColor.white
    /// A thin line on the side towards the picture (nil: none).
    var accent: RGBAColor? = RGBAColor(r: 1, g: 0.8, b: 0.08)

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fresh = LiveBanner()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        logoID = try c.decodeIfPresent(UUID.self, forKey: .logoID)
        logoPath = try c.decodeIfPresent(String.self, forKey: .logoPath)
        atTop = try c.decodeIfPresent(Bool.self, forKey: .atTop) ?? false
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? fresh.height
        font = try c.decodeIfPresent(TextFont.self, forKey: .font) ?? .system
        background = try c.decodeIfPresent(RGBAColor.self, forKey: .background) ?? fresh.background
        text = try c.decodeIfPresent(RGBAColor.self, forKey: .text) ?? .white
        accent = try c.decodeIfPresent(RGBAColor.self, forKey: .accent)
    }

    var label: String { title.isEmpty ? (subtitle.isEmpty ? "Banner" : subtitle) : title }
}

/// All logos and banners of the live mode, kept between launches.
@MainActor
final class LiveOverlayLibrary: ObservableObject {
    /// SCREENKAST_OVERLAY_FOLDER puts it elsewhere (pictures of the control window in tests).
    static let shared = LiveOverlayLibrary(folder: ProcessInfo.processInfo.environment["SCREENKAST_OVERLAY_FOLDER"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Screenkast", isDirectory: true))

    @Published private(set) var logos: [LiveLogo] = []
    @Published private(set) var banners: [LiveBanner] = []
    let logoFolder: URL
    private let store: URL
    private var thumbnails: [String: NSImage] = [:]
    private var bannerPictures: [String: NSImage] = [:]

    private struct Stored: Codable {
        var logos: [LiveLogo]
        var banners: [LiveBanner]
    }

    init(folder: URL) {
        logoFolder = folder.appendingPathComponent("Logos", isDirectory: true)
        store = folder.appendingPathComponent("LiveLogosUndBanner.json")
        if let data = try? Data(contentsOf: store), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            logos = stored.logos.filter { FileManager.default.fileExists(atPath: logoFolder.appendingPathComponent($0.file).path) }
            banners = stored.banners
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Stored(logos: logos, banners: banners)) { try? data.write(to: store, options: .atomic) }
    }

    func path(of logo: LiveLogo) -> String { logoFolder.appendingPathComponent(logo.file).path }

    func logo(_ id: UUID?) -> LiveLogo? { id.flatMap { id in logos.first { $0.id == id } } }
    func banner(_ id: UUID?) -> LiveBanner? { id.flatMap { id in banners.first { $0.id == id } } }

    /// How the logo is drawn in the live picture.
    func watermark(_ logo: LiveLogo) -> Watermark {
        Watermark(file: path(of: logo), corner: logo.corner, size: logo.size, opacity: logo.opacity)
    }

    /// The banner with the full path of its logo, ready for the picture.
    func resolved(_ banner: LiveBanner) -> LiveBanner {
        var copy = banner
        copy.logoPath = logo(banner.logoID).map(path(of:))
        return copy
    }

    // MARK: Logos

    /// Copies the pictures into the app's folder. Returns the new logos.
    @discardableResult
    func addLogos(_ urls: [URL]) throws -> [LiveLogo] {
        try FileManager.default.createDirectory(at: logoFolder, withIntermediateDirectories: true)
        var added: [LiveLogo] = []
        for url in urls {
            let file = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased())
            try FileManager.default.copyItem(at: url, to: logoFolder.appendingPathComponent(file))
            added.append(LiveLogo(name: url.deletingPathExtension().lastPathComponent, file: file))
        }
        logos += added
        save()
        return added
    }

    /// Takes over a logo file that already lies in the logo folder (the single logo of older versions).
    func adopt(file path: String, corner: CameraCorner, size: Double, opacity: Double) -> LiveLogo? {
        let url = URL(fileURLWithPath: path)
        guard url.deletingLastPathComponent().standardizedFileURL == logoFolder.standardizedFileURL,
              FileManager.default.fileExists(atPath: path) else { return nil }
        if let known = logos.first(where: { $0.file == url.lastPathComponent }) { return known }
        var logo = LiveLogo(name: "Logo", file: url.lastPathComponent)
        logo.corner = corner
        logo.size = size
        logo.opacity = opacity
        logos.append(logo)
        save()
        return logo
    }

    func update(_ logo: LiveLogo) {
        guard let i = logos.firstIndex(where: { $0.id == logo.id }), logos[i] != logo else { return }
        logos[i] = logo
        save()
    }

    /// Removes the logo and its file; banners that showed it go on without a logo.
    func remove(logo id: UUID) {
        guard let i = logos.firstIndex(where: { $0.id == id }) else { return }
        let removed = logos.remove(at: i)
        try? FileManager.default.removeItem(atPath: path(of: removed))
        thumbnails[removed.file] = nil
        for j in banners.indices where banners[j].logoID == id { banners[j].logoID = nil }
        save()
    }

    func thumbnail(_ logo: LiveLogo) -> NSImage? {
        if let kept = thumbnails[logo.file] { return kept }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path(of: logo)) as CFURL, nil),
              let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 160,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: picture, size: NSSize(width: picture.width, height: picture.height))
        thumbnails[logo.file] = image
        return image
    }

    // MARK: Banners

    /// A new banner with the name of the Mac's user and the first logo.
    func addBanner() -> LiveBanner {
        var banner = LiveBanner()
        banner.title = NSFullUserName()
        banner.logoID = logos.first?.id
        banners.append(banner)
        save()
        return banner
    }

    func duplicate(banner id: UUID) -> LiveBanner? {
        guard var copy = banner(id) else { return nil }
        copy.id = UUID()
        banners.append(copy)
        save()
        return copy
    }

    func update(_ banner: LiveBanner) {
        guard let i = banners.firstIndex(where: { $0.id == banner.id }), banners[i] != banner else { return }
        banners[i] = banner
        save()
    }

    func remove(banner id: UUID) {
        banners.removeAll { $0.id == id }
        save()
    }

    /// The banner as it lies in the live picture (full width), for the editor's preview.
    func bannerPicture(_ banner: LiveBanner) -> NSImage? {
        cachedBanner(banner, key: "full") { LiveBannerArt.picture(banner, width: LiveCompositor.canvas.width, pictureHeight: LiveCompositor.canvas.height) }
    }

    /// A short piece of the banner, high enough to read, for its tile.
    func bannerThumbnail(_ banner: LiveBanner) -> NSImage? {
        let shown = resolved(banner)
        return cachedBanner(shown, key: "tile") { LiveBannerArt.picture(shown, width: 300, pictureHeight: 110 / CGFloat(shown.height)) }
    }

    private func cachedBanner(_ banner: LiveBanner, key: String, make: () -> CGImage?) -> NSImage? {
        guard let data = try? JSONEncoder().encode(banner), let text = String(data: data, encoding: .utf8) else { return nil }
        let id = key + text
        if let kept = bannerPictures[id] { return kept }
        guard let picture = make() else { return nil }
        if bannerPictures.count > 40 { bannerPictures.removeAll() }
        let image = NSImage(cgImage: picture, size: NSSize(width: picture.width, height: picture.height))
        bannerPictures[id] = image
        return image
    }
}

/// Draws banners (for the live picture and as small pictures in the control window).
enum LiveBannerArt {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [LiveBanner: CIImage] = [:]

    /// The banner as wide as the live picture, origin at 0,0.
    static func image(_ banner: LiveBanner) -> CIImage {
        if let kept = lock.withLock({ cache[banner] }) { return kept }
        let made = picture(banner, width: LiveCompositor.canvas.width, pictureHeight: LiveCompositor.canvas.height)
            .map { CIImage(cgImage: $0) } ?? .empty()
        lock.withLock {
            if cache.count > 8 { cache.removeAll() }
            cache[banner] = made
        }
        return made
    }

    static func picture(_ banner: LiveBanner, width: CGFloat, pictureHeight: CGFloat) -> CGImage? {
        let height = max(8, (pictureHeight * CGFloat(banner.height)).rounded())
        let w = Int(width.rounded()), h = Int(height)
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.setFillColor(banner.background.cgColor)
        c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let accent = banner.accent {
            let line = max(2, height * 0.05)
            c.setFillColor(accent.cgColor)
            c.fill(CGRect(x: 0, y: banner.atTop ? 0 : height - line, width: width, height: line))
        }
        let margin = 0.035 * min(width, pictureHeight)
        var textRight = width - margin

        // The logo on the right, as high as the strip allows.
        if let path = banner.logoPath, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let logo = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: Int(height * 4),
           ] as CFDictionary) {
            let box = CGSize(width: width * 0.3, height: height * 0.68)
            let scale = min(box.width / CGFloat(logo.width), box.height / CGFloat(logo.height))
            let size = CGSize(width: CGFloat(logo.width) * scale, height: CGFloat(logo.height) * scale)
            let rect = CGRect(x: width - margin - size.width, y: (height - size.height) / 2, width: size.width, height: size.height)
            c.interpolationQuality = .high
            c.draw(logo, in: rect)
            textRight = rect.minX - margin
        }

        // The text on the left, vertically centered.
        let two = !banner.subtitle.isEmpty && !banner.title.isEmpty
        let titleSize = height * (two ? 0.34 : 0.42)
        let design = TextDesign(font: banner.font)
        let lines: [(String, CTFont, CGColor)] = [
            (banner.title, TextBlockCache.font(design, size: titleSize, weight: .bold), banner.text.cgColor),
            (banner.subtitle, TextBlockCache.font(design, size: titleSize * 0.66, weight: .regular), banner.text.with(alpha: banner.text.a * 0.82).cgColor),
        ].filter { !$0.0.isEmpty }
        let measured = lines.map { line -> (CTLine, CGFloat, CGFloat) in
            let attributed = NSAttributedString(string: line.0, attributes: [.font: line.1, .foregroundColor: line.2])
            let ctLine = CTLineCreateTruncatedLine(CTLineCreateWithAttributedString(attributed), Double(max(10, textRight - margin)), .end,
                                                   CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [.font: line.1, .foregroundColor: line.2])))
                ?? CTLineCreateWithAttributedString(attributed)
            return (ctLine, CTFontGetAscent(line.1), CTFontGetDescent(line.1))
        }
        let gap = titleSize * 0.12
        let total = measured.reduce(0) { $0 + $1.1 + $1.2 } + gap * CGFloat(max(0, measured.count - 1))
        var top = (height + total) / 2
        for (line, ascent, descent) in measured {
            c.textPosition = CGPoint(x: margin, y: top - ascent)
            CTLineDraw(line, c)
            top -= ascent + descent + gap
        }
        return c.makeImage()
    }
}

/// One logo or banner in the live picture, with how far it has come in (0…1).
enum LiveOverlayDraw {
    case logo(Watermark, alpha: Double)
    /// `shown` moves the strip in from its edge, `alpha` fades it.
    case banner(LiveBanner, shown: Double, alpha: Double)

    /// Everything of the configuration fully shown (pictures without animation, tests).
    static func steady(_ config: LiveConfig) -> [LiveOverlayDraw] {
        var result: [LiveOverlayDraw] = []
        if config.logoOn == true, let logo = config.logo { result.append(.logo(logo, alpha: 1)) }
        if let banner = config.banner { result.append(.banner(banner, shown: 1, alpha: 1)) }
        return result
    }
}

/// Fades logos and slides banners in and out when they change (render queue of the live engine).
struct LiveOverlayAnimator {
    static let duration = 0.35

    private struct Layer<Item> {
        var item: Item
        let key: String
        let start: Double
        var end: Double?
        let slideIn: Bool
        var slideOut = false
    }

    private var logos: [Layer<Watermark>] = []
    private var banners: [Layer<LiveBanner>] = []

    private static func ease(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    mutating func draws(for config: LiveConfig, now: Double) -> [LiveOverlayDraw] {
        let wantedLogo = config.logoOn == true ? config.logo : nil
        update(&logos, wanted: wantedLogo, key: wantedLogo?.file, now: now, slide: false)
        update(&banners, wanted: config.banner, key: config.banner?.id.uuidString, now: now, slide: true)

        func progress<Item>(_ layer: Layer<Item>) -> Double {
            let coming = Self.ease((now - layer.start) / Self.duration)
            let going = layer.end.map { 1 - Self.ease((now - $0) / Self.duration) } ?? 1
            return min(coming, going)
        }
        var result: [LiveOverlayDraw] = logos.map { .logo($0.item, alpha: progress($0)) }
        for layer in banners {
            let p = progress(layer)
            let leaving = layer.end != nil
            let slides = leaving ? layer.slideOut : layer.slideIn
            result.append(.banner(layer.item, shown: slides ? p : 1, alpha: slides ? 1 : p))
        }
        return result
    }

    /// Same item (by key): changed in place. Another one: the old one goes, the new one comes.
    private func update<Item>(_ layers: inout [Layer<Item>], wanted: Item?, key: String?, now: Double, slide: Bool) {
        layers.removeAll { layer in layer.end.map { now - $0 > Self.duration } ?? false }
        if let i = layers.firstIndex(where: { $0.end == nil }) {
            if let wanted, layers[i].key == key {
                layers[i].item = wanted
                return
            }
            layers[i].end = now
            layers[i].slideOut = slide && wanted == nil
        }
        if let wanted, let key {
            // Between two banners the picture fades; into an empty spot the banner slides.
            let replacing = layers.contains { $0.end == now }
            layers.append(Layer(item: wanted, key: key, start: now, slideIn: slide && !replacing))
        }
    }
}
