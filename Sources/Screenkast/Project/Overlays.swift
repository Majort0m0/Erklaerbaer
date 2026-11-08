import Foundation

// MARK: - Audio lanes

/// The audio lanes of the editor timeline.
enum AudioLane: String, Codable, CaseIterable, Identifiable {
    case mic, system, voiceOver, music
    var id: String { rawValue }

    var label: String {
        switch self {
        case .mic: return "Mikrofon"
        case .system: return "Systemton"
        case .voiceOver: return "Voice-over"
        case .music: return "Musik"
        }
    }

    var icon: String {
        switch self {
        case .mic: return "mic.fill"
        case .system: return "speaker.wave.2.fill"
        case .voiceOver: return "waveform.badge.mic"
        case .music: return "music.note"
        }
    }

    /// Role of the composition track(s) of this lane (see `MediaComposition.audioTracks`).
    var role: String {
        switch self {
        case .mic: return "mic"
        case .system: return "system"
        case .voiceOver: return "voiceover"
        case .music: return "music"
        }
    }
}

/// A range in which one audio lane is silent (source time).
struct AudioMute: Codable, Identifiable, Equatable {
    var id = UUID()
    var lane: AudioLane
    var start: Double
    var end: Double
    /// Volume factor in the range (nil or 0: silent). Lets a part of a lane be quieter or louder.
    var gain: Double? = nil
    /// Found automatically (breath sounds); nil = set by hand.
    var kind: AudioRangeKind? = nil
    /// Strength of the voice enhancement in this range (0…1, microphone only); nil = as everywhere.
    var enhance: Double? = nil

    var level: Double { max(0, gain ?? 0) }
    var isMute: Bool { level < 0.001 }
}

enum AudioRangeKind: String, Codable {
    case breath
}

/// Narration recorded in the editor. Placed on the source timeline; several clips can share
/// one file (the recording is split where playback skipped a cut).
/// See `EditSettings.linkedPieces`.
struct LinkedPiece: Equatable {
    let timeline: ClosedRange<Double>
    let fileShift: Double
}

struct VoiceOverClip: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Relative to the project folder, e.g. "voiceover/<uuid>.m4a".
    var file: String
    /// Where the clip starts inside the file (seconds).
    var fileOffset: Double
    /// Source time at which the clip plays.
    var start: Double
    var duration: Double
    /// Volume factor of this clip (nil: 1).
    var volume: Double? = nil
    /// Not tied to the video: `start` is a timeline position and stays put when parts of the video
    /// are cut or moved (nil: follows the moment of the video it was placed on).
    var free: Bool? = nil
    var isFree: Bool { free == true }
    /// A stretch of this clip in the composition belongs to the clip with this id.
    var parent: UUID? = nil
    /// On the music lane (mixed like music) instead of the voice-over lane.
    var music: Bool? = nil
    var isMusic: Bool { music == true }
    /// Fade in/out of this clip in seconds.
    var fadeIn: Double? = nil
    var fadeOut: Double? = nil
    var end: Double { start + duration }
    var gain: Double { max(0, volume ?? 1) }
}

extension VoiceOverClip {
    /// Layer of each clip: clips that overlap go onto separate layers (first free one, by start).
    static func layers(_ clips: [VoiceOverClip]) -> (layerOf: [UUID: Int], count: Int) {
        var layerEnds: [Double] = []
        var layerOf: [UUID: Int] = [:]
        for clip in clips.sorted(by: { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }) {
            if let i = layerEnds.firstIndex(where: { $0 <= clip.start + 1e-6 }) {
                layerOf[clip.id] = i
                layerEnds[i] = clip.end
            } else {
                layerOf[clip.id] = layerEnds.count
                layerEnds.append(clip.end)
            }
        }
        return (layerOf, max(1, layerEnds.count))
    }

    /// Crossfades where clips are pushed over each other: the earlier clip fades out while the
    /// later one fades in, over the overlap (fade-in at the start, fade-out at the end of a clip).
    static func crossfades(_ clips: [VoiceOverClip]) -> [UUID: (fadeIn: Double, fadeOut: Double)] {
        var result: [UUID: (fadeIn: Double, fadeOut: Double)] = [:]
        let sorted = clips.sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
        for (i, a) in sorted.enumerated() {
            for b in sorted[(i + 1)...] where b.start < a.end - 0.01 && b.end > a.end + 0.01 {
                let length = a.end - b.start
                result[a.id, default: (0, 0)].fadeOut = max(result[a.id]?.fadeOut ?? 0, length)
                result[b.id, default: (0, 0)].fadeIn = max(result[b.id]?.fadeIn ?? 0, length)
            }
        }
        return result
    }

