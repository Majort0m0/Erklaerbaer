import Foundation
import CoreGraphics

// MARK: - Recording data (written once by the recorder)

/// Metadata about the raw screen recording.
struct RecordingInfo: Codable {
    var videoFile: String = "screen.mov"
    /// Pixel size of the captured video.
    var pixelWidth: Int
    var pixelHeight: Int
    /// Pixels per point of the captured area (2 on Retina displays).
    var pointPixelScale: Double
    var duration: Double
    var createdAt: Date
    var sourceName: String
    var hasMicrophone: Bool
    /// Separate webcam recording (same timeline as the screen video), e.g. "camera.mov".
    var cameraFile: String? = nil
    /// Roles of the audio tracks in the screen video in track order ("system", "mic").
    var audioTracks: [String]? = nil
    /// A second window recorded at the same time (same timeline as the screen video), e.g. "window2.mov".
    var overlayVideoFile: String? = nil
    var overlaySourceName: String? = nil
    var overlayAspect: Double? = nil
    /// Rotation of an imported video (a phone video filmed upright), applied when rendering.
    var rotation: Int? = nil
    /// An empty project: the video is only a black canvas for inserted clips, pictures and texts.
    var blank: Bool? = nil

    var audioRoles: [String] { audioTracks ?? (hasMicrophone ? ["mic"] : []) }
    var hasSystemAudio: Bool { audioRoles.contains("system") }
    var hasMicAudio: Bool { audioRoles.contains("mic") }
}

/// One cursor position sample. Coordinates are normalized to the captured
/// area (0…1, origin top-left); `c` indexes `CursorTrack.images`.
struct CursorSample: Codable {
    var t: Double
    var x: Double
    var y: Double
    var c: Int
}

struct ClickEvent: Codable, Hashable {
    var t: Double
    var x: Double
    var y: Double
}

/// A captured system cursor image. Sizes and hotspot are in points, hotspot origin top-left.
struct CursorImageInfo: Codable {
    var file: String
    var width: Double
    var height: Double
    var hotX: Double
    var hotY: Double
}

struct CursorTrack: Codable {
    var samples: [CursorSample] = []
    var clicks: [ClickEvent] = []
    var images: [CursorImageInfo] = []
    /// Keyboard shortcuts (optional: older projects don't have it).
    var keys: [KeyEvent]? = nil
}

// MARK: - Edit settings (changed in the editor)

/// Hides a region of the recording (pixelate or blur) for a time range.
/// Rect is normalized to the captured area (origin top-left).
struct BlurMask: Codable, Identifiable, Equatable {
    enum Style: String, Codable, CaseIterable, Identifiable {
        case pixelate = "Verpixeln"
        case blur = "Weichzeichnen"
        var id: String { rawValue }
    }
    var id = UUID()
    var start: Double
    var end: Double
    var x: Double = 0.35
    var y: Double = 0.4
    var width: Double = 0.3
    var height: Double = 0.12
    var style: Style = .pixelate
}

/// A part of the recording that is removed in the output (source time).
struct CutRange: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    /// Transition between the parts before and after the cut (timeline seconds, 0 = hard cut).
    var dissolve: Double = 0
    var transition: TransitionStyle = .dissolve
    /// Made by an automatic step (shown and reviewable as such); nil = cut by hand.
    var origin: CutOrigin? = nil
}

/// Where an automatic cut comes from.
enum CutOrigin: String, Codable {
    case filler, pause, transcript
    var label: String {
        switch self {
        case .filler: return "Füllwort"
        case .pause: return "Pause"
        case .transcript: return "Text"
        }
    }
    var short: String {
        switch self {
        case .filler: return "äh"
        case .pause: return "Pause"
        case .transcript: return "Text"
        }
    }
}

extension CutRange {
    /// Tolerant decoding: cuts of older projects have no `dissolve`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        dissolve = try c.decodeIfPresent(Double.self, forKey: .dissolve) ?? 0
        transition = try c.decodeIfPresent(TransitionStyle.self, forKey: .transition) ?? .dissolve
        origin = try c.decodeIfPresent(CutOrigin.self, forKey: .origin)
    }

    /// Automatic cuts get a short sound crossfade instead of a hard join (no clipped words).
    static let speechCrossfade = 0.06
}

