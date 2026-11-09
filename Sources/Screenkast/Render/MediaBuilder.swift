import Foundation
import AVFoundation
import CoreImage

// MARK: - Audio track roles

/// Tags audio tracks as "system" or "mic" so the editor can mix them separately.
enum AudioRole {
    static let prefix = "screenkast:"

    static func metadata(_ role: String) -> [AVMetadataItem] {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeUserDataTrackName
        item.value = (prefix + role) as NSString
        item.extendedLanguageTag = "und"
        return [item]
    }

    /// Roles of the asset's audio tracks (by track metadata, falling back to the recorded order).
    static func roles(of tracks: [AVAssetTrack], fallback: [String]) async -> [String] {
        var result: [String] = []
        for (i, track) in tracks.enumerated() {
            let items = (try? await track.load(.metadata)) ?? []
            var role: String?
            for item in items {
                if let s = try? await item.load(.stringValue), s.hasPrefix(prefix) {
                    role = String(s.dropFirst(prefix.count))
                }
            }
            result.append(role ?? (i < fallback.count ? fallback[i] : "mic"))
        }
        return result
    }
}

// MARK: - Composition

/// Linear map from composition time to source time inside one placed piece.
struct TimeSlice: Equatable {
    /// Source range of the recording and its range on the editor timeline.
    let source: ClosedRange<Double>
    let timeline: ClosedRange<Double>
    let compStart: Double
    let isFreeze: Bool
    var insertID: UUID? = nil

    var compEnd: Double { compStart + timeline.upperBound - timeline.lowerBound }
    /// Source seconds per composition second.
    var rate: Double {
        let l = timeline.upperBound - timeline.lowerBound
        return l > 0 ? (source.upperBound - source.lowerBound) / l : 1
    }
    func source(atComp t: Double) -> Double { source.lowerBound + (t - compStart) * rate }
    func comp(ofSource s: Double) -> Double { compStart + (s - source.lowerBound) / rate }
    func comp(ofTimeline t: Double) -> Double { compStart + t - timeline.lowerBound }
}

/// Everything AVFoundation needs to play or export a project.
///
/// Composition layout: [intro card] [kept parts of the recording] [outro card]. Each part is placed
/// in pieces (speed changes are time-scaled, freeze frames stretch a tiny range). A transition at
/// a cut puts the first seconds of the following part onto extra "B" tracks underneath the end of
/// the previous part; intro/outro cards pushed over the recording are blended on top of it.
struct MediaComposition {
    struct AudioTrack {
        let track: AVCompositionTrack
        /// "mic", "system", "voiceover" or "clicks".
        let role: String
        /// Voice-over layer (clips that overlap are on separate tracks).
        var layer: Int? = nil
        /// Carries the incoming side of transitions at cuts.
        var isDissolveB = false
    }

    /// A transition at a cut in composition time; `bSlices` map it to the incoming part's source time.
    struct DissolveRange: Equatable {
        let start: Double
        let end: Double
        let bSlices: [TimeSlice]
        let style: TransitionStyle
    }

    let asset: AVComposition
    let videoComposition: AVMutableVideoComposition
    let audioTracks: [AudioTrack]
    /// Composition times where two kept segments meet with a hard cut (for click-free audio fades).
    let joins: [CMTime]
    let dissolves: [DissolveRange]
    /// The recording's pieces in composition order.
    let slices: [TimeSlice]
    let totalDuration: Double
    /// Voice-over clips with their start on the timeline (they play in real time) and their layer.
    let voiceOverClips: [VoiceOverClip]
    let voiceOverLayers: [UUID: Int]
    /// Composition range of the output (fade in/out at its ends).
    let outputRange: ClosedRange<Double>
    /// Where someone speaks (source time; music gets quieter there).
    var speech: [ClosedRange<Double>] = []
    /// Inserted clips' sound: composition range and volume.
    var insertVolumes: [(range: ClosedRange<Double>, volume: Double)] = []
    /// Video overlays' sound per layer track: composition range and volume.
    var overlayVolumes: [CMPersistentTrackID: [(range: ClosedRange<Double>, overlay: UUID)]] = [:]

    /// Composition time of timeline time 0 (the intro lies before it).
    var recordingOffset: Double { slices.first.map { $0.compStart - $0.timeline.lowerBound } ?? 0 }

    /// Composition ranges covering the kept parts of a source range.
    func compRanges(ofSource r: ClosedRange<Double>) -> [ClosedRange<Double>] {
        slices.compactMap { s in
            let lo = max(s.source.lowerBound, r.lowerBound), hi = min(s.source.upperBound, r.upperBound)
            guard hi > lo else { return nil }
            return s.comp(ofSource: lo)...s.comp(ofSource: hi)
        }
    }

    /// Composition ranges covering the kept parts of a timeline range.
    func compRanges(ofTimeline r: ClosedRange<Double>) -> [ClosedRange<Double>] {
        mergedRanges(slices.compactMap { s in
            let lo = max(s.timeline.lowerBound, r.lowerBound), hi = min(s.timeline.upperBound, r.upperBound)
            guard hi > lo else { return nil }
            return s.comp(ofTimeline: lo)...s.comp(ofTimeline: hi)
        })
    }

    /// Composition time of a source time (nil if that moment is not in the composition).
    func compTime(ofSource t: Double) -> Double? {
        (slices.first { t >= $0.source.lowerBound && t < $0.source.upperBound } ?? slices.first { $0.source.contains(t) })
            .map { $0.comp(ofSource: t) }
    }

