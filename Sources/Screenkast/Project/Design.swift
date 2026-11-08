import Foundation
import CoreGraphics
import ImageIO

// MARK: - Colors

/// A color stored in a project (sRGB, 0…1).
struct RGBAColor: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    static let white = RGBAColor(r: 1, g: 1, b: 1)
    static let black = RGBAColor(r: 0, g: 0, b: 0)
    static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)

    func with(alpha: Double) -> RGBAColor { RGBAColor(r: r, g: g, b: b, a: alpha) }

    /// "#RRGGBB" (for the key of cached images).
    var key: String { String(format: "%02x%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255)) }
}

// MARK: - Text design

enum TextFont: String, Codable, CaseIterable, Identifiable {
    case system, rounded, serif, mono, condensed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Standard"
        case .rounded: return "Rund"
        case .serif: return "Serifen"
        case .mono: return "Mono"
        case .condensed: return "Schmal"
        }
    }
}

enum TextWeight: String, Codable, CaseIterable, Identifiable {
    case regular, medium, semibold, bold, heavy
    var id: String { rawValue }
    var label: String {
        switch self {
        case .regular: return "Normal"
        case .medium: return "Mittel"
        case .semibold: return "Halbfett"
        case .bold: return "Fett"
        case .heavy: return "Extrafett"
        }
    }
    /// Core Text weight trait (−1 … 1).
    var trait: CGFloat {
        switch self {
        case .regular: return 0
        case .medium: return 0.23
        case .semibold: return 0.3
        case .bold: return 0.4
        case .heavy: return 0.56
        }
    }
}

/// Look of a lower third (and the text of title cards): font, colors, box, accent bar.
struct TextDesign: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var name: String = "Eigenes Design"
    var font: TextFont = .system
    var weight: TextWeight = .bold
    var titleColor: RGBAColor = .white
    var subtitleColor: RGBAColor = RGBAColor(r: 1, g: 1, b: 1, a: 0.8)
    /// Box behind the text (alpha 0 = no box).
    var box: RGBAColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.86)
    /// Colored bar on the leading edge of the box (nil = none).
    var accent: RGBAColor? = nil
    /// Corner radius as a fraction of the title size (0 = square corners).
    var cornerRadius: Double = 0.32
    /// Inner spacing factor.
    var padding: Double = 1
    var shadow: Bool = false
    var uppercaseTitle: Bool = false
    /// Title-card background (nil: the project's background).
    var cardBackground: RGBAColor? = nil

    var hasBox: Bool { box.a > 0.01 }

    /// Identifies the rendered look (cache key, ignores id and name).
    var key: String {
        [font.rawValue, weight.rawValue, titleColor.key, subtitleColor.key, box.key, accent?.key ?? "-",
         String(format: "%.2f-%.2f", cornerRadius, padding), shadow ? "s" : "", uppercaseTitle ? "u" : "",
         cardBackground?.key ?? "-"].joined(separator: ",")
    }

    /// Same look, other identity (when applied to an item or saved as a new preset).
    func copy(named name: String? = nil) -> TextDesign {
        var d = self
        d.id = UUID()
        if let name { d.name = name }
        return d
    }
}

