import Foundation
import AVFoundation
import CoreImage

/// Selftests for the live strength of the voice enhancement (wet/dry mix, per range), breath
/// ranges, labelled automatic cuts with a sound crossfade, and the cursor lane.
enum ReviewTest {
    private static func fail(_ m: String) -> NSError {
        NSError(domain: "selftest", code: 95, userInfo: [NSLocalizedDescriptionKey: m])
    }

    static func run(base: Project) async throws {
        try await mixTest(base)
        try await MainActor.run { try editorTest(base) }
        try cursorTest(base)
    }

    private static func mixed(_ media: MediaComposition, _ settings: EditSettings, role: String) async throws -> [Float] {
        let tracks = media.audioTracks.filter { $0.role == role && !$0.isDissolveB }.map(\.track)
        guard !tracks.isEmpty else { throw fail("no \(role) track") }
        let reader = try AVAssetReader(asset: media.asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        ])
        output.audioMix = media.audioMix(settings: settings)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? fail("reader") }
        var samples = [Float](repeating: 0, count: Int(media.totalDuration * 48_000) + 4800)
        while let sb = output.copyNextSampleBuffer() {
            guard let block = sb.dataBuffer else { continue }
            let start = Int((sb.presentationTimeStamp.seconds * 48_000).rounded())
            let n = CMBlockBufferGetDataLength(block) / 4
            var chunk = [Float](repeating: 0, count: n)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            for i in 0..<n where start + i >= 0 && start + i < samples.count { samples[start + i] = chunk[i] }
        }
        return samples
    }

    private static func rms(_ s: [Float], _ a: Double, _ b: Double) -> Double {
        let lo = Int(a * 48_000), hi = min(s.count, Int(b * 48_000))
        return sqrt(s[lo..<hi].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, hi - lo)))
    }

    // MARK: Wet/dry

    private static func mixTest(_ base: Project) async throws {
        guard base.info.hasMicAudio else { print("– voice strength skipped (no mic)"); return }
        var s = EditSettings()
        s.removeEcho = false
        s.zoomSegments = []
        s.voice.enabled = true
        let p = Project(url: base.url, info: base.info, cursor: base.cursor, settings: s)
        _ = try await VoiceProcessor.process(project: p, settings: s)
        guard FileManager.default.fileExists(atPath: VoiceProcessor.micDryURL(for: p, settings: s).path) else { throw fail("no dry file") }
        // Strength 30 %, but 100 % (only enhanced) from 1 to 2 s.
        p.settings.voice.intensity = 0.3
        var range = AudioMute(lane: .mic, start: 1.0, end: 2.0)
        range.gain = 1
        range.enhance = 1
        p.settings.audioMutes = [range]
        let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30,
                                                segments: p.settings.keptSegments(duration: base.info.duration))
        var full = p.settings
        full.voice.intensity = 1
        full.audioMutes = []
        let wetFull = rms(try await mixed(media, full, role: "mic"), 0.2, 0.8)
        let wet = try await mixed(media, p.settings, role: "mic")
        let dry = try await mixed(media, p.settings, role: "micdry")
        let wetShare = rms(wet, 0.2, 0.8) / max(1e-9, wetFull)
        let wetInRange = rms(wet, 1.2, 1.8) / max(1e-9, rms(try await mixed(media, full, role: "mic"), 1.2, 1.8))
        let dryInRange = rms(dry, 1.2, 1.8)
        guard abs(wetShare - 0.3) < 0.05, abs(wetInRange - 1) < 0.05, dryInRange < 0.002, rms(dry, 0.2, 0.8) > 0.01 else {
            throw fail(String(format: "voice strength: wet %.2f (30 %%), in range %.2f (100 %%), dry in range %.4f", wetShare, wetInRange, dryInRange))
        }
        print(String(format: "✓ voice enhancement strength: live mix of enhanced and dry microphone (%.0f %% enhanced), a range at 100 %% overrides it", wetShare * 100))
    }

    // MARK: Breaths, automatic cuts

    @MainActor
    private static func editorTest(_ base: Project) throws {
        var s = EditSettings()
        s.removeEcho = false
        s.words = [TranscriptWord(text: "Hallo", start: 0.3, end: 0.6), TranscriptWord(text: "äh", start: 0.9, end: 1.1),
                   TranscriptWord(text: "Welt", start: 1.5, end: 1.9)]
        let editor = EditorModel(project: Project(url: base.url, info: base.info, cursor: base.cursor, settings: s))
        editor.removeFillerWords()
        guard let cut = editor.settings.cuts.first, cut.origin == .filler, cut.dissolve == CutRange.speechCrossfade,
              editor.settings.dissolves(duration: editor.duration).count == 1 else {
            throw fail("filler cut: \(editor.settings.cuts)")
        }
        editor.restoreCuts(.filler)
        guard editor.settings.cuts.isEmpty else { throw fail("restore filler cuts") }
        // Breath ranges: volume follows the setting, review jumps to them, all can be removed.
        var b = AudioMute(lane: .mic, start: 2.0, end: 2.4)
        b.kind = .breath
        b.gain = 0.25
        editor.settings.audioMutes = [b]
        editor.setBreathReduction(20)
        guard abs((editor.settings.audioMutes.first?.gain ?? 0) - 0.1) < 1e-6 else { throw fail("breath reduction") }
        editor.seek(to: 0.1)
        editor.reviewNext(breaths: true)
        guard editor.selection == .mute(b.id), editor.currentTime < 2.0, editor.currentTime > 0.3 else {
            throw fail("review breaths: \(String(describing: editor.selection)) at \(editor.currentTime)")
        }
        editor.removeBreathRegions()
        guard editor.breathRegions.isEmpty else { throw fail("remove breaths") }
        // Breaths never lie on recognized words ("sich" has a breathy "ch").
        let kept = EditorModel.outsideWords([0.0...0.5, 1.0...1.25], words: [TranscriptWord(text: "sich", start: 0.95, end: 1.2)])
        guard kept == [0.0...0.5] else { throw fail("breaths outside words: \(kept)") }
        // German filler list: "Er" and "um" are words, "äh" is not.
        let de = EditorModel.fillerWords(language: "de-DE")
        guard de.contains("äh"), !de.contains("er"), !de.contains("um") else { throw fail("German fillers") }
        // Cursor lane: a range, edited and clamped.
        editor.addCursorRange(start: 1.0, end: 1.1, effect: .hidden)
        guard let r = editor.settings.cursorRanges.first, editor.display(r.end) - editor.display(r.start) >= 0.3 - 1e-9,
              editor.selection == .cursorRange(r.id) else { throw fail("cursor range") }
        print("✓ automatic edits: filler cut labelled with a sound crossfade, taken back at once; breath ranges follow the strength, review jumps to them; cursor range added")
    }

    // MARK: Cursor lane

    private static func cursorTest(_ base: Project) throws {
        let ctx = CIContext()
        guard let sample = base.cursor.samples.first(where: { $0.x > 0.2 && $0.x < 0.8 && $0.y > 0.2 && $0.y < 0.8 && $0.t > 0.5 }) else {
            print("– cursor lane skipped"); return
        }
        let t = sample.t
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: base.info.pixelWidth, height: base.info.pixelHeight))
        func render(_ ranges: [CursorRange], at time: Double) -> (CIImage, FrameRenderer) {
            var s = EditSettings()
            s.zoomSegments = []
            s.hideIdleCursor = false
            s.cursorRanges = ranges
            let r = FrameRenderer(project: Project(url: base.url, info: base.info, cursor: base.cursor, settings: s))
            return (r.render(source: source, camera: nil, time: time), r)
        }
        let hidden = [CursorRange(start: max(0, t - 0.5), end: t + 0.5, effect: .hidden)]
        let (with, r) = render(hidden, at: t)
        let (without, _) = render([], at: t)
        guard let c = r.cursorPosition(at: t) else { throw fail("no cursor") }
        let q = r.outputPoint(c, at: t)
        let box = CGRect(x: q.x - 4, y: r.outputSize.height - q.y - 30, width: 30, height: 30)
        let diff = with.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: without])
            .applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: box)])
        var px = [Float](repeating: 0, count: 4)
        ctx.render(diff, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        // Outside the range the cursor is back.
        let later = base.info.duration - 0.2
        let (a, _) = render(hidden, at: later), (b, _) = render([], at: later)
        let outside = a.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: b])
            .applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(origin: .zero, size: r.outputSize))])
        var px2 = [Float](repeating: 0, count: 4)
        ctx.render(outside, toBitmap: &px2, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        guard px[0] + px[1] + px[2] > 0.3, px2[0] + px2[1] + px2[2] < 0.01 else {
            throw fail("cursor lane: hidden diff \(px), outside \(px2)")
        }
        print("✓ cursor lane: the pointer disappears inside its range only")
    }
}