    private func mergedRanges(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound + 1e-6 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// A fade over a timeline range, split where cuts remove parts of it.
    private func timelineCurves(_ s: Double, _ e: Double, _ shape: VolumeEnvelope.Curve.Shape) -> [VolumeEnvelope.Curve] {
        guard e > s else { return [] }
        return compRanges(ofTimeline: s...e).compactMap { r in
            // Comp ranges of a timeline range run 1:1; recover the timeline position of each piece.
            guard let slice = slices.first(where: { r.lowerBound >= $0.compStart - 1e-6 && r.lowerBound <= $0.compEnd + 1e-6 }) else { return nil }
            let t0 = slice.timeline.lowerBound + r.lowerBound - slice.compStart
            let t1 = t0 + r.upperBound - r.lowerBound
            return VolumeEnvelope.Curve(start: r.lowerBound, end: r.upperBound, p0: (t0 - s) / (e - s), p1: (t1 - s) / (e - s), shape: shape)
        }
    }

    func audioMix(settings: EditSettings) -> AVAudioMix? {
        guard !audioTracks.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        // Clips crossfade within their own lane.
        let fades = VoiceOverClip.crossfades(voiceOverClips.filter { !$0.isMusic })
            .merging(VoiceOverClip.crossfades(voiceOverClips.filter(\.isMusic))) { a, _ in a }
        let tail = MediaBuilder.dissolveTail
        mix.inputParameters = audioTracks.map { entry in
            let p = AVMutableAudioMixInputParameters(track: entry.track)
            p.audioTimePitchAlgorithm = .spectral
            let isDry = entry.role == "micdry"
            let lane = isDry ? AudioLane.mic : AudioLane.allCases.first { $0.role == entry.role }
            let base: Double
            switch lane {
            case .mic: base = settings.micMuted ? 0 : settings.micVolume
            case .system: base = settings.systemMuted ? 0 : settings.systemVolume
            case .voiceOver: base = settings.voiceOverMuted ? 0 : settings.voiceOverVolume
            case .music: base = (settings.music?.muted ?? true) ? 0 : settings.music?.volume ?? 0
            case nil: base = entry.role == "insert" || entry.role == "overlay" ? 1
                : entry.role == "effects" ? settings.soundEffectVolume : settings.clickVolume
            }
            var dips: [VolumeEnvelope.Dip] = []
            var curves: [VolumeEnvelope.Curve] = []
            if entry.role == "insert" {
                for d in dissolves {
                    curves.append(.init(start: d.start, end: d.end, shape: entry.isDissolveB ? .equalPowerIn : .equalPowerOut))
                }
                for v in insertVolumes where v.volume < 0.999 {
                    dips.append(.init(start: v.range.lowerBound, end: v.range.upperBound, level: v.volume, rampIn: 0.01, rampOut: 0.01))
                }
            }
            if entry.role == "overlay" {
                // Video clips pushed over each other: their sound crossfades over the overlap.
                let others = overlayVolumes.filter { $0.key != entry.track.trackID }.values.flatMap { $0 }
                for v in overlayVolumes[entry.track.trackID] ?? [] {
                    guard let mine = settings.videoOverlays.first(where: { $0.id == v.overlay }), !mine.synced else { continue }
                    let rivals = others.filter { other in
                        settings.videoOverlays.contains { $0.id == other.overlay && !$0.synced && FrameRenderer.sameSpot($0, mine) && ($0.lane ?? 0) == (mine.lane ?? 0) }
                    }
                    for o in rivals where o.range.overlaps(v.range) {
                        if o.range.lowerBound < v.range.lowerBound, o.range.upperBound < v.range.upperBound, o.range.upperBound - v.range.lowerBound > 0.02 {
                            curves.append(.init(start: v.range.lowerBound, end: o.range.upperBound, shape: .equalPowerIn))
                        }
                        if o.range.upperBound > v.range.upperBound, o.range.lowerBound > v.range.lowerBound, v.range.upperBound - o.range.lowerBound > 0.02 {
                            curves.append(.init(start: o.range.lowerBound, end: v.range.upperBound, shape: .equalPowerOut))
                        }
                    }
                }
                // Volume by overlay (the volume in settings may have changed since the build).
                for v in overlayVolumes[entry.track.trackID] ?? [] {
                    let o = settings.videoOverlays.first { $0.id == v.overlay }
                    let volume = o.map { $0.muted ? 0 : min(1, $0.volume) } ?? 1
                    // Keyframes: the volume follows them in small steps.
                    if let keys = o?.keys, !keys.isEmpty, o?.muted != true {
                        let first = (overlayVolumes.values.flatMap { $0 }.filter { $0.overlay == v.overlay }.map(\.range.lowerBound).min()) ?? v.range.lowerBound
                        var t = v.range.lowerBound
                        while t < v.range.upperBound {
                            let end = min(v.range.upperBound, t + 0.1)
                            if let level = Motion.value(keys, at: (t + end) / 2 - first)?.volume, level < 0.999 {
                                dips.append(.init(start: t, end: end, level: level, rampIn: 0.05, rampOut: 0.05))
                            }
                            t = end
                        }
                    } else if volume < 0.999 {
                        dips.append(.init(start: v.range.lowerBound, end: v.range.upperBound, level: volume, rampIn: 0.02, rampOut: 0.02))
                    }
                }
            }
            if lane == .music, let music = settings.music {
                // Music runs on across cuts; it fades in/out with the video and ducks under speech.
                curves.append(.init(start: outputRange.lowerBound, end: outputRange.lowerBound + max(0.01, music.fadeIn), shape: .linearIn))
                curves.append(.init(start: outputRange.upperBound - max(0.01, music.fadeOut), end: outputRange.upperBound, shape: .linearOut))
                if music.duckUnderSpeech {
                    var talk = speech.flatMap { compRanges(ofSource: $0) }
                    talk += voiceOverClips.filter { !$0.isMusic }.flatMap { compRanges(ofTimeline: $0.start...$0.end) }
                    for r in talk {
                        dips.append(.init(start: r.lowerBound, end: r.upperBound, level: music.duckLevel, rampIn: 0.3, rampOut: 0.6))
                    }
                }
            }
            if let lane, lane != .music {
                if entry.isDissolveB {
                    // Muted ranges inside the part the B side plays.
                    for d in dissolves {
                        for mute in settings.audioMutes where mute.lane == lane {
                            for slice in d.bSlices {
                                let lo = max(slice.source.lowerBound, mute.start), hi = min(slice.source.upperBound, mute.end)
                                if hi > lo { dips.append(.init(start: slice.comp(ofSource: lo), end: slice.comp(ofSource: hi), level: min(1, mute.level), rampIn: 0.015, rampOut: 0.015)) }
                            }
                        }
                    }
                } else {
                    // 12 ms dip at each hard cut against clicks.
                    dips += joins.map { VolumeEnvelope.Dip(start: $0.seconds, end: $0.seconds, level: 0, rampIn: 0.012, rampOut: 0.012) }
                    for mute in settings.audioMutes where mute.lane == lane {
                        for r in compRanges(ofSource: mute.start...mute.end) {
                            dips.append(.init(start: r.lowerBound, end: r.upperBound, level: min(1, mute.level), rampIn: 0.015, rampOut: 0.015))
                        }
                    }
                }
            }
            // Enhanced and dry microphone: their share follows the strength (overall and per range).
            if lane == .mic, audioTracks.contains(where: { $0.role == "micdry" }) {
                func share(_ amount: Double) -> Double { isDry ? 1 - amount : amount }
                let g = settings.voice.strength
                if entry.isDissolveB {
                    if share(g) < 0.999 { dips.append(.init(start: 0, end: totalDuration, level: share(g), rampIn: 0, rampOut: 0)) }
                } else {
                    let regions = settings.audioMutes.filter { $0.lane == .mic && $0.enhance != nil }
                        .flatMap { m in compRanges(ofSource: m.start...m.end).map { ($0, min(1, max(0, m.enhance ?? g))) } }
                        .sorted { $0.0.lowerBound < $1.0.lowerBound }
                    var cursor = 0.0
                    func add(_ a: Double, _ b: Double, _ amount: Double) {
                        guard b > a + 1e-4, share(amount) < 0.999 else { return }
                        dips.append(.init(start: a, end: b, level: share(amount), rampIn: 0.03, rampOut: 0.03))
                    }
                    for (r, amount) in regions {
                        if r.lowerBound > cursor { add(cursor, r.lowerBound, g) }
                        add(r.lowerBound, r.upperBound, amount)
                        cursor = max(cursor, r.upperBound)
                    }
                    if cursor < totalDuration { add(cursor, totalDuration, g) }
                }
            }
            if lane == .mic || lane == .system {
                if settings.duckUnderVoiceOver, !settings.voiceOverMuted, settings.voiceOverVolume > 0.01 {
                    for clip in voiceOverClips where !clip.isMusic {
                        for r in compRanges(ofTimeline: clip.start...clip.end) {
                            dips.append(.init(start: r.lowerBound, end: r.upperBound, level: settings.duckLevel, rampIn: 0.25, rampOut: 0.4))
                        }
                    }
                }
                // Transitions at cuts: the outgoing sound fades out while the incoming one fades in.
                // Right after the transition both tracks carry the same material for `tail` seconds.
                for d in dissolves {
                    if entry.isDissolveB {
                        curves.append(.init(start: d.start, end: d.end, shape: .equalPowerIn))
                        curves.append(.init(start: d.end, end: d.end + tail, shape: .linearOut))
                    } else {
                        curves.append(.init(start: d.start, end: d.end, shape: .equalPowerOut))
                        curves.append(.init(start: d.end, end: d.end + tail, shape: .linearIn))
                    }
                }
            }
            // Voice-over clips pushed over each other crossfade.
            if lane == .voiceOver || lane == .music, let layer = entry.layer {
                for clip in voiceOverClips where voiceOverLayers[clip.id] == layer && clip.isMusic == (lane == .music) {
                    // The clip's own fades.
                    if let f = clip.fadeIn, f > 0.01 { curves += timelineCurves(clip.start, min(clip.end, clip.start + f), .linearIn) }
                    if let f = clip.fadeOut, f > 0.01 { curves += timelineCurves(max(clip.start, clip.end - f), clip.end, .linearOut) }
                    // Clip volume (looked up in the settings: changing it needs no new composition).
                    let gain = settings.voiceOvers.first { $0.id == (clip.parent ?? clip.id) }?.gain ?? clip.gain
                    if gain < 0.999 {
                        for r in compRanges(ofTimeline: clip.start...clip.end) {
                            dips.append(.init(start: r.lowerBound, end: r.upperBound, level: gain, rampIn: 0.01, rampOut: 0.01))
                        }
                    }
                    guard let f = fades[clip.id] else { continue }
                    curves += timelineCurves(clip.start, clip.start + f.fadeIn, .equalPowerIn)
                    curves += timelineCurves(clip.end - f.fadeOut, clip.end, .equalPowerOut)
                }
            }
            // Fade in/out of the whole video.
            if settings.fadeIn > 0.01 {
                curves.append(.init(start: outputRange.lowerBound, end: outputRange.lowerBound + settings.fadeIn, shape: .linearIn))
            }
            if settings.fadeOut > 0.01 {
                curves.append(.init(start: outputRange.upperBound - settings.fadeOut, end: outputRange.upperBound, shape: .linearOut))
            }
            VolumeEnvelope.apply(base: base, dips: dips, curves: curves, total: totalDuration, to: p)
            return p
        }
        return mix
    }

    func videoComposition(renderSize: CGSize, fps: Int) -> AVMutableVideoComposition {
        let copy = videoComposition.mutableCopy() as! AVMutableVideoComposition
        copy.renderSize = renderSize
        copy.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        return copy
    }
}

/// Piecewise linear volume: a base volume lowered by "dips" (mutes, ducking, cut fades) and
/// multiplied by fade curves (crossfades).
enum VolumeEnvelope {
    struct Dip {
        var start: Double
        var end: Double
        /// Volume factor inside the dip.
        var level: Double
        /// Fade before `start` / after `end`.
        var rampIn: Double
        var rampOut: Double
    }