extension TextDesign {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = TextDesign()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? base.name
        font = try c.decodeIfPresent(TextFont.self, forKey: .font) ?? base.font
        weight = try c.decodeIfPresent(TextWeight.self, forKey: .weight) ?? base.weight
        titleColor = try c.decodeIfPresent(RGBAColor.self, forKey: .titleColor) ?? base.titleColor
        subtitleColor = try c.decodeIfPresent(RGBAColor.self, forKey: .subtitleColor) ?? base.subtitleColor
        box = try c.decodeIfPresent(RGBAColor.self, forKey: .box) ?? base.box
        accent = try c.decodeIfPresent(RGBAColor.self, forKey: .accent)
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? base.cornerRadius
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? base.padding
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? base.shadow
        uppercaseTitle = try c.decodeIfPresent(Bool.self, forKey: .uppercaseTitle) ?? base.uppercaseTitle
        cardBackground = try c.decodeIfPresent(RGBAColor.self, forKey: .cardBackground)
    }

    private static func fixed(_ n: Int) -> UUID { UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", n))! }
    static let accentBlue = RGBAColor(r: 0.17, g: 0.42, b: 0.98)

    /// The four classic styles (projects from before designs existed use them).
    static func legacy(_ style: TextStyle) -> TextDesign {
        switch style {
        case .dark: return presets[0]
        case .light: return presets[1]
        case .accent: return presets[2]
        case .plain: return presets[3]
        }
    }

    /// Built-in designs (fixed ids, so a project remembers which one it uses).
    static let presets: [TextDesign] = [
        TextDesign(id: fixed(1), name: "Dunkel", box: RGBAColor(r: 0, g: 0, b: 0, a: 0.86),
                   cardBackground: RGBAColor(r: 0.06, g: 0.06, b: 0.08)),
        TextDesign(id: fixed(2), name: "Hell", titleColor: RGBAColor(r: 0.08, g: 0.08, b: 0.1),
                   subtitleColor: RGBAColor(r: 0.32, g: 0.32, b: 0.36), box: RGBAColor(r: 1, g: 1, b: 1, a: 0.95),
                   cardBackground: RGBAColor(r: 0.97, g: 0.97, b: 0.98)),
        TextDesign(id: fixed(3), name: "Farbig", box: accentBlue.with(alpha: 0.96), cardBackground: accentBlue),
        TextDesign(id: fixed(4), name: "Ohne Box", box: .clear, shadow: true),
        TextDesign(id: fixed(5), name: "Akzentbalken", box: RGBAColor(r: 0.07, g: 0.07, b: 0.09, a: 0.9),
                   accent: RGBAColor(r: 1, g: 0.75, b: 0.05), cornerRadius: 0.08),
        TextDesign(id: fixed(6), name: "Glas", font: .rounded, weight: .semibold,
                   box: RGBAColor(r: 1, g: 1, b: 1, a: 0.22), cornerRadius: 0.6, shadow: true),
        TextDesign(id: fixed(7), name: "Etikett", font: .condensed, weight: .heavy,
                   titleColor: RGBAColor(r: 0.08, g: 0.08, b: 0.08), subtitleColor: RGBAColor(r: 0.15, g: 0.15, b: 0.15, a: 0.85),
                   box: RGBAColor(r: 1, g: 0.84, b: 0.04), cornerRadius: 0, uppercaseTitle: true),
        TextDesign(id: fixed(8), name: "Klassisch", font: .serif, weight: .semibold,
                   subtitleColor: RGBAColor(r: 0.93, g: 0.86, b: 0.7), box: RGBAColor(r: 0.1, g: 0.08, b: 0.06, a: 0.88),
                   accent: RGBAColor(r: 0.85, g: 0.68, b: 0.35), cornerRadius: 0.05,
                   cardBackground: RGBAColor(r: 0.1, g: 0.08, b: 0.06)),
        TextDesign(id: fixed(9), name: "Terminal", font: .mono, weight: .medium,
                   titleColor: RGBAColor(r: 0.35, g: 1, b: 0.55), subtitleColor: RGBAColor(r: 0.7, g: 0.9, b: 0.75, a: 0.85),
                   box: RGBAColor(r: 0.03, g: 0.05, b: 0.04, a: 0.92), cornerRadius: 0.15,
                   cardBackground: RGBAColor(r: 0.02, g: 0.04, b: 0.03)),
        TextDesign(id: fixed(10), name: "Pastell", font: .rounded, weight: .bold,
                   titleColor: RGBAColor(r: 0.2, g: 0.13, b: 0.32), subtitleColor: RGBAColor(r: 0.38, g: 0.3, b: 0.5),
                   box: RGBAColor(r: 0.93, g: 0.88, b: 1, a: 0.96), cornerRadius: 0.8,
                   cardBackground: RGBAColor(r: 0.93, g: 0.88, b: 1)),
        TextDesign(id: fixed(11), name: "Signal", weight: .heavy, box: RGBAColor(r: 0.9, g: 0.15, b: 0.2, a: 0.96),
                   cornerRadius: 0.12, uppercaseTitle: true, cardBackground: RGBAColor(r: 0.75, g: 0.1, b: 0.15)),
        TextDesign(id: fixed(12), name: "Minimal", font: .system, weight: .semibold, box: .clear,
                   accent: RGBAColor(r: 1, g: 1, b: 1, a: 0.9), shadow: true),
    ]
}