/// Transition at a cut: the last `length` timeline seconds before `aEnd` (from `aStart`) blend
/// into the first ones from `bStart`; the output then continues with the recording from `resume`
/// (the two parts are pushed over each other, the output gets shorter by `length`).
/// A transition into the part with this key from the part that plays before it.
struct JoinTransition: Codable, Identifiable, Equatable {
    var id = UUID()
    var key: Double
    var length: Double
    var style: TransitionStyle = .dissolve
}

struct Dissolve: Equatable {
    var cutID: UUID
    var aStart: Double
    var aEnd: Double
    var bStart: Double
    var resume: Double
    var length: Double
    var style: TransitionStyle = .dissolve
}

struct ZoomSegment: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var scale: Double
    var isAuto: Bool = true
}

enum OutputAspect: String, Codable, CaseIterable, Identifiable {
    case wide = "16:9"
    case vertical = "9:16"
    case square = "1:1"
    case classic = "4:3"
    case source = "Original"
    var id: String { rawValue }
}

enum BackgroundStyle: Codable, Equatable {
    case gradient(Int)
    case color(red: Double, green: Double, blue: Double)
    case image(path: String)
}

struct EditSettings: Codable, Equatable {
    var trimStart: Double = 0
    var trimEnd: Double? = nil
    var cuts: [CutRange] = []
    /// Split points of the recording (source time): the clip is shown in parts that can be
    /// selected and removed one by one.
    var splits: [Double] = []
    var masks: [BlurMask] = []
    var captions: [Caption] = []
    var showCaptions: Bool = true
    var showShortcuts: Bool = true
    var captionSize: Double = 1
    var captionLanguage: String = "de-DE"

    var background: BackgroundStyle = .gradient(0)
    var backgroundBlur: Double = 0
    var aspect: OutputAspect = .wide
    /// Fraction of the shorter output side used as padding around the recording.
    var padding: Double = 0.07
    /// Corner radius at a 1080p reference size.
    var cornerRadius: Double = 16
    /// 0…1
    var shadow: Double = 0.6

    var showCursor: Bool = true
    var cursorScale: Double = 1.6
    /// 0 = raw movement, 1 = very smooth
    var cursorSmoothing: Double = 0.6
    var clickEffect: Bool = true
    var hideIdleCursor: Bool = false

    var autoZoom: Bool = true
    var defaultZoom: Double = 1.8
    var zoomSegments: [ZoomSegment] = []

    // Camera bubble
    var cameraVisible: Bool = true
    var cameraShape: CameraShape = .circle
    /// Fraction of the shorter output side.
    var cameraSize: Double = 0.26
    var cameraCorner: CameraCorner = .bottomRight
    /// Free position (bubble center, normalized to the output, origin top-left); overrides the corner.
    var cameraX: Double? = nil
    var cameraY: Double? = nil
    var cameraMirror: Bool = true
    var cameraShadow: Bool = true

    // Audio (0…1)
    var micVolume: Double = 1
    var micMuted: Bool = false
    var systemVolume: Double = 0.8
    var systemMuted: Bool = false
    /// Remove the speaker echo (system audio picked up by the mic).
    var removeEcho: Bool = true
    /// 0 = off … 1 = strong (cursor and camera).
    var motionBlur: Double = 0.5
    var clickSound: Bool = false
    var clickVolume: Double = 0.5

    // Audio lanes
    /// Ranges in which a lane is silent.
    var audioMutes: [AudioMute] = []
    var voiceOvers: [VoiceOverClip] = []
    var voiceOverVolume: Double = 1
    var voiceOverMuted: Bool = false
    /// Lower microphone and system audio while a voice-over plays.
    var duckUnderVoiceOver: Bool = true
    var duckLevel: Double = 0.25

    /// Lower thirds and title cards.
    var texts: [TextOverlay] = []
    /// How far the intro/outro card is pushed over the recording (cross dissolve, seconds).
    var introOverlap: Double = 0
    var outroOverlap: Double = 0

    /// Faster/slower parts and freeze frames (see `TimeMap`).
    var speeds: [SpeedRange] = []
    var freezes: [FreezeFrame] = []
    /// Fade from/to black at the very beginning and end of the video (seconds).
    var fadeIn: Double = 0
    var fadeOut: Double = 0