    /// A fade over `start…end`; outside that range the factor is 1. `p0…p1` is the part of the
    /// whole fade this piece covers (a fade split by a cut continues where it left off).
    struct Curve {
        enum Shape { case equalPowerIn, equalPowerOut, linearIn, linearOut }
        var start: Double
        var end: Double
        var p0: Double = 0
        var p1: Double = 1
        var shape: Shape

        func gain(at t: Double) -> Double {
            guard t >= start, t <= end else { return 1 }
            let p = end > start ? p0 + (p1 - p0) * (t - start) / (end - start) : p1
            switch shape {
            case .equalPowerIn: return sin(min(1, max(0, p)) * .pi / 2)
            case .equalPowerOut: return cos(min(1, max(0, p)) * .pi / 2)
            case .linearIn: return min(1, max(0, p))
            case .linearOut: return 1 - min(1, max(0, p))
            }
        }
    }

    static func factor(_ d: Dip, at t: Double) -> Double {
        if t <= d.start - d.rampIn || t >= d.end + d.rampOut { return 1 }
        if t < d.start { return 1 + (d.level - 1) * (t - (d.start - d.rampIn)) / max(1e-6, d.rampIn) }
        if t <= d.end { return d.level }
        return d.level + (1 - d.level) * (t - d.end) / max(1e-6, d.rampOut)
    }

    static func value(at t: Double, base: Double, dips: [Dip], curves: [Curve] = []) -> Double {
        base * dips.reduce(1) { min($0, factor($1, at: t)) } * curves.reduce(1) { $0 * $1.gain(at: t) }
    }

    /// Breakpoints (time, volume); the volume is linear in between.
    static func points(base: Double, dips: [Dip], curves: [Curve] = [], total: Double) -> [(time: Double, volume: Double)] {
        var times: Set<Double> = [0]
        func add(_ t: Double) {
            // A ramp reaching past the end of the audio track is dropped by AVFoundation: the last
            // breakpoint lies 5 ms before the end (a fade-out is practically silent there).
            let t = min(t, total - 0.005)
            if t > 0 { times.insert((t * 100_000).rounded() / 100_000) }
        }
        for d in dips {
            for t in [d.start - d.rampIn, d.start, d.end, d.end + d.rampOut] { add(t) }
        }
        for c in curves {
            // Just outside the curve the factor jumps back to 1 (the clip has ended or not begun).
            for t in [c.start - 0.001, c.start, c.end, c.end + 0.001] { add(t) }
            if c.shape == .equalPowerIn || c.shape == .equalPowerOut {
                for i in 1..<16 { add(c.start + (c.end - c.start) * Double(i) / 16) }
            }
        }
        return times.sorted().map { ($0, value(at: $0, base: base, dips: dips, curves: curves)) }
    }

    static func apply(base: Double, dips: [Dip], curves: [Curve] = [], total: Double, to params: AVMutableAudioMixInputParameters) {
        let pts = points(base: base, dips: dips, curves: curves, total: total)
        params.setVolume(Float(pts[0].volume), at: .zero)
        for (a, b) in zip(pts, pts.dropFirst()) where abs(a.volume - b.volume) > 1e-4 {
            params.setVolumeRamp(fromStartVolume: Float(a.volume), toEndVolume: Float(b.volume),
                                 timeRange: CMTimeRange(start: CMTime(seconds: a.time, preferredTimescale: 48_000),
                                                        end: CMTime(seconds: b.time, preferredTimescale: 48_000)))
        }
    }
}

enum MediaBuilder {
    static let screenTrackID: CMPersistentTrackID = 1
    static let cameraTrackID: CMPersistentTrackID = 2
    /// Incoming side of transitions at cuts.
    static let screenBTrackID: CMPersistentTrackID = 101
    static let cameraBTrackID: CMPersistentTrackID = 102
    /// Inserted video clips.
    static let insertTrackID: CMPersistentTrackID = 103
    /// Second recorded window (follows the recording like the camera).
    static let syncedOverlayTrackID: CMPersistentTrackID = 104
    /// Video overlays: one track per layer from here.
    static let overlayTrackBase: CMPersistentTrackID = 200
    /// After a transition at a cut, both audio tracks carry the same material this long and
    /// crossfade linearly (no click where the incoming part moves back to the main track).
    static let dissolveTail = 0.02
    /// Time scale of all composition edits (fine enough for 1 ms freeze ranges).
    static let timescale: CMTimeScale = 48_000