// MARK: - Pictures

/// Frame around a picture or video overlay.
enum PictureFrame: String, Codable, CaseIterable, Identifiable {
    case none, rounded, border, polaroid, circle
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Pur"
        case .rounded: return "Abgerundet"
        case .border: return "Rahmen"
        case .polaroid: return "Foto"
        case .circle: return "Kreis"
        }
    }
}

// MARK: - Annotation shapes

/// Outline of a frame or spotlight.
enum AnnotationShape: String, Codable, CaseIterable, Identifiable {
    case rectangle, rounded, ellipse
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rectangle: return "Eckig"
        case .rounded: return "Abgerundet"
        case .ellipse: return "Rund/Oval"
        }
    }
    var icon: String {
        switch self {
        case .rectangle: return "rectangle"
        case .rounded: return "rectangle.roundedtop"
        case .ellipse: return "oval"
        }
    }
}

// MARK: - Color grading

/// Simple color correction (exposure, contrast, saturation, warmth).
struct ColorGrade: Codable, Equatable {
    /// Exposure in stops (−2 … 2).
    var exposure: Double = 0
    /// 0.5 … 1.5
    var contrast: Double = 1
    /// 0 (black and white) … 2
    var saturation: Double = 1
    /// −1 (cool) … 1 (warm)
    var temperature: Double = 0
    /// −1 … 1
    var vibrance: Double = 0
    var applyToScreen: Bool = false
    var applyToCamera: Bool = true
    /// Inserted clips and video overlays.
    var applyToMedia: Bool = true

    var isNeutral: Bool {
        abs(exposure) < 0.005 && abs(contrast - 1) < 0.005 && abs(saturation - 1) < 0.005
            && abs(temperature) < 0.005 && abs(vibrance) < 0.005
    }

    struct Preset: Identifiable {
        let id: String
        let name: String
        let exposure, contrast, saturation, temperature, vibrance: Double
    }

    static let presets: [Preset] = [
        Preset(id: "neutral", name: "Neutral", exposure: 0, contrast: 1, saturation: 1, temperature: 0, vibrance: 0),
        Preset(id: "vivid", name: "Lebendig", exposure: 0.05, contrast: 1.12, saturation: 1.12, temperature: 0, vibrance: 0.35),
        Preset(id: "warm", name: "Warm", exposure: 0.05, contrast: 1.05, saturation: 1.05, temperature: 0.45, vibrance: 0.1),
        Preset(id: "cool", name: "Kühl", exposure: 0, contrast: 1.05, saturation: 0.95, temperature: -0.4, vibrance: 0),
        Preset(id: "bright", name: "Aufhellen", exposure: 0.45, contrast: 0.95, saturation: 1.02, temperature: 0.05, vibrance: 0.1),
        Preset(id: "contrast", name: "Kontrast", exposure: 0, contrast: 1.3, saturation: 1.05, temperature: 0, vibrance: 0),
        Preset(id: "muted", name: "Matt", exposure: 0.05, contrast: 0.85, saturation: 0.75, temperature: 0.1, vibrance: -0.2),
        Preset(id: "bw", name: "Schwarzweiß", exposure: 0, contrast: 1.15, saturation: 0, temperature: 0, vibrance: 0),
    ]