    var music: BackgroundMusic? = nil
    var voice = VoiceEnhancement()
    var cameraLayouts: [CameraLayoutRange] = []
    var annotations: [Annotation] = []
    var images: [ImageOverlay] = []
    var watermark: Watermark? = nil
    var inserts: [InsertClip] = []
    var chapters: [Chapter] = []
    /// Recognized words (for cutting via the transcript).
    var words: [TranscriptWord] = []
    /// Videos on top of the recording (picture in picture, second recorded window).
    var videoOverlays: [VideoOverlay] = []
    /// Color correction.
    var color = ColorGrade()
    /// Design new lower thirds and title cards get (nil: the classic dark one).
    var textDesign: TextDesign? = nil
    /// Bring the whole mix to a loudness target when exporting.
    var masterNormalize: Bool = false
    var masterTargetLUFS: Double = -16
    /// The second recorded window's overlay was deleted (don't add it again).
    var dismissedSyncedOverlay: Bool = false
    /// Vertical center of the recording in the output (0 top … 1 bottom); nil = centered.
    var contentY: Double? = nil
    /// Layout of the formats not shown right now (key: `OutputAspect.rawValue`).
    var formatLayouts: [String: FormatLayout] = [:]
    var captionStyle = CaptionStyle()
    var captionSource: CaptionSource = .microphone
    /// Highlight around the mouse pointer.
    var cursorEffect: CursorEffect = .none
    var cursorEffectSize: Double = 1
    /// Parts with their own highlight (the cursor lane).
    var cursorRanges: [CursorRange] = []
    /// Order of the video's parts on the timeline (their source start times), nil: the original order.
    var clipOrder: [Double]? = nil
    /// Lanes whose new items are not tied to the video ("texts", "media", "voiceOver").
    var freeLanes: [String] = []
    /// Lanes locked against changes with the mouse.
    var lockedLanes: [String] = []
    /// Transitions where two parts meet without a cut between them (after a split or a move).
    var joinTransitions: [JoinTransition] = []
    /// Short "whoosh" at zooms and transitions.
    var soundEffects: Bool = false
    var soundEffectVolume: Double = 0.35

    /// Short side of the exported video in pixels.
    var exportShortSide: Int = 1080
    var exportHEVC: Bool = false
    var exportFPS: Int = 60
}

extension EditSettings {
    /// Longest cross dissolve (cuts, intro, outro).
    static let maxDissolve = 5.0

    /// Parts of the source that end up in the output (trim range minus cuts, source time) and
    /// the cross dissolves between them. A part that follows a dissolve starts `length` later:
    /// its first seconds are shown during the dissolve.
    func cutLayout(duration: Double) -> (segments: [ClosedRange<Double>], dissolves: [Dissolve]) {
        let natural = naturalCutLayout(duration: duration)
        guard clipOrder != nil || !joinTransitions.isEmpty else { return natural }
        let arranged = arrangedParts(duration: duration, natural: natural)
        return (arranged.parts.map(\.range), arranged.dissolves)
    }

    /// A stretch of the video on the timeline (between cuts, split points and inserted clips).
    struct ClipPart: Equatable {
        /// Identifies the part in `clipOrder`: where it begins in the recording.
        let key: Double
        let range: ClosedRange<Double>
    }

    /// The parts of the video in the order they play.
    func clipParts(duration: Double) -> [ClipPart] { arrangedParts(duration: duration, natural: naturalCutLayout(duration: duration)).parts }