    static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: timescale) }

    /// - Parameter segments: source ranges to include, in order (nil = whole recording, for the editor
    ///   preview, which runs in timeline time and skips cuts while playing). Each piece gets its own
    ///   instruction mapping composition time back to source time, so cursor/zoom stay correct.
    ///   Intro and outro title cards are added before/after in both cases; transitions at cuts and
    ///   intro/outro cards pushed over the recording are placed wherever their source range is.
    static func make(project: Project, renderer: FrameRenderer, fps: Int,
                     segments: [ClosedRange<Double>]? = nil, speech: [ClosedRange<Double>] = []) async throws -> MediaComposition {
        let settings = project.settings
        // `map`: speed changes, freeze frames, inserted clips. `edit`: the edited timeline on top of
        // it (only the kept parts, in their order).
        let map = settings.timeMap(duration: project.info.duration)
        let edit = settings.editMap(duration: project.info.duration)
        let layout = settings.cutLayout(duration: project.info.duration)
        let kept = layout.segments
        let screenAsset = AVURLAsset(url: project.videoURL)
        let duration = try await screenAsset.load(.duration)
        let full = CMTimeRange(start: .zero, duration: duration)
        var ranges: [ClosedRange<Double>] = (segments ?? kept).compactMap {
            let hi = min($0.upperBound, duration.seconds)
            return hi > $0.lowerBound ? $0.lowerBound...hi : nil
        }
        // The preview needs something to show even if everything is cut away.
        if ranges.isEmpty, segments == nil, duration.seconds > 0 { ranges = [0...min(0.5, duration.seconds)] }
        guard !ranges.isEmpty else { throw RecorderError.writerFailed("Nichts zu exportieren – alles weggeschnitten") }

        let composition = AVMutableComposition()
        // Source assets must stay alive while their tracks are inserted.
        var keepAlive: [AVAsset] = [screenAsset]
        defer { _ = keepAlive }
        guard let srcVideo = try await screenAsset.loadTracks(withMediaType: .video).first,
              let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: screenTrackID) else {
            throw RecorderError.writerFailed("Keine Videospur gefunden")
        }

        // Camera
        var camSource: (track: AVAssetTrack, range: CMTimeRange)?
        var camTrack: AVMutableCompositionTrack?
        if let camURL = project.cameraURL, FileManager.default.fileExists(atPath: camURL.path) {
            let camAsset = AVURLAsset(url: camURL)
            keepAlive.append(camAsset)
            if let camVideo = try? await camAsset.loadTracks(withMediaType: .video).first,
               let camRange = try? await camVideo.load(.timeRange) {
                camSource = (camVideo, camRange)
                camTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: cameraTrackID)
            }
        }

        // Audio (echo-free microphone replaces the original mic track when enabled)
        let srcAudio = try await screenAsset.loadTracks(withMediaType: .audio)
        let roles = await AudioRole.roles(of: srcAudio, fallback: project.info.audioRoles)
        var cleanMic: AVAssetTrack?
        let cleanURL = EchoCanceller.cleanURL(for: project)
        if settings.removeEcho, roles.contains("system"), FileManager.default.fileExists(atPath: cleanURL.path) {
            let cleanAsset = AVURLAsset(url: cleanURL)
            keepAlive.append(cleanAsset)
            cleanMic = try? await cleanAsset.loadTracks(withMediaType: .audio).first
        }
        // Enhanced voice (noise reduction, loudness) replaces the microphone when it is ready.
        let voiceMicURL = VoiceProcessor.micURL(for: project, settings: settings)
        if settings.voice.enhancesMic, roles.contains("mic"), FileManager.default.fileExists(atPath: voiceMicURL.path) {
            let voiceAsset = AVURLAsset(url: voiceMicURL)
            keepAlive.append(voiceAsset)
            if let track = try? await voiceAsset.loadTracks(withMediaType: .audio).first { cleanMic = track }
        }
        var audioSources: [(source: AVAssetTrack, range: CMTimeRange, target: AVMutableCompositionTrack, role: String,
                            bTarget: AVMutableCompositionTrack?)] = []
        for (original, role) in zip(srcAudio, roles) {
            let track = (role == "mic" ? cleanMic : nil) ?? original
            guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let trackRange = try await track.load(.timeRange)
            audioSources.append((track, trackRange, target, role, nil))
        }
        // The microphone without noise reduction (same loudness): mixed with the enhanced one by
        // the strength of the enhancement, overall and per range.
        let dryURL = VoiceProcessor.micDryURL(for: project, settings: settings)
        if settings.voice.enhancesMic, roles.contains("mic"), FileManager.default.fileExists(atPath: voiceMicURL.path),
           FileManager.default.fileExists(atPath: dryURL.path) {
            let dryAsset = AVURLAsset(url: dryURL)
            if let dry = try? await dryAsset.loadTracks(withMediaType: .audio).first, let range = try? await dry.load(.timeRange),
               let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                keepAlive.append(dryAsset)
                audioSources.append((dry, range, target, "micdry", nil))
            }
        }

        // Voice-over: clips start at a source moment and play in real time (their timeline range
        // is start…start+duration). Clips that overlap go onto separate tracks ("layers") and crossfade.
        var voSources: [String: (track: AVAssetTrack, range: CMTimeRange)] = [:]
        for file in Set(settings.voiceOvers.map(\.file)) {
            let enhanced = VoiceProcessor.voiceOverURL(for: project, file: file, settings: settings)
            let useEnhanced = settings.voice.enhancesVoiceOver && FileManager.default.fileExists(atPath: enhanced.path)
            let asset = AVURLAsset(url: useEnhanced ? enhanced : project.url.appendingPathComponent(file))
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await track.load(.timeRange) else { continue }
            keepAlive.append(asset)
            voSources[file] = (track, range)
        }
        let allAudioClips = settings.voiceOvers.filter { voSources[$0.file] != nil && $0.duration > 0.01 }
            .flatMap { clip -> [VoiceOverClip] in
                if clip.isFree { return [clip] }
                // Tied to the video: it is cut and moved along with it.
                let pieces = settings.linkedPieces(start: clip.start, duration: clip.duration, map: map, kept: kept)
                return pieces.enumerated().map { index, piece in
                    var c = clip
                    c.id = UUID()
                    c.parent = clip.id
                    if index > 0 { c.fadeIn = nil }
                    if index < pieces.count - 1 { c.fadeOut = nil }
                    c.start = piece.timeline.lowerBound
                    c.duration = piece.timeline.upperBound - piece.timeline.lowerBound
                    c.fileOffset += piece.fileShift
                    return c
                }
            }
            .sorted { $0.start < $1.start }
        let musicClips = allAudioClips.filter(\.isMusic)
        let voClips = allAudioClips.filter { !$0.isMusic }
        let voLayers = VoiceOverClip.layers(voClips)
        let musicLayers = VoiceOverClip.layers(musicClips)
        let musicClipTracks: [AVMutableCompositionTrack] = musicClips.isEmpty ? [] : (0..<musicLayers.count).compactMap { _ in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        let voTracks: [AVMutableCompositionTrack] = voClips.isEmpty ? [] : (0..<voLayers.count).compactMap { _ in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        // Inserted clips: their own video and audio track.
        var insertSources: [UUID: (clip: InsertClip, video: AVAssetTrack, videoRange: CMTimeRange, audio: (AVAssetTrack, CMTimeRange)?)] = [:]
        for clip in settings.inserts {
            let asset = AVURLAsset(url: project.url.appendingPathComponent(clip.file))
            guard let video = try? await asset.loadTracks(withMediaType: .video).first,
                  let videoRange = try? await video.load(.timeRange) else { continue }
            keepAlive.append(asset)
            var audio: (AVAssetTrack, CMTimeRange)?
            if let a = try? await asset.loadTracks(withMediaType: .audio).first, let r = try? await a.load(.timeRange) { audio = (a, r) }
            insertSources[clip.id] = (clip, video, videoRange, audio)
        }
        let insertVideo = insertSources.isEmpty ? nil : composition.addMutableTrack(withMediaType: .video, preferredTrackID: insertTrackID)
        let insertAudio = insertSources.values.contains { $0.audio != nil }
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        var insertVolumes: [(range: ClosedRange<Double>, volume: Double)] = []

        // Video overlays: free ones play in real time on layer tracks, the synced one follows the recording.
        struct OverlaySource { let overlay: VideoOverlay; let video: AVAssetTrack; let videoRange: CMTimeRange; let audio: (AVAssetTrack, CMTimeRange)? }
        var overlaySources: [UUID: OverlaySource] = [:]
        var syncedSource: (track: AVAssetTrack, range: CMTimeRange)?
        var syncedFile: String?
        for o in settings.videoOverlays {
            if o.synced, syncedFile != nil { continue }
            let asset = AVURLAsset(url: project.url.appendingPathComponent(o.file))
            guard let video = try? await asset.loadTracks(withMediaType: .video).first,
                  let videoRange = try? await video.load(.timeRange) else { continue }
            keepAlive.append(asset)
            if o.synced {
                syncedSource = (video, videoRange)
                syncedFile = o.file
                continue
            }
            var audio: (AVAssetTrack, CMTimeRange)?
            if let a = try? await asset.loadTracks(withMediaType: .audio).first, let r = try? await a.load(.timeRange) { audio = (a, r) }
            overlaySources[o.id] = OverlaySource(overlay: o, video: video, videoRange: videoRange, audio: audio)
        }
        func overlayPieces(_ o: VideoOverlay) -> [LinkedPiece] {
            o.isFree ? [LinkedPiece(timeline: o.start...(o.start + o.duration), fileShift: 0)]
                : settings.linkedPieces(start: o.start, duration: o.duration, map: map, kept: kept)
        }
        let overlaysOnTimeline = overlaySources.values.compactMap { source -> VideoOverlay? in
            var o = source.overlay
            guard let first = overlayPieces(o).first, let last = overlayPieces(o).last else { return nil }
            o.start = first.timeline.lowerBound
            o.duration = last.timeline.upperBound - first.timeline.lowerBound
            return o
        }
        let overlayLayers = VideoOverlay.layers(overlaysOnTimeline, timeline: { $0 })
        let overlayVideoTracks: [AVMutableCompositionTrack] = (0..<overlayLayers.count).compactMap {
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: overlayTrackBase + CMPersistentTrackID($0))
        }
        var overlayAudioTracks: [Int: AVMutableCompositionTrack] = [:]
        for source in overlaySources.values where source.audio != nil {
            guard let layer = overlayLayers.layerOf[source.overlay.id], overlayAudioTracks[layer] == nil else { continue }
            overlayAudioTracks[layer] = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        var overlayVolumes: [CMPersistentTrackID: [(range: ClosedRange<Double>, overlay: UUID)]] = [:]
        let syncedTrack = syncedSource == nil ? nil
            : composition.addMutableTrack(withMediaType: .video, preferredTrackID: syncedOverlayTrackID)
        /// Overlay id → track its frames are on (for the compositor).
        var overlayTracks: [UUID: CMPersistentTrackID] = [:]
        for (id, layer) in overlayLayers.layerOf where layer < overlayVideoTracks.count { overlayTracks[id] = overlayVideoTracks[layer].trackID }
        if let syncedTrack, let syncedFile {
            for o in settings.videoOverlays where o.synced && o.file == syncedFile { overlayTracks[o.id] = syncedTrack.trackID }
        }
        let overlayRotations = Dictionary(uniqueKeysWithValues: settings.videoOverlays.map { ($0.id, $0.rotation) })

        /// End of the media placed so far, per track.
        var trackEnds: [CMPersistentTrackID: CMTime] = [:]
        /// Places `sourceRange` of `source` at `at`, filling any gap before it with silence/emptiness
        /// (media can't be inserted past the end of a track). Returns the composition range it filled.
        @discardableResult
        func place(_ source: AVAssetTrack, _ sourceRange: CMTimeRange, into target: AVMutableCompositionTrack,
                   at: CMTime) -> CMTimeRange? {
            var range = sourceRange
            var at = at
            let end = trackEnds[target.trackID] ?? .zero
            if at < end {
                // Never overlap (an insert would shift everything after it).
                let overlap = CMTimeSubtract(end, at)
                guard overlap < range.duration else { return nil }
                range = CMTimeRange(start: CMTimeAdd(range.start, overlap), duration: CMTimeSubtract(range.duration, overlap))
                at = end
            }
            guard range.duration > .zero else { return nil }
            if at > end { target.insertEmptyTimeRange(CMTimeRange(start: end, end: at)) }
            do {
                try target.insertTimeRange(range, of: source, at: at)
                let placed = CMTimeRange(start: at, duration: range.duration)
                trackEnds[target.trackID] = placed.end
                return placed
            } catch {
                FileHandle.standardError.write("insert failed (\(target.mediaType.rawValue)): \(error)\n".data(using: .utf8)!)
                return nil
            }
        }
        /// Inserts the part of source range `s` that the track covers at composition time `at`,
        /// time-scaled so that `s` takes `length` seconds.
        @discardableResult
        func placeScaled(_ source: AVAssetTrack, available: CMTimeRange, into target: AVMutableCompositionTrack,
                         source s: ClosedRange<Double>, length: Double, at: Double) -> Bool {
            let lo = max(s.lowerBound, available.start.seconds), hi = min(s.upperBound, available.end.seconds)
            guard hi > lo, s.upperBound > s.lowerBound else { return false }
            let factor = length / (s.upperBound - s.lowerBound)
            guard let placed = place(source, CMTimeRange(start: time(lo), end: time(hi)), into: target,
                                     at: time(at + (lo - s.lowerBound) * factor)) else { return false }
            if abs(factor - 1) > 1e-6 {
                let scaled = time(placed.duration.seconds * factor)
                target.scaleTimeRange(placed, toDuration: scaled)
                trackEnds[target.trackID] = CMTimeAdd(placed.start, scaled)
            }
            return true
        }
        /// Composition time of the start of the edited timeline.
        var timelineZero = 0.0
        /// Places a source range of the recording piece by piece (speed, freeze frames) at composition
        /// time `at` onto the given video/camera/audio tracks. Freeze frames are silent.
        func placeRecording(_ r: ClosedRange<Double>, at: Double, video: AVMutableCompositionTrack,
                            camera: AVMutableCompositionTrack?, audio: [(AVAssetTrack, CMTimeRange, AVMutableCompositionTrack)],
                            audioExtra: Double = 0, inserts: Bool = false, synced: AVMutableCompositionTrack? = nil,
                            insertTargets: (video: AVMutableCompositionTrack, audio: AVMutableCompositionTrack?)? = nil) -> [TimeSlice] {
            var cursor = at
            var slices: [TimeSlice] = []
            for piece in map.pieces(in: r) {
                let length = piece.timeline.upperBound - piece.timeline.lowerBound
                if inserts, let id = piece.insertID, let ins = insertSources[id], let videoTarget = insertTargets?.video ?? insertVideo {
                    // The inserted clip plays at its own speed; the recording waits.
                    let fraction = (piece.timeline.lowerBound - map.timeline(ins.clip.sourceRange.lowerBound))
                    let from = time(ins.clip.fileOffset + fraction)
                    let clipRange = CMTimeRange(start: from, duration: time(length))
                    place(ins.video, CMTimeRangeGetIntersection(clipRange, otherRange: ins.videoRange), into: videoTarget, at: time(cursor))
                    if let (track, range) = ins.audio, let audioTarget = insertTargets == nil ? insertAudio : insertTargets?.audio {
                        place(track, CMTimeRangeGetIntersection(clipRange, otherRange: range), into: audioTarget, at: time(cursor))
                        insertVolumes.append((cursor...(cursor + length), ins.clip.volume))
                    }
                    slices.append(TimeSlice(source: piece.source, timeline: (cursor - timelineZero)...(cursor - timelineZero + length),
                                            compStart: cursor, isFreeze: true, insertID: id))
                    cursor += length
                    continue
                }
                placeScaled(srcVideo, available: full, into: video, source: piece.source, length: length, at: cursor)
                if let camera, let camSource {
                    placeScaled(camSource.track, available: camSource.range, into: camera, source: piece.source, length: length, at: cursor)
                }
                if let synced, let syncedSource {
                    placeScaled(syncedSource.track, available: syncedSource.range, into: synced, source: piece.source, length: length, at: cursor)
                }
                if !piece.isFreeze {
                    for (src, available, target) in audio {
                        placeScaled(src, available: available, into: target, source: piece.source, length: length, at: cursor)
                    }
                }
                slices.append(TimeSlice(source: piece.source, timeline: (cursor - timelineZero)...(cursor - timelineZero + length),
                                        compStart: cursor, isFreeze: piece.isFreeze))
                cursor += length
            }
            if audioExtra > 0, let last = slices.last, !last.isFreeze {
                // A little more sound after the range (crossfaded with the main track).
                let extra = r.upperBound...map.source(map.timeline(r.upperBound) + audioExtra)
                for piece in map.pieces(in: extra) where !piece.isFreeze {
                    let length = piece.timeline.upperBound - piece.timeline.lowerBound
                    for (src, available, target) in audio {
                        placeScaled(src, available: available, into: target, source: piece.source, length: length,
                                    at: cursor + piece.timeline.lowerBound - map.timeline(r.upperBound))
                    }
                }
            }
            return slices
        }

        // Click sounds: one short sample per recorded click, on its own track.
        var clickTrack: AVMutableCompositionTrack?
        var clickSource: AVAssetTrack?
        var clickRange = CMTimeRange.zero
        let clicks = project.cursor.clicks.filter(\.isInsideCapture).map(\.t).sorted()
        if settings.clickSound, !clicks.isEmpty,
           let url = try? ClickSound.ensureFile(for: project),
           case let clickAsset = AVURLAsset(url: url),
           let track = try? await clickAsset.loadTracks(withMediaType: .audio).first {
            keepAlive.append(clickAsset)
            clickSource = track
            clickRange = (try? await track.load(.timeRange)) ?? .zero
            clickTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        var instructions: [RenderInstruction] = []
        var joins: [CMTime] = []
        var slices: [TimeSlice] = []
        var cursor = 0.0
        let intro = settings.intro.flatMap { $0.length > 0.05 ? $0 : nil }
        let outro = settings.outro.flatMap { $0.length > 0.05 ? $0 : nil }
        let introOverlap = intro == nil ? 0 : settings.introOverlapLength(duration: project.info.duration)
        let outroOverlap = outro == nil ? 0 : settings.outroOverlapLength(duration: project.info.duration)
        // The whole video's fade from/to black needs the output range, known only at the end.
        var cardInstructions: [(range: CMTimeRange, card: TextOverlay, localOffset: Double, fadeToRecording: Bool)] = []

        /// Full-screen title card before or after the recording (no source media). `localOffset`:
        /// card time at its first frame here (an outro pushed over the recording starts later).
        func addCard(_ card: TextOverlay, length seconds: Double, localOffset: Double, fadeToRecording: Bool) {
            guard seconds > 0.001 else { return }
            let range = CMTimeRange(start: time(cursor), duration: time(seconds))
            // The video track must reach over the card (a trailing empty edit does not count towards
            // the composition's length): one source frame stretched to the card's length. The card
            // instruction never shows it.
            let still = CMTimeRangeGetIntersection(CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 30)), otherRange: full)
            if let placed = place(srcVideo, still, into: screenTrack, at: range.start) {
                screenTrack.scaleTimeRange(placed, toDuration: CMTimeSubtract(range.end, placed.start))
            } else {
                screenTrack.insertEmptyTimeRange(range)
            }
            trackEnds[screenTrack.trackID] = range.end
            cardInstructions.append((range, card, localOffset, fadeToRecording))
            cursor += seconds
        }
        if let intro { addCard(intro, length: intro.length - introOverlap, localOffset: 0, fadeToRecording: introOverlap == 0) }
        let recordingStart = cursor
        timelineZero = recordingStart
        let mainAudio = audioSources.map { ($0.source, $0.range, $0.target) }

        for range in ranges {
            let segmentStart = cursor
            let placed = placeRecording(range, at: cursor, video: screenTrack, camera: camTrack, audio: mainAudio, inserts: true,
                                        synced: syncedTrack)
            guard !placed.isEmpty else { throw RecorderError.writerFailed("Videospur konnte nicht eingefügt werden") }
            let t0 = map.timeline(range.lowerBound), t1 = map.timeline(range.upperBound)
            if let clickTrack, let clickSource {
                for t in clicks where t >= range.lowerBound && t < range.upperBound {
                    guard let slice = placed.first(where: { !$0.isFreeze && $0.source.contains(t) }),
                          slice.comp(ofSource: t) + ClickSound.length <= segmentStart + t1 - t0 else { continue }
                    let at = time(slice.comp(ofSource: t))
                    guard at >= trackEnds[clickTrack.trackID] ?? .zero else { continue }   // never cut a click short
                    place(clickSource, clickRange, into: clickTrack, at: at)
                }
            }
            if segmentStart > recordingStart, let prev = slices.last {
                // A join with a transition needs no click protection: its sound crossfades.
                let dissolved = layout.dissolves.contains {
                    abs($0.aEnd - prev.source.upperBound) < 1e-6 && abs($0.resume - range.lowerBound) < 1e-6
                }
                // Parts that simply continue each other (a split point) need none either.
                if !dissolved, abs(prev.source.upperBound - range.lowerBound) > 1e-6 { joins.append(time(segmentStart)) }
            }
            slices += placed
            cursor = segmentStart + t1 - t0
        }
        let recordingEnd = cursor
        let outroCompStart = cursor
        // Voice-overs and video overlays run in real time along the finished timeline: from where
        // they begin, straight across every join.
        let timelineLength = recordingEnd - recordingStart
        for clip in voClips + musicClips {
            let lo = max(clip.start, 0), hi = min(clip.end, timelineLength)
            guard hi - lo > 0.001, let src = voSources[clip.file] else { continue }
            guard let layer = (clip.isMusic ? musicLayers : voLayers).layerOf[clip.id] else { continue }
            let tracks = clip.isMusic ? musicClipTracks : voTracks
            guard layer < tracks.count else { continue }
            let fileRange = CMTimeRangeGetIntersection(CMTimeRange(start: time(clip.fileOffset + lo - clip.start), duration: time(hi - lo)),
                                                       otherRange: src.range)
            place(src.track, fileRange, into: tracks[layer], at: time(recordingStart + lo))
        }
        let placedOverlays = overlaySources.values.flatMap { source in overlayPieces(source.overlay).map { (source, $0) } }
            .sorted { $0.1.timeline.lowerBound < $1.1.timeline.lowerBound }
        for (source, piece) in placedOverlays {
            let o = source.overlay
            let lo = max(piece.timeline.lowerBound, 0), hi = min(piece.timeline.upperBound, timelineLength)
            guard hi - lo > 0.001, let layer = overlayLayers.layerOf[o.id], layer < overlayVideoTracks.count else { continue }
            let fileRange = CMTimeRange(start: time(o.fileOffset + piece.fileShift + lo - piece.timeline.lowerBound), duration: time(hi - lo))
            let at = time(recordingStart + lo)
            place(source.video, CMTimeRangeGetIntersection(fileRange, otherRange: source.videoRange), into: overlayVideoTracks[layer], at: at)
            if let (track, available) = source.audio, let target = overlayAudioTracks[layer] {
                place(track, CMTimeRangeGetIntersection(fileRange, otherRange: available), into: target, at: at)
                overlayVolumes[target.trackID, default: []].append(((recordingStart + lo)...(recordingStart + hi), o.id))
            }
        }
        if let outro { addCard(outro, length: outro.length - outroOverlap, localOffset: outroOverlap, fadeToRecording: outroOverlap == 0) }

        func compTime(ofSource t: Double) -> Double? {
            (slices.first { t >= $0.source.lowerBound && t < $0.source.upperBound } ?? slices.first { $0.source.contains(t) })
                .map { $0.comp(ofSource: t) }
        }

        // Transitions at cuts: the incoming part plays on the B tracks under the end of the outgoing one.
        var dissolves: [MediaComposition.DissolveRange] = []
        var screenB: AVMutableCompositionTrack?
        var cameraB: AVMutableCompositionTrack?
        var insertAudioB: AVMutableCompositionTrack?
        // In playing order: the B tracks are filled from front to back.
        for d in layout.dissolves.sorted(by: { (compTime(ofSource: $0.aStart) ?? 0) < (compTime(ofSource: $1.aStart) ?? 0) }) {
            guard let c0 = compTime(ofSource: d.aStart), let c1 = compTime(ofSource: d.aEnd - 1e-9),
                  abs(c1 - c0 - d.length) < 0.01 else { continue }
            if screenB == nil { screenB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: screenBTrackID) }
            if camTrack != nil, cameraB == nil { cameraB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: cameraBTrackID) }
            guard let screenB else { continue }
            for i in audioSources.indices where audioSources[i].bTarget == nil {
                audioSources[i].bTarget = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            }
            let bAudio = audioSources.compactMap { a in a.bTarget.map { (a.source, a.range, $0) } }
            if insertAudioB == nil, insertSources.values.contains(where: { $0.audio != nil }) {
                insertAudioB = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            }
            let bSlices = placeRecording(d.bStart...d.resume, at: c0, video: screenB, camera: cameraB, audio: bAudio,
                                         audioExtra: dissolveTail, inserts: true, insertTargets: (screenB, insertAudioB))
            guard !bSlices.isEmpty else { continue }
            dissolves.append(.init(start: c0, end: c0 + d.length, bSlices: bSlices, style: d.style))
        }

        // Intro/outro cards pushed over the recording are drawn on top of its first/last seconds.
        var overlays: [RenderInstruction.CardOverlay] = []
        if let intro, introOverlap > 0, let first = kept.first, let c0 = compTime(ofSource: first.lowerBound) {
            overlays.append(.init(card: intro, start: c0, end: c0 + introOverlap, localOffset: intro.length - introOverlap, fadingOut: true))
        }
        if let outro, outroOverlap > 0, let last = kept.last,
           let end = compTime(ofSource: last.upperBound - 1e-9) {
            overlays.append(.init(card: outro, start: end - outroOverlap, end: end, localOffset: 0, fadingOut: false))
        }

        // Output range for the fade from/to black (in the preview: the kept part, or the cards).
        let outputStart = intro != nil ? 0 : (kept.first.flatMap { compTime(ofSource: $0.lowerBound) } ?? recordingStart)
        let outputEnd = outro != nil ? cursor : (kept.last.flatMap { compTime(ofSource: $0.upperBound - 1e-9) } ?? recordingEnd)
        // Background music in output time: each kept part gets the music that belongs to its output
        // position, so it runs on seamlessly where playback skips a cut.
        var musicTrack: AVMutableCompositionTrack?
        if let music = settings.music, music.clipped != true {
            let asset = AVURLAsset(url: project.url.appendingPathComponent(music.file))
            if let track = try? await asset.loadTracks(withMediaType: .audio).first,
               let range = try? await track.load(.timeRange), range.duration.seconds > 0.1,
               let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                keepAlive.append(asset)
                musicTrack = target
                var pieces: [(comp: Double, output: Double, length: Double)] = []
                var output = 0.0
                if intro != nil {
                    pieces.append((0, 0, recordingStart))
                    output = recordingStart
                }
                for seg in kept {
                    guard let c = compTime(ofSource: seg.lowerBound) else { continue }
                    let length = map.length(seg)
                    pieces.append((c, output, length))
                    output += length
                }
                if outro != nil { pieces.append((outroCompStart, output, cursor - outroCompStart)) }
                let fileLength = range.end.seconds
                for piece in pieces where piece.length > 0.001 {
                    var done = 0.0
                    while done < piece.length - 0.001 {
                        var fileTime = music.fileOffset + piece.output + done
                        if music.loop { fileTime = fileTime.truncatingRemainder(dividingBy: fileLength) }
                        guard fileTime < fileLength - 0.01 else { break }
                        let chunk = min(piece.length - done, fileLength - fileTime)
                        place(track, CMTimeRange(start: time(fileTime), duration: time(chunk)), into: target, at: time(piece.comp + done))
                        done += chunk
                    }
                }
            }
        }

        // Sound effects: a whoosh where a zoom begins and where a transition starts.
        var effectsTrack: AVMutableCompositionTrack?
        if settings.soundEffects, let url = try? WhooshSound.ensureFile(for: project) {
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .audio).first, let range = try? await track.load(.timeRange),
               let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                keepAlive.append(asset)
                effectsTrack = target
                var moments = settings.zoomSegments.compactMap { compTime(ofSource: $0.start) }
                moments += dissolves.map { $0.start - 0.1 }
                for t in moments.sorted() where t >= 0 && t + WhooshSound.length <= cursor {
                    guard time(t) >= trackEnds[target.trackID] ?? .zero else { continue }
                    place(track, range, into: target, at: time(t))
                }
            }
        }

        let globalFade = settings.fadeIn > 0.01 || settings.fadeOut > 0.01
            ? RenderInstruction.GlobalFade(start: outputStart, fadeIn: settings.fadeIn, end: outputEnd, fadeOut: settings.fadeOut) : nil

        for c in cardInstructions {
            instructions.append(RenderInstruction(timeRange: c.range, renderer: renderer, card: c.card, localOffset: c.localOffset,
                                                  fadeToRecording: c.fadeToRecording, globalFade: globalFade))
        }

        // Recording instructions: one per piece, split where a transition or card overlay begins or ends.
        let dissolveTracks = screenB.map { (screen: $0.trackID, camera: cameraB?.trackID) }
        let inner = dissolves.flatMap { [$0.start, $0.end] } + overlays.flatMap { [$0.start, $0.end] }
        var lastEnd = time(recordingStart)
        for (index, slice) in slices.enumerated() {
            let start = lastEnd
            // Without an outro the last instruction must reach the very end of the composition: the
            // file's own timescale can make its tracks some microseconds longer than our rounding,
            // and macOS rejects the export of a video composition that leaves such a sliver uncovered.
            let end = index == slices.count - 1 ? (outro == nil ? max(time(recordingEnd), composition.duration) : time(recordingEnd))
                : time(slices[index + 1].compStart)
            guard end > start else { continue }
            lastEnd = end
            var bounds: [CMTime] = [start, end]
            for t in inner where t > start.seconds + 1e-3 && t < end.seconds - 1e-3 {
                let tt = time(t)
                if !bounds.contains(where: { abs(($0 - tt).seconds) < 1e-3 }) { bounds.append(tt) }
            }
            bounds.sort()
            let mapping = RenderInstruction.Mapping(compStart: slice.compStart, sourceStart: slice.source.lowerBound, rate: slice.rate)
            func rotation(_ id: UUID?) -> Int { id.flatMap { id in settings.inserts.first { $0.id == id }?.rotation } ?? 0 }
            func dissolveInfo(at mid: Double) -> RenderInstruction.DissolveInfo? {
                dissolveTracks.flatMap { tracks in
                    dissolves.first { mid > $0.start && mid < $0.end }.map {
                        let insert = $0.bSlices.first?.insertID
                        return RenderInstruction.DissolveInfo(start: $0.start, end: $0.end,
                                                              bMappings: $0.bSlices.map { .init(compStart: $0.compStart, sourceStart: $0.source.lowerBound, rate: $0.rate) },
                                                              style: $0.style, screenTrackID: tracks.screen, cameraTrackID: tracks.camera,
                                                              bIsInsert: insert != nil, bRotation: rotation(insert))
                    }
                }
            }
            if slice.insertID != nil, let insertVideo {
                for (a, b) in zip(bounds, bounds.dropFirst()) {
                    instructions.append(RenderInstruction(timeRange: CMTimeRange(start: a, end: b), renderer: renderer,
                                                          insertTrackID: insertVideo.trackID, mapping: mapping, globalFade: globalFade,
                                                          overlayTracks: overlayTracks, overlayRotations: overlayRotations,
                                                          insertRotation: rotation(slice.insertID), dissolve: dissolveInfo(at: (a.seconds + b.seconds) / 2)))
                }
                continue
            }
            for (a, b) in zip(bounds, bounds.dropFirst()) {
                let mid = (a.seconds + b.seconds) / 2
                let dissolve = dissolveInfo(at: mid)
                instructions.append(RenderInstruction(timeRange: CMTimeRange(start: a, end: b), renderer: renderer,
                                                      screenTrackID: screenTrackID,
                                                      cameraTrackID: camTrack == nil ? nil : cameraTrackID,
                                                      mapping: mapping,
                                                      fadeInStart: intro != nil && introOverlap == 0 ? recordingStart : nil,
                                                      fadeOutEnd: outro != nil && outroOverlap == 0 ? recordingEnd : nil,
                                                      dissolve: dissolve,
                                                      cardOverlay: overlays.first { mid > $0.start && mid < $0.end },
                                                      globalFade: globalFade,
                                                      overlayTracks: overlayTracks, overlayRotations: overlayRotations))
            }
        }
        instructions.sort { $0.timeRange.start < $1.timeRange.start }

        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = ScreenkastCompositor.self
        video.instructions = instructions
        video.renderSize = renderer.outputSize
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        // ScreenCaptureKit only delivers frames when the screen changes. Use our own
        // constant frame rate so cursor and zoom animate smoothly over static screens.
        video.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        var audioTracks = audioSources.map { MediaComposition.AudioTrack(track: $0.target, role: $0.role) }
        audioTracks += audioSources.compactMap { a in a.bTarget.map { MediaComposition.AudioTrack(track: $0, role: a.role, isDissolveB: true) } }
        audioTracks += voTracks.enumerated().map { MediaComposition.AudioTrack(track: $0.element, role: AudioLane.voiceOver.role, layer: $0.offset) }
        audioTracks += musicClipTracks.enumerated().map { MediaComposition.AudioTrack(track: $0.element, role: AudioLane.music.role, layer: $0.offset) }
        if let clickTrack { audioTracks.append(.init(track: clickTrack, role: "clicks")) }
        if let effectsTrack { audioTracks.append(.init(track: effectsTrack, role: "effects")) }
        if let musicTrack { audioTracks.append(.init(track: musicTrack, role: AudioLane.music.role)) }
        if let insertAudio { audioTracks.append(.init(track: insertAudio, role: "insert")) }
        if let insertAudioB { audioTracks.append(.init(track: insertAudioB, role: "insert", isDissolveB: true)) }
        audioTracks += overlayAudioTracks.values.map { MediaComposition.AudioTrack(track: $0, role: "overlay") }
        return MediaComposition(asset: composition, videoComposition: video, audioTracks: audioTracks, joins: joins,
                                dissolves: dissolves, slices: slices, totalDuration: cursor,
                                voiceOverClips: voClips + musicClips,
                                voiceOverLayers: voLayers.layerOf.merging(musicLayers.layerOf) { a, _ in a },
                                outputRange: outputStart...max(outputStart, outputEnd),
                                speech: speech, insertVolumes: insertVolumes, overlayVolumes: overlayVolumes)
    }
}