    mutating func apply(_ p: Preset) {
        exposure = p.exposure; contrast = p.contrast; saturation = p.saturation
        temperature = p.temperature; vibrance = p.vibrance
    }
}

extension ColorGrade {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        applyToScreen = try c.decodeIfPresent(Bool.self, forKey: .applyToScreen) ?? false
        applyToCamera = try c.decodeIfPresent(Bool.self, forKey: .applyToCamera) ?? true
        applyToMedia = try c.decodeIfPresent(Bool.self, forKey: .applyToMedia) ?? true
    }
}

// MARK: - Video overlays

/// A video shown on top of the recording (picture in picture). Like a voice-over it starts at a
/// source moment and plays in real time; `duration` is in timeline seconds. A synced overlay is
/// a second window recorded together with the screen: its frames follow the recording (cuts,
/// speed changes), the overlay only decides where and when it is visible.
struct VideoOverlay: Codable, Identifiable, Equatable {
    var id = UUID()
    var file: String
    var name: String
    /// Source time where it appears.
    var start: Double
    /// Visible length (timeline seconds).
    var duration: Double
    var fileOffset: Double = 0
    var fileDuration: Double
    var synced: Bool = false
    /// Center (normalized output, origin top-left) and width as a fraction of the output width.
    var x: Double = 0.75
    var y: Double = 0.32
    var width: Double = 0.38
    /// Width / height of the video.
    var aspect: Double = 16.0 / 9.0
    var opacity: Double = 1
    var volume: Double = 1
    var muted: Bool = false
    var frame: PictureFrame = .rounded
    var shadow: Bool = true
    /// Rotation of the video in degrees (portrait phone videos: 90).
    var rotation: Int = 0
    /// Not tied to the video: `start` is a timeline position and stays put when parts of the video
    /// are cut or moved (nil: follows the moment of the video it was placed on).
    var free: Bool? = nil
    var isFree: Bool { free == true }
}

/// Rotation (degrees) of a video track's preferred transform, and the matching orientation.
enum VideoRotation {
    static func degrees(_ t: CGAffineTransform) -> Int {
        let a = Int((atan2(t.b, t.a) * 180 / .pi).rounded())
        return ((a % 360) + 360) % 360
    }

    static func orientation(_ degrees: Int) -> CGImagePropertyOrientation {
        switch ((degrees % 360) + 360) % 360 {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }
}

extension VideoOverlay {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        file = try c.decode(String.self, forKey: .file)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? file
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 1
        fileOffset = try c.decodeIfPresent(Double.self, forKey: .fileOffset) ?? 0
        fileDuration = try c.decodeIfPresent(Double.self, forKey: .fileDuration) ?? duration
        synced = try c.decodeIfPresent(Bool.self, forKey: .synced) ?? false
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.75
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.32
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0.38
        aspect = try c.decodeIfPresent(Double.self, forKey: .aspect) ?? 16.0 / 9.0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        frame = try c.decodeIfPresent(PictureFrame.self, forKey: .frame) ?? .rounded
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? true
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        free = try c.decodeIfPresent(Bool.self, forKey: .free)
    }

    /// Layer of each overlay: overlays that overlap in time play on separate tracks (timeline time).
    static func layers(_ overlays: [VideoOverlay], timeline: (Double) -> Double) -> (layerOf: [UUID: Int], count: Int) {
        var ends: [Double] = []
        var layerOf: [UUID: Int] = [:]
        for o in overlays.filter({ !$0.synced }).sorted(by: { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }) {
            let s = timeline(o.start), e = s + o.duration
            if let i = ends.firstIndex(where: { $0 <= s + 1e-6 }) {
                layerOf[o.id] = i; ends[i] = e
            } else {
                layerOf[o.id] = ends.count; ends.append(e)
            }
        }
        return (layerOf, ends.count)
    }
}

// MARK: - Layout per output format