    /// The parts in playing order with the transitions between them: those at cuts whose two
    /// sides still follow each other, and those set on any other join.
    private func arrangedParts(duration: Double, natural: (segments: [ClosedRange<Double>], dissolves: [Dissolve]))
        -> (parts: [ClipPart], dissolves: [Dissolve]) {
        var parts = clipParts(duration: duration, natural: natural)
        var dissolves: [Dissolve] = []
        for d in natural.dissolves {
            let i = parts.firstIndex { abs($0.range.upperBound - d.aEnd) < 1e-6 }
            if let i, i + 1 < parts.count, abs(parts[i + 1].range.lowerBound - d.resume) < 1e-6 {
                dissolves.append(d)
            } else if let b = parts.firstIndex(where: { abs($0.range.lowerBound - d.resume) < 1e-6 }) {
                // The parts no longer meet: the part gets back what the transition had taken.
                parts[b] = ClipPart(key: parts[b].key, range: d.bStart...parts[b].range.upperBound)
            }
        }
        let map = timeMap(duration: duration)
        for t in joinTransitions {
            guard let i = parts.firstIndex(where: { abs($0.key - t.key) < 1e-4 }), i > 0 else { continue }
            let a = parts[i - 1], b = parts[i]
            guard !dissolves.contains(where: { abs($0.aEnd - a.range.upperBound) < 1e-6 && abs($0.resume - b.range.lowerBound) < 1e-6 }) else { continue }
            let length = min(t.length, Self.maxDissolve, map.length(a.range) - 0.05, map.length(b.range) / 2)
            guard length > 0.03 else { continue }
            let aStart = map.source(map.timeline(a.range.upperBound) - length)
            let resume = map.source(map.timeline(b.range.lowerBound) + length)
            dissolves.append(Dissolve(cutID: t.id, aStart: aStart, aEnd: a.range.upperBound, bStart: b.range.lowerBound,
                                      resume: resume, length: length, style: t.style))
            parts[i] = ClipPart(key: b.key, range: resume...b.range.upperBound)
        }
        return (parts, dissolves)
    }

    private func clipParts(duration: Double, natural: (segments: [ClosedRange<Double>], dissolves: [Dissolve])) -> [ClipPart] {
        let map = timeMap(duration: duration)
        let borders = splits + inserts.flatMap { [$0.sourceRange.lowerBound, $0.sourceRange.upperBound] }
        var parts: [ClipPart] = []
        for seg in natural.segments {
            let inner = Set(borders.filter { $0 > seg.lowerBound + 1e-6 && $0 < seg.upperBound - 1e-6 }).sorted()
            let points = [seg.lowerBound] + inner + [seg.upperBound]
            for (a, b) in zip(points, points.dropFirst()) where map.length(a...b) > 0.002 {
                // After a transition the part begins later than the cut ended; the key stays the cut's end.
                let key = a == seg.lowerBound ? (natural.dissolves.first { abs($0.resume - a) < 1e-6 }?.bStart ?? a) : a
                parts.append(ClipPart(key: key, range: a...b))
            }
        }
        guard let order = clipOrder else { return parts }
        // Parts in the saved order; new ones (after a split or a restored cut) follow their neighbor.
        var ordered: [ClipPart] = []
        for key in order {
            if let p = parts.first(where: { abs($0.key - key) < 1e-4 }), !ordered.contains(p) { ordered.append(p) }
        }
        for (i, p) in parts.enumerated() where !ordered.contains(p) {
            if i > 0, let j = ordered.firstIndex(of: parts[i - 1]) { ordered.insert(p, at: j + 1) } else { ordered.insert(p, at: 0) }
        }
        return ordered
    }

    /// The edited timeline: kept parts only, in playing order.
    func editMap(duration: Double) -> TimeMap {
        TimeMap(base: timeMap(duration: duration), parts: keptSegments(duration: duration))
    }

    /// Kept parts of the recording in their original order, with the transitions at the cuts.
    func naturalCutLayout(duration: Double) -> (segments: [ClosedRange<Double>], dissolves: [Dissolve]) {
        let start = max(0, trimStart), end = min(trimEnd ?? duration, duration)
        guard end > start else { return ([], []) }
        // Transition lengths are timeline seconds (speed changes and freeze frames applied).
        let map = timeMap(duration: duration)
        // Kept parts and the cut that ends right before each of them. Slivers under 20 ms on the
        // timeline are dropped (an inserted clip is a tiny source range, but long on the timeline).
        var parts: [(lo: Double, hi: Double, before: CutRange?)] = []
        var cursor = start
        var gapCut: CutRange?
        for cut in cuts.sorted(by: { $0.start < $1.start }) {
            let cs = max(start, cut.start), ce = min(end, cut.end)
            guard ce > cs else { continue }
            if cs > cursor, map.length(cursor...cs) > 0.02 { parts.append((cursor, cs, gapCut)) }
            if ce > cursor { cursor = ce; gapCut = cut }
        }
        if end > cursor, map.length(cursor...end) > 0.02 { parts.append((cursor, end, gapCut)) }

        var segments: [ClosedRange<Double>] = []
        var dissolves: [Dissolve] = []
        for part in parts {
            var lo = part.lo
            if let prev = segments.last, let cut = part.before, cut.dissolve > 0.001 {
                let length = min(cut.dissolve, Self.maxDissolve, map.length(prev) - 0.05, map.length(part.lo...part.hi) / 2)
                if length > 0.03 {
                    let aStart = map.source(map.timeline(prev.upperBound) - length)
                    let resume = map.source(map.timeline(part.lo) + length)
                    dissolves.append(Dissolve(cutID: cut.id, aStart: aStart, aEnd: prev.upperBound, bStart: part.lo,
                                              resume: resume, length: length, style: cut.transition))
                    lo = resume
                }
            }
            segments.append(lo...part.hi)
        }
        return (segments, dissolves)
    }