// MARK: - Custom compositor (screen + camera → FrameRenderer)

final class RenderInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    /// Composition time → source time inside one piece.
    struct Mapping {
        let compStart: Double
        let sourceStart: Double
        let rate: Double
        func source(_ t: Double) -> Double { sourceStart + (t - compStart) * rate }
    }

    /// Transition at a cut: the B tracks carry the incoming part.
    struct DissolveInfo {
        let start: Double
        let end: Double
        let bMappings: [Mapping]
        let style: TransitionStyle
        let screenTrackID: CMPersistentTrackID
        let cameraTrackID: CMPersistentTrackID?
        /// The incoming part is an inserted clip.
        var bIsInsert = false
        var bRotation = 0

        func bSource(_ t: Double) -> Double {
            (bMappings.last { t >= $0.compStart - 1e-9 } ?? bMappings[0]).source(t)
        }
    }

    /// Intro/outro card blended over the recording (the card was pushed over it).
    struct CardOverlay {
        let card: TextOverlay
        let start: Double
        let end: Double
        /// Card time at `start`.
        let localOffset: Double
        /// Intro: the card fades out over the recording; outro: it fades in.
        let fadingOut: Bool
    }

    /// Fade from black at the start and to black at the end of the output.
    struct GlobalFade {
        let start: Double
        let fadeIn: Double
        let end: Double
        let fadeOut: Double

        func alpha(at t: Double) -> Double {
            var a = 1.0
            if fadeIn > 0.01 { a = min(a, (t - start) / fadeIn) }
            if fadeOut > 0.01 { a = min(a, (end - t) / fadeOut) }
            return max(0, min(1, a))
        }
    }

    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let renderer: FrameRenderer
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let mapping: Mapping
    /// Intro/outro title card (no source frames).
    let card: TextOverlay?
    /// Card time at the start of this instruction, and whether the card fades to the background.
    let cardLocalOffset: Double
    let cardFadesToRecording: Bool
    /// The recording fades in from this composition time (after an intro) …
    let fadeInStart: Double?
    /// … and out until this one (before an outro).
    let fadeOutEnd: Double?
    let dissolve: DissolveInfo?
    let cardOverlay: CardOverlay?
    let globalFade: GlobalFade?
    /// Track of an inserted clip shown instead of the recording.
    let insertTrackID: CMPersistentTrackID?
    /// Rotation of the inserted clip (degrees).
    var insertRotation = 0
    /// Video overlays: track of each overlay's frames, and their rotation.
    var overlayTracks: [UUID: CMPersistentTrackID] = [:]
    var overlayRotations: [UUID: Int] = [:]

    /// Current frames of the video overlays.
    func overlayFrames(_ request: AVAsynchronousVideoCompositionRequest) -> [UUID: CIImage] {
        var frames: [UUID: CIImage] = [:]
        var byTrack: [CMPersistentTrackID: CIImage] = [:]
        for (id, track) in overlayTracks {
            if byTrack[track] == nil, let buffer = request.sourceFrame(byTrackID: track) { byTrack[track] = CIImage(cvPixelBuffer: buffer) }
            guard let frame = byTrack[track] else { continue }
            let r = overlayRotations[id] ?? 0
            frames[id] = r == 0 ? frame : frame.oriented(VideoRotation.orientation(r))
        }
        return frames
    }

    init(timeRange: CMTimeRange, renderer: FrameRenderer, screenTrackID: CMPersistentTrackID,
         cameraTrackID: CMPersistentTrackID?, mapping: Mapping, fadeInStart: Double? = nil, fadeOutEnd: Double? = nil,
         dissolve: DissolveInfo? = nil, cardOverlay: CardOverlay? = nil, globalFade: GlobalFade? = nil,
         overlayTracks: [UUID: CMPersistentTrackID] = [:], overlayRotations: [UUID: Int] = [:]) {
        self.overlayTracks = overlayTracks
        self.overlayRotations = overlayRotations
        self.timeRange = timeRange
        self.renderer = renderer
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.mapping = mapping
        self.card = nil
        self.cardLocalOffset = 0
        self.cardFadesToRecording = true
        self.fadeInStart = fadeInStart
        self.fadeOutEnd = fadeOutEnd
        self.dissolve = dissolve
        self.cardOverlay = cardOverlay
        self.globalFade = globalFade
        self.insertTrackID = nil
        var ids = [screenTrackID] + (cameraTrackID.map { [$0] } ?? [])
        if let dissolve { ids += [dissolve.screenTrackID] + (dissolve.cameraTrackID.map { [$0] } ?? []) }
        ids += Set(overlayTracks.values).sorted()
        requiredSourceTrackIDs = ids.map { NSNumber(value: $0) }
    }

    init(timeRange: CMTimeRange, renderer: FrameRenderer, card: TextOverlay, localOffset: Double = 0, fadeToRecording: Bool = true,
         globalFade: GlobalFade? = nil) {
        self.timeRange = timeRange
        self.renderer = renderer
        self.screenTrackID = kCMPersistentTrackID_Invalid
        self.cameraTrackID = nil
        self.mapping = Mapping(compStart: 0, sourceStart: 0, rate: 1)
        self.card = card
        self.cardLocalOffset = localOffset
        self.cardFadesToRecording = fadeToRecording
        self.fadeInStart = nil
        self.fadeOutEnd = nil
        self.dissolve = nil
        self.cardOverlay = nil
        self.globalFade = globalFade
        self.insertTrackID = nil
        requiredSourceTrackIDs = []
    }

    /// An inserted clip (its frames take the place of the recording).
    init(timeRange: CMTimeRange, renderer: FrameRenderer, insertTrackID: CMPersistentTrackID, mapping: Mapping, globalFade: GlobalFade?,
         overlayTracks: [UUID: CMPersistentTrackID] = [:], overlayRotations: [UUID: Int] = [:], insertRotation: Int = 0,
         dissolve: DissolveInfo? = nil) {
        self.overlayTracks = overlayTracks
        self.overlayRotations = overlayRotations
        self.insertRotation = insertRotation
        self.timeRange = timeRange
        self.renderer = renderer
        self.screenTrackID = kCMPersistentTrackID_Invalid
        self.cameraTrackID = nil
        self.mapping = mapping
        self.card = nil
        self.cardLocalOffset = 0
        self.cardFadesToRecording = true
        self.fadeInStart = nil
        self.fadeOutEnd = nil
        self.dissolve = dissolve
        self.cardOverlay = nil
        self.globalFade = globalFade
        self.insertTrackID = insertTrackID
        let bTracks = dissolve.map { [$0.screenTrackID] } ?? []
        requiredSourceTrackIDs = ([insertTrackID] + bTracks + Set(overlayTracks.values).sorted()).map { NSNumber(value: $0) }
    }

    /// Opacity of the recording at composition time `t` (fades next to intro/outro).
    func contentAlpha(at t: Double) -> Double {
        var a = 1.0
        if let f = fadeInStart { a = min(a, (t - f) / TextOverlay.fade) }
        if let f = fadeOutEnd { a = min(a, (f - t) / TextOverlay.fade) }
        return max(0, min(1, a))
    }

    /// Ease in and out (video transitions).
    static func smooth(_ p: Double) -> Double {
        let x = min(1, max(0, p))
        return x * x * (3 - 2 * x)
    }
}