    /// Volume factor of a clip at source time `t` (equal-power crossfade curves).
    static func crossfadeGain(at t: Double, clip: VoiceOverClip, fadeIn: Double, fadeOut: Double) -> Double {
        var g = 1.0
        if fadeIn > 0, t < clip.start + fadeIn { g *= sin(max(0, (t - clip.start) / fadeIn) * .pi / 2) }
        if fadeOut > 0, t > clip.end - fadeOut { g *= cos(min(1, (t - (clip.end - fadeOut)) / fadeOut) * .pi / 2) }
        return g
    }
}

// MARK: - Text overlays

enum TextStyle: String, Codable, CaseIterable, Identifiable {
    case dark = "Dunkel"
    case light = "Hell"
    case accent = "Farbig"
    case plain = "Ohne Box"
    var id: String { rawValue }
}

enum TextAlign: String, Codable, CaseIterable, Identifiable {
    case left = "Links"
    case center = "Mitte"
    case right = "Rechts"
    var id: String { rawValue }
}

/// A lower third / text box, or a full-screen title card.
struct TextOverlay: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case lowerThird, titleCard
    }
    /// Title cards can cover the recording (`overlay`) or play before/after it.
    enum Placement: String, Codable, CaseIterable, Identifiable {
        case overlay, intro, outro
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overlay: return "Über dem Video"
            case .intro: return "Vorspann"
            case .outro: return "Abspann"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var placement: Placement = .overlay
    /// Source time (overlay). Intro/outro: `start` = 0, `end` = length of the card.
    var start: Double
    var end: Double
    var title: String
    var subtitle: String = ""
    var style: TextStyle = .dark
    var align: TextAlign = .left
    /// Anchor in the output (normalized, origin top-left): the left edge, center or right edge
    /// of the box (by `align`) and its vertical center. Used by lower thirds.
    var x: Double = 0.06
    var y: Double = 0.8
    /// Text size factor.
    var size: Double = 1
    /// Own design (nil: the classic `style`).
    var design: TextDesign? = nil
    /// Picture or logo shown in the box next to the text (project file).
    var image: String? = nil
    /// Not tied to the video: `start` is a timeline position and stays put when parts of the video
    /// are cut or moved (nil: follows the moment of the video it was placed on).
    var free: Bool? = nil
    var isFree: Bool { free == true }

    var length: Double { end - start }
    /// The look used for rendering.
    var look: TextDesign { design ?? TextDesign.legacy(style) }

    static let fade = 0.35
}

extension EditSettings {
    var intro: TextOverlay? { texts.first { $0.kind == .titleCard && $0.placement == .intro } }
    var outro: TextOverlay? { texts.first { $0.kind == .titleCard && $0.placement == .outro } }
    var introDuration: Double { max(0, intro?.length ?? 0) }
    var outroDuration: Double { max(0, outro?.length ?? 0) }

    /// Texts shown on top of the recording (lower thirds and covering title cards).
    var overlayTexts: [TextOverlay] { texts.filter { $0.placement == .overlay || $0.kind == .lowerThird } }

    /// What remains on the edited timeline of something that plays in real time from source time
    /// `start`, tied to the video: the parts lying over removed material are gone, and each
    /// remaining piece goes wherever its part of the video goes. `fileShift`: seconds from the
    /// beginning of the thing to this piece.
    func linkedPieces(start: Double, duration seconds: Double, map: TimeMap, kept: [ClosedRange<Double>]) -> [LinkedPiece] {
        let b0 = map.timeline(start), b1 = b0 + seconds
        var result: [LinkedPiece] = []
        var cursor = 0.0
        for seg in kept {
            let t0 = map.timeline(seg.lowerBound), t1 = t0 + map.length(seg)
            let lo = max(b0, t0), hi = min(b1, t1)
            if hi - lo > 0.001 { result.append(LinkedPiece(timeline: (cursor + lo - t0)...(cursor + hi - t0), fileShift: lo - b0)) }
            cursor += t1 - t0
        }
        return result
    }

    /// Source ranges of `range` that are kept, mapped to output time (intro, trim and cuts applied).
    func outputRanges(ofSource range: ClosedRange<Double>, duration: Double) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        let map = timeMap(duration: duration)
        var cursor = introLead(duration: duration)
        for seg in keptSegments(duration: duration) {
            let s = max(seg.lowerBound, range.lowerBound), e = min(seg.upperBound, range.upperBound)
            let t0 = map.timeline(seg.lowerBound)
            if e > s { result.append((cursor + map.timeline(s) - t0)...(cursor + map.timeline(e) - t0)) }
            cursor += map.length(seg)
        }
        return result
    }
}