    /// Parts of the source that end up in the output, in order (source time).
    func keptSegments(duration: Double) -> [ClosedRange<Double>] {
        cutLayout(duration: duration).segments
    }

    func dissolves(duration: Double) -> [Dissolve] {
        cutLayout(duration: duration).dissolves
    }

    /// Part of the intro that plays over the start of the recording (cross dissolve).
    func introOverlapLength(duration: Double) -> Double {
        guard let intro, introOverlap > 0.01, let first = keptSegments(duration: duration).first else { return 0 }
        let length = min(introOverlap, intro.length - 0.2, timeMap(duration: duration).length(first) / 2, Self.maxDissolve)
        return length > 0.03 ? length : 0
    }

    /// Part of the outro that plays over the end of the recording (cross dissolve).
    func outroOverlapLength(duration: Double) -> Double {
        guard let outro, outroOverlap > 0.01, let last = keptSegments(duration: duration).last else { return 0 }
        let length = min(outroOverlap, outro.length - 0.2, timeMap(duration: duration).length(last) / 2, Self.maxDissolve)
        return length > 0.03 ? length : 0
    }

    /// Time the intro plays before the recording starts (its length minus the overlap).
    func introLead(duration: Double) -> Double { introDuration - introOverlapLength(duration: duration) }
    /// Time the outro plays after the recording ends.
    func outroLead(duration: Double) -> Double { outroDuration - outroOverlapLength(duration: duration) }

    /// Length of the output: intro + kept parts of the recording + outro (overlaps counted once).
    func outputDuration(duration: Double) -> Double {
        let map = timeMap(duration: duration)
        return introLead(duration: duration) + keptSegments(duration: duration).reduce(0) { $0 + map.length($1) }
            + outroLead(duration: duration)
    }
}

enum CameraShape: String, Codable, CaseIterable, Identifiable {
    case circle = "Kreis"
    case roundedSquare = "Abgerundet"
    case rectangle = "Rechteck"
    /// The person without background (Vision person segmentation on the Mac).
    case cutout = "Freigestellt"
    var id: String { rawValue }
}

enum CameraCorner: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .topLeft: return "Oben links"
        case .topRight: return "Oben rechts"
        case .bottomLeft: return "Unten links"
        case .bottomRight: return "Unten rechts"
        }
    }
}