final class ScreenkastCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                                     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                                     kCVPixelFormatType_32BGRA],
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    /// `image` dimmed towards black; `alpha` is the perceived brightness (Core Image works in linear
    /// light, where a linear ramp would stay bright for long and drop only at the end).
    static func dimmed(_ image: CIImage, _ alpha: Double, rect: CGRect) -> CIImage {
        guard alpha < 0.999 else { return image }
        return CIImage(color: .black).cropped(to: rect)
            .applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: image, kCIInputTimeKey: pow(max(0, alpha), 2.2)])
            .cropped(to: rect)
    }

    /// Transition from `a` to `b` at progress `p` (0…1).
    static func transition(_ a: CIImage, _ b: CIImage, progress p: Double, style: TransitionStyle, rect: CGRect) -> CIImage {
        func blend(_ x: CIImage, _ y: CIImage, _ q: Double) -> CIImage {
            x.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: y, kCIInputTimeKey: q]).cropped(to: rect)
        }
        switch style {
        case .dissolve:
            return blend(a, b, RenderInstruction.smooth(p))
        case .dipToBlack:
            return p < 0.5 ? dimmed(a, 1 - RenderInstruction.smooth(p * 2), rect: rect)
                : dimmed(b, RenderInstruction.smooth(p * 2 - 1), rect: rect)
        case .push:
            let e = CGFloat(RenderInstruction.smooth(p))
            let outgoing = a.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -e * rect.width, y: 0))
            let incoming = b.cropped(to: rect).transformed(by: CGAffineTransform(translationX: (1 - e) * rect.width, y: 0))
            return incoming.composited(over: outgoing).cropped(to: rect)
        }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? RenderInstruction,
              let out = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "Screenkast", code: 1, userInfo: [NSLocalizedDescriptionKey: "Compositor-Setup fehlgeschlagen"]))
            return
        }
        let size = request.renderContext.size
        let rect = CGRect(origin: .zero, size: size)
        let t = request.compositionTime.seconds
        let renderer = instruction.renderer
        var image: CIImage
        let turn = renderer.sourceRotation
        func upright(_ i: CIImage) -> CIImage { turn == 0 ? i : i.oriented(VideoRotation.orientation(turn)) }
        /// The part coming in during a transition.
        func incoming(_ d: RenderInstruction.DissolveInfo) -> CIImage? {
            guard let bFrame = request.sourceFrame(byTrackID: d.screenTrackID) else { return nil }
            if d.bIsInsert {
                var frame = CIImage(cvPixelBuffer: bFrame)
                if d.bRotation != 0 { frame = frame.oriented(VideoRotation.orientation(d.bRotation)) }
                return renderer.render(source: frame, camera: nil, time: d.bSource(t), plain: true)
            }
            let bCamera = d.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
            return renderer.render(source: upright(CIImage(cvPixelBuffer: bFrame)), camera: bCamera, time: d.bSource(t))
        }
        func blend(_ a: CIImage, _ b: CIImage, _ p: Double) -> CIImage {
            a.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: b, kCIInputTimeKey: p]).cropped(to: rect)
        }
        if let card = instruction.card {
            image = renderer.renderCard(card, localTime: t - instruction.timeRange.start.seconds + instruction.cardLocalOffset,
                                        fadeToRecording: instruction.cardFadesToRecording)
        } else if let insert = instruction.insertTrackID {
            var frame = request.sourceFrame(byTrackID: insert).map { CIImage(cvPixelBuffer: $0) }
            if instruction.insertRotation != 0 { frame = frame?.oriented(VideoRotation.orientation(instruction.insertRotation)) }
            image = renderer.render(source: frame, camera: nil, time: instruction.mapping.source(t), plain: true,
                                    overlays: instruction.overlayFrames(request))
            if let d = instruction.dissolve, let b = incoming(d) {
                image = Self.transition(image, b, progress: (t - d.start) / max(1e-6, d.end - d.start), style: d.style, rect: rect)
            }
        } else {
            let screen = request.sourceFrame(byTrackID: instruction.screenTrackID).map { upright(CIImage(cvPixelBuffer: $0)) }
            let camera = instruction.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
            image = renderer.render(source: screen, camera: camera, time: instruction.mapping.source(t),
                                    contentAlpha: instruction.contentAlpha(at: t), overlays: instruction.overlayFrames(request))
            if let d = instruction.dissolve, let b = incoming(d) {
                image = Self.transition(image, b, progress: (t - d.start) / max(1e-6, d.end - d.start), style: d.style, rect: rect)
            }
            if let o = instruction.cardOverlay {
                let p = (t - o.start) / max(1e-6, o.end - o.start)
                let card = renderer.renderCard(o.card, localTime: o.localOffset + t - o.start, fadeToRecording: false)
                image = blend(image, card, RenderInstruction.smooth(o.fadingOut ? 1 - p : p))
            }
        }
        if let fade = instruction.globalFade {
            image = Self.dimmed(image, fade.alpha(at: t), rect: rect)
        }
        context.render(image, to: out, bounds: rect, colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: out)
    }

    func cancelAllPendingVideoCompositionRequests() {}
}
