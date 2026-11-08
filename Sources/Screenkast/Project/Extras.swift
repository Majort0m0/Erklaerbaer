import Foundation

// MARK: - Background music

/// Music under the whole video (output time: it runs on across cuts).
struct BackgroundMusic: Codable, Equatable {
    /// Relative to the project folder, e.g. "media/music-1234.m4a".
    var file: String
    var name: String
    var volume: Double = 0.35
    var muted: Bool = false
    /// Where the music starts in the file.
    var fileOffset: Double = 0
    var loop: Bool = true
    var fadeIn: Double = 1.5
    var fadeOut: Double = 2.5
    /// Quieter while someone speaks (microphone, voice-over).
    var duckUnderSpeech: Bool = true
    var duckLevel: Double = 0.3
    /// The music was cut into clips (on the music lane); the file no longer runs through the video.
    var clipped: Bool? = nil
}

extension BackgroundMusic {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? file
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0.35
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        fileOffset = try c.decodeIfPresent(Double.self, forKey: .fileOffset) ?? 0
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? true
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 1.5
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 2.5
        duckUnderSpeech = try c.decodeIfPresent(Bool.self, forKey: .duckUnderSpeech) ?? true
        duckLevel = try c.decodeIfPresent(Double.self, forKey: .duckLevel) ?? 0.3
        clipped = try c.decodeIfPresent(Bool.self, forKey: .clipped)
    }
}

// MARK: - Voice enhancement

/// Noise reduction and loudness normalization of the microphone and voice-overs.
struct VoiceEnhancement: Codable, Equatable {
    var enabled: Bool = false
    /// 0 … 1
    var noiseReduction: Double = 0.45
    var normalize: Bool = true
    /// Integrated loudness target (LUFS); −16 suits YouTube and podcasts.
    var targetLUFS: Double = -16
    /// Which lanes are enhanced (nil: both).
    var mic: Bool? = nil
    var voiceOver: Bool? = nil
    /// Breath sounds get quieter (nil: off). Sensitivity 0…1 (how loud a breath may be), reduction in dB.
    var breaths: Bool? = nil
    var breathSensitivity: Double? = nil
    var breathReductionDB: Double? = nil

    var reducesBreaths: Bool { breaths ?? false }
    var breathLevel: Double { breathSensitivity ?? 0.5 }
    var breathDB: Double { breathReductionDB ?? 12 }

    var enhancesMic: Bool { enabled && (mic ?? true) }
    var enhancesVoiceOver: Bool { enabled && (voiceOver ?? true) }

    /// Identifies the processed files (a change of parameters makes new ones).
    /// Identifies the processed files (breaths and the strength are applied in the mix, not in them).
    var key: String {
        String(format: "n%.2f-%@-%.0f", noiseReduction, normalize ? "l" : "x", targetLUFS) + "-g"
    }
    /// How much of the enhanced voice is heard (1 = all, 0 = only loudness matched), live in the mix.
    var intensity: Double? = nil
    var strength: Double { min(1, max(0, intensity ?? 1)) }
}

extension VoiceEnhancement {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        noiseReduction = try c.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0.45
        normalize = try c.decodeIfPresent(Bool.self, forKey: .normalize) ?? true
        targetLUFS = try c.decodeIfPresent(Double.self, forKey: .targetLUFS) ?? -16
        mic = try c.decodeIfPresent(Bool.self, forKey: .mic)
        voiceOver = try c.decodeIfPresent(Bool.self, forKey: .voiceOver)
        breaths = try c.decodeIfPresent(Bool.self, forKey: .breaths)
        breathSensitivity = try c.decodeIfPresent(Double.self, forKey: .breathSensitivity)
        breathReductionDB = try c.decodeIfPresent(Double.self, forKey: .breathReductionDB)
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity)
    }
}

// MARK: - Camera layouts