extension EditSettings {
    /// Tolerant decoding: keys missing in older projects keep their default value.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        trimStart = try v(.trimStart, trimStart)
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        cuts = try v(.cuts, cuts)
        splits = try v(.splits, splits)
        masks = try v(.masks, masks)
        captions = try v(.captions, captions)
        showCaptions = try v(.showCaptions, showCaptions)
        showShortcuts = try v(.showShortcuts, showShortcuts)
        captionSize = try v(.captionSize, captionSize)
        captionLanguage = try v(.captionLanguage, captionLanguage)
        background = try v(.background, background)
        backgroundBlur = try v(.backgroundBlur, backgroundBlur)
        aspect = try v(.aspect, aspect)
        padding = try v(.padding, padding)
        cornerRadius = try v(.cornerRadius, cornerRadius)
        shadow = try v(.shadow, shadow)
        showCursor = try v(.showCursor, showCursor)
        cursorScale = try v(.cursorScale, cursorScale)
        cursorSmoothing = try v(.cursorSmoothing, cursorSmoothing)
        clickEffect = try v(.clickEffect, clickEffect)
        hideIdleCursor = try v(.hideIdleCursor, hideIdleCursor)
        autoZoom = try v(.autoZoom, autoZoom)
        defaultZoom = try v(.defaultZoom, defaultZoom)
        zoomSegments = try v(.zoomSegments, zoomSegments)
        cameraVisible = try v(.cameraVisible, cameraVisible)
        cameraShape = try v(.cameraShape, cameraShape)
        cameraSize = try v(.cameraSize, cameraSize)
        cameraCorner = try v(.cameraCorner, cameraCorner)
        cameraX = try c.decodeIfPresent(Double.self, forKey: .cameraX)
        cameraY = try c.decodeIfPresent(Double.self, forKey: .cameraY)
        cameraMirror = try v(.cameraMirror, cameraMirror)
        cameraShadow = try v(.cameraShadow, cameraShadow)
        micVolume = try v(.micVolume, micVolume)
        micMuted = try v(.micMuted, micMuted)
        systemVolume = try v(.systemVolume, systemVolume)
        systemMuted = try v(.systemMuted, systemMuted)
        removeEcho = try v(.removeEcho, removeEcho)
        motionBlur = try v(.motionBlur, motionBlur)
        clickSound = try v(.clickSound, clickSound)
        clickVolume = try v(.clickVolume, clickVolume)
        audioMutes = try v(.audioMutes, audioMutes)
        voiceOvers = try v(.voiceOvers, voiceOvers)
        voiceOverVolume = try v(.voiceOverVolume, voiceOverVolume)
        voiceOverMuted = try v(.voiceOverMuted, voiceOverMuted)
        duckUnderVoiceOver = try v(.duckUnderVoiceOver, duckUnderVoiceOver)
        duckLevel = try v(.duckLevel, duckLevel)
        texts = try v(.texts, texts)
        introOverlap = try v(.introOverlap, introOverlap)
        outroOverlap = try v(.outroOverlap, outroOverlap)
        speeds = try v(.speeds, speeds)
        freezes = try v(.freezes, freezes)
        fadeIn = try v(.fadeIn, fadeIn)
        fadeOut = try v(.fadeOut, fadeOut)
        music = try c.decodeIfPresent(BackgroundMusic.self, forKey: .music)
        voice = try v(.voice, voice)
        cameraLayouts = try v(.cameraLayouts, cameraLayouts)
        annotations = try v(.annotations, annotations)
        images = try v(.images, images)
        watermark = try c.decodeIfPresent(Watermark.self, forKey: .watermark)
        inserts = try v(.inserts, inserts)
        chapters = try v(.chapters, chapters)
        words = try v(.words, words)
        videoOverlays = try v(.videoOverlays, videoOverlays)
        color = try v(.color, color)
        textDesign = try c.decodeIfPresent(TextDesign.self, forKey: .textDesign)
        masterNormalize = try v(.masterNormalize, masterNormalize)
        masterTargetLUFS = try v(.masterTargetLUFS, masterTargetLUFS)
        dismissedSyncedOverlay = try v(.dismissedSyncedOverlay, dismissedSyncedOverlay)
        contentY = try c.decodeIfPresent(Double.self, forKey: .contentY)
        formatLayouts = try v(.formatLayouts, formatLayouts)
        captionStyle = try v(.captionStyle, captionStyle)
        captionSource = try v(.captionSource, captionSource)
        cursorEffect = try v(.cursorEffect, cursorEffect)
        cursorEffectSize = try v(.cursorEffectSize, cursorEffectSize)
        cursorRanges = try v(.cursorRanges, cursorRanges)
        clipOrder = try c.decodeIfPresent([Double].self, forKey: .clipOrder)
        freeLanes = try v(.freeLanes, freeLanes)
        lockedLanes = try v(.lockedLanes, lockedLanes)
        joinTransitions = try v(.joinTransitions, joinTransitions)
        soundEffects = try v(.soundEffects, soundEffects)
        soundEffectVolume = try v(.soundEffectVolume, soundEffectVolume)
        exportShortSide = try v(.exportShortSide, exportShortSide)
        exportHEVC = try v(.exportHEVC, exportHEVC)
        exportFPS = try v(.exportFPS, exportFPS)
    }
}