/// Where the recording, the camera and the captions sit in one output format. Every format keeps
/// its own layout: switching from 16:9 to 9:16 and back restores each one.
struct FormatLayout: Codable, Equatable {
    var padding: Double
    /// Vertical center of the recording (0 top … 1 bottom); nil = centered.
    var contentY: Double?
    var cameraCorner: CameraCorner
    var cameraX: Double?
    var cameraY: Double?
    var cameraSize: Double
    var captionX: Double
    var captionY: Double

    /// Starting layout of a format: in portrait (Reels, Shorts, TikTok) the recording sits at the
    /// top, the camera large at the bottom and the captions in between.
    static func standard(for aspect: OutputAspect) -> FormatLayout {
        switch aspect {
        case .vertical:
            return FormatLayout(padding: 0.04, contentY: 0.27, cameraCorner: .bottomRight, cameraX: 0.5, cameraY: 0.77,
                                cameraSize: 0.5, captionX: 0.5, captionY: 0.535)
        case .square:
            return FormatLayout(padding: 0.05, contentY: 0.4, cameraCorner: .bottomRight, cameraX: nil, cameraY: nil,
                                cameraSize: 0.27, captionX: 0.5, captionY: 0.87)
        case .wide, .classic, .source:
            return FormatLayout(padding: 0.07, contentY: nil, cameraCorner: .bottomRight, cameraX: nil, cameraY: nil,
                                cameraSize: 0.26, captionX: 0.5, captionY: 0.9)
        }
    }
}

extension EditSettings {
    var currentLayout: FormatLayout {
        FormatLayout(padding: padding, contentY: contentY, cameraCorner: cameraCorner, cameraX: cameraX, cameraY: cameraY,
                     cameraSize: cameraSize, captionX: captionStyle.x, captionY: captionStyle.y)
    }

    mutating func apply(_ l: FormatLayout) {
        padding = l.padding; contentY = l.contentY
        cameraCorner = l.cameraCorner; cameraX = l.cameraX; cameraY = l.cameraY; cameraSize = l.cameraSize
        captionStyle.x = l.captionX; captionStyle.y = l.captionY
    }

    /// Changes the output format; the layout of the old one is kept, the new one gets its own.
    mutating func switchAspect(to new: OutputAspect) {
        guard new != aspect else { return }
        formatLayouts[aspect.rawValue] = currentLayout
        aspect = new
        apply(formatLayouts[new.rawValue] ?? FormatLayout.standard(for: new))
    }
}

// MARK: - Caption style

enum CaptionMode: String, Codable, CaseIterable, Identifiable {
    case sentence, highlight, chunks, word
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sentence: return "Ganze Zeilen"
        case .highlight: return "Zeilen, Wort hervorgehoben"
        case .chunks: return "Wortgruppen"
        case .word: return "Wort für Wort"
        }
    }
}