/// How the camera is shown during a part of the video.
enum CameraLayout: String, Codable, CaseIterable, Identifiable {
    case normal, large, fullscreen, hidden, split
    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .large: return "Groß"
        case .fullscreen: return "Nur Kamera"
        case .hidden: return "Aus"
        case .split: return "Nebeneinander"
        }
    }

    var icon: String {
        switch self {
        case .normal: return "person.crop.circle"
        case .large: return "person.crop.circle.fill"
        case .fullscreen: return "person.crop.rectangle.fill"
        case .hidden: return "person.crop.circle.badge.xmark"
        case .split: return "rectangle.split.2x1"
        }
    }
}

struct CameraLayoutRange: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var layout: CameraLayout
}

// MARK: - Annotations

enum AnnotationKind: String, Codable, CaseIterable, Identifiable {
    case arrow, frame, spotlight
    var id: String { rawValue }

    var label: String {
        switch self {
        case .arrow: return "Pfeil"
        case .frame: return "Rahmen"
        case .spotlight: return "Spotlight"
        }
    }

    var icon: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .frame: return "rectangle"
        case .spotlight: return "flashlight.on.fill"
        }
    }
}

enum AnnotationColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, white
    var id: String { rawValue }

    var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .red: return (0.96, 0.23, 0.2)
        case .orange: return (1.0, 0.58, 0.0)
        case .yellow: return (1.0, 0.84, 0.04)
        case .green: return (0.2, 0.78, 0.35)
        case .blue: return (0.04, 0.52, 1.0)
        case .white: return (1, 1, 1)
        }
    }
}

/// Arrow, frame or spotlight on the recording (zooms with it, like masks). Coordinates are
/// normalized to the captured area (origin top-left). Arrow: from (x, y) to (x + width, y + height).
struct Annotation: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: AnnotationKind
    var start: Double
    var end: Double
    var x: Double = 0.35
    var y: Double = 0.35
    var width: Double = 0.3
    var height: Double = 0.2
    var color: AnnotationColor = .red
    /// Line width factor.
    var thickness: Double = 1
    /// Outline of a frame or spotlight (nil: rounded rectangle).
    var shape: AnnotationShape? = nil

    var outline: AnnotationShape { shape ?? .rounded }
}

// MARK: - Own media

/// A picture shown over the video for a while (fixed in the output).
struct ImageOverlay: Codable, Identifiable, Equatable {
    var id = UUID()
    var file: String
    var start: Double
    var end: Double
    /// Center (normalized output, origin top-left) and width as a fraction of the output width.
    var x: Double = 0.5
    var y: Double = 0.5
    var width: Double = 0.35
    var opacity: Double = 1
    /// Frame and shadow (nil: none, for projects from before).
    var frame: PictureFrame? = nil
    var shadow: Bool? = nil
    /// Not tied to the video: `start` is a timeline position and stays put when parts of the video
    /// are cut or moved (nil: follows the moment of the video it was placed on).
    var free: Bool? = nil
    var isFree: Bool { free == true }
}

/// Logo in a corner of every frame.
struct Watermark: Codable, Equatable {
    var file: String
    var corner: CameraCorner = .topRight
    /// Width as a fraction of the shorter output side.
    var size: Double = 0.14
    var opacity: Double = 0.85
}

/// Another video inserted at a moment of the recording (like a freeze frame, the recording waits).
struct InsertClip: Codable, Identifiable, Equatable {
    var id = UUID()
    var file: String
    var name: String
    /// Source time of the recording where the clip is inserted.
    var at: Double
    var fileOffset: Double = 0
    var duration: Double
    /// Length of the whole file (limits trimming).
    var fileDuration: Double
    var volume: Double = 1
    /// Rotation of the video in degrees (portrait phone videos: 90), nil = 0.
    var rotation: Int? = nil

    /// Tiny source range stretched over the clip (see `FreezeFrame`).
    var sourceRange: ClosedRange<Double> { max(0, at - FreezeFrame.span)...max(at, FreezeFrame.span) }
}

// MARK: - Chapters and transcript

struct Chapter: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Source time.
    var time: Double
    var title: String
}

/// A recognized word with its time in the recording.
struct TranscriptWord: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
}