// MARK: - Project bundle on disk

/// A `.screenkast` folder: screen.mov, recording.json, cursor.json, edit.json, cursors/*.png
final class Project {
    let url: URL
    var info: RecordingInfo
    var cursor: CursorTrack
    var settings: EditSettings

    var videoURL: URL { url.appendingPathComponent(info.videoFile) }
    var cameraURL: URL? { info.cameraFile.map { url.appendingPathComponent($0) } }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var effectiveTrimEnd: Double { min(settings.trimEnd ?? info.duration, info.duration) }

    init(url: URL, info: RecordingInfo, cursor: CursorTrack, settings: EditSettings) {
        self.url = url
        self.info = info
        self.cursor = cursor
        self.settings = settings
    }

    static let fileExtension = "screenkast"

    /// ~/Movies/Erklärbär. The folder of the app's former name (Screenkast) is renamed once, so
    /// existing recordings come along; if that fails, the old folder stays in use.
    static var libraryURL: URL {
        let fm = FileManager.default
        let movies = fm.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        let dir = movies.appendingPathComponent("Erklärbär", isDirectory: true)
        let old = movies.appendingPathComponent("Screenkast", isDirectory: true)
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
            do { try fm.moveItem(at: old, to: dir) } catch { return old }
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func makeNewProjectURL(date: Date = Date(), in folder: URL = Project.libraryURL) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        var url = folder.appendingPathComponent("Aufnahme \(f.string(from: date)).\(fileExtension)", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("Aufnahme \(f.string(from: date)) \(n).\(fileExtension)", isDirectory: true)
            n += 1
        }
        return url
    }

    static func load(from url: URL) throws -> Project {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let info = try dec.decode(RecordingInfo.self, from: Data(contentsOf: url.appendingPathComponent("recording.json")))
        let cursor = (try? dec.decode(CursorTrack.self, from: Data(contentsOf: url.appendingPathComponent("cursor.json")))) ?? CursorTrack()
        var settings: EditSettings
        if let data = try? Data(contentsOf: url.appendingPathComponent("edit.json")),
           let s = try? dec.decode(EditSettings.self, from: data) {
            settings = s
        } else {
            // A new recording gets the default style.
            settings = StyleLibrary.newProjectSettings(projectURL: url)
            settings.zoomSegments = AutoZoom.segments(for: cursor.clicks, duration: info.duration, scale: settings.defaultZoom)
        }
        return Project(url: url, info: info, cursor: cursor, settings: settings)
    }

    func saveAll() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let enc = Self.encoder
        try enc.encode(info).write(to: url.appendingPathComponent("recording.json"), options: .atomic)
        try enc.encode(cursor).write(to: url.appendingPathComponent("cursor.json"), options: .atomic)
        try saveSettings()
    }

    func saveSettings() throws {
        try Self.encoder.encode(settings).write(to: url.appendingPathComponent("edit.json"), options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }

    /// All projects in the standard folder, newest first.
    static func listLibrary() -> [URL] { listProjects(in: libraryURL) }

    /// All projects directly in `folder`, newest first.
    static func listProjects(in folder: URL) -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { $0.pathExtension == fileExtension && fm.fileExists(atPath: $0.appendingPathComponent("recording.json").path) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da > db
            }
    }
}

// MARK: - Output geometry

enum OutputGeometry {
    /// Output video size for the given settings and source pixel size (always even numbers).
    static func size(aspect: OutputAspect, shortSide: Int, sourceSize: CGSize) -> CGSize {
        let s = Double(shortSide)
        func even(_ v: Double) -> CGFloat { CGFloat(Int((v / 2).rounded()) * 2) }
        switch aspect {
        case .wide: return CGSize(width: even(s * 16 / 9), height: even(s))
        case .vertical: return CGSize(width: even(s), height: even(s * 16 / 9))
        case .square: return CGSize(width: even(s), height: even(s))
        case .classic: return CGSize(width: even(s * 4 / 3), height: even(s))
        case .source:
            let w = max(1, sourceSize.width), h = max(1, sourceSize.height)
            if w >= h { return CGSize(width: even(s * w / h), height: even(s)) }
            return CGSize(width: even(s), height: even(s * h / w))
        }
    }
}