/// Look and position of the captions.
struct CaptionStyle: Codable, Equatable {
    var mode: CaptionMode = .sentence
    var font: TextFont = .system
    var weight: TextWeight = .bold
    var textColor: RGBAColor = .white
    /// The word being spoken (highlight, word groups).
    var highlightColor: RGBAColor = RGBAColor(r: 1, g: 0.84, b: 0.04)
    /// Box behind the text (alpha 0 = none).
    var box: RGBAColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.86)
    /// Thick dark outline around the letters (the TikTok look).
    var outline: Bool = false
    var uppercase: Bool = false
    /// Words pop in (word groups, word for word).
    var pop: Bool = true
    /// Center of the caption block (normalized output, origin top-left).
    var x: Double = 0.5
    var y: Double = 0.9

    var key: String {
        [mode.rawValue, font.rawValue, weight.rawValue, textColor.key, highlightColor.key, box.key,
         outline ? "o" : "", uppercase ? "u" : ""].joined(separator: ",")
    }

    struct Preset: Identifiable {
        let id: String
        let name: String
        let apply: (inout CaptionStyle) -> Void
    }

    static let presets: [Preset] = [
        Preset(id: "classic", name: "Klassisch") { s in
            s.mode = .sentence; s.font = .system; s.weight = .bold; s.textColor = .white
            s.box = RGBAColor(r: 0, g: 0, b: 0, a: 0.86); s.outline = false; s.uppercase = false
        },
        Preset(id: "karaoke", name: "Karaoke") { s in
            s.mode = .highlight; s.font = .rounded; s.weight = .heavy; s.textColor = .white
            s.highlightColor = RGBAColor(r: 1, g: 0.84, b: 0.04); s.box = RGBAColor(r: 0, g: 0, b: 0, a: 0.7); s.outline = false; s.uppercase = false
        },
        Preset(id: "tiktok", name: "TikTok") { s in
            s.mode = .chunks; s.font = .system; s.weight = .heavy; s.textColor = .white
            s.highlightColor = RGBAColor(r: 1, g: 0.84, b: 0.04); s.box = .clear; s.outline = true; s.uppercase = true; s.pop = true
        },
        Preset(id: "word", name: "Wort für Wort") { s in
            s.mode = .word; s.font = .rounded; s.weight = .heavy; s.textColor = .white
            s.box = .clear; s.outline = true; s.uppercase = false; s.pop = true
        },
        Preset(id: "minimal", name: "Minimal") { s in
            s.mode = .sentence; s.font = .system; s.weight = .semibold; s.textColor = .white
            s.box = .clear; s.outline = true; s.uppercase = false
        },
        Preset(id: "bright", name: "Hell") { s in
            s.mode = .highlight; s.font = .system; s.weight = .bold; s.textColor = RGBAColor(r: 0.1, g: 0.1, b: 0.12)
            s.highlightColor = RGBAColor(r: 0.17, g: 0.42, b: 0.98); s.box = RGBAColor(r: 1, g: 1, b: 1, a: 0.94); s.outline = false; s.uppercase = false
        },
    ]
}

extension CaptionStyle {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptionStyle()
        mode = try c.decodeIfPresent(CaptionMode.self, forKey: .mode) ?? d.mode
        font = try c.decodeIfPresent(TextFont.self, forKey: .font) ?? d.font
        weight = try c.decodeIfPresent(TextWeight.self, forKey: .weight) ?? d.weight
        textColor = try c.decodeIfPresent(RGBAColor.self, forKey: .textColor) ?? d.textColor
        highlightColor = try c.decodeIfPresent(RGBAColor.self, forKey: .highlightColor) ?? d.highlightColor
        box = try c.decodeIfPresent(RGBAColor.self, forKey: .box) ?? d.box
        outline = try c.decodeIfPresent(Bool.self, forKey: .outline) ?? d.outline
        uppercase = try c.decodeIfPresent(Bool.self, forKey: .uppercase) ?? d.uppercase
        pop = try c.decodeIfPresent(Bool.self, forKey: .pop) ?? d.pop
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? d.x
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? d.y
    }
}

// MARK: - Cursor effects

enum CursorEffect: String, Codable, CaseIterable, Identifiable {
    case none, halo, spotlight, lens, hidden
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Keiner"
        case .halo: return "Leuchtkreis"
        case .spotlight: return "Spotlight"
        case .lens: return "Lupe"
        case .hidden: return "Cursor ausblenden"
        }
    }
    var icon: String {
        switch self {
        case .none: return "cursorarrow"
        case .halo: return "circle.dotted"
        case .spotlight: return "flashlight.on.fill"
        case .lens: return "magnifyingglass"
        case .hidden: return "cursorarrow.slash"
        }
    }
    /// Choices for the whole video (hiding it everywhere is the "Cursor anzeigen" switch).
    static var global: [CursorEffect] { [.none, .halo, .spotlight, .lens] }
}

/// A part of the video with its own pointer highlight (or no pointer).
struct CursorRange: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var effect: CursorEffect = .spotlight
    var size: Double = 1
}
