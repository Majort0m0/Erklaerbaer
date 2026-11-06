import Foundation
import AVFoundation
import CoreImage
import AppKit
import ImageIO

/// Selftests for pauses, voice enhancement, music, inserted clips, camera layouts, annotations,
/// pictures/logo, chapters, transcript editing, style presets and GIF export.
enum ExtrasTest {
    private static func fail(_ m: String) -> NSError {
        NSError(domain: "selftest", code: 50, userInfo: [NSLocalizedDescriptionKey: m])
    }

    static func run(base: Project, dir: URL) async throws {
        try pauseTest()
        try voiceTest()
        try await musicTest(base)
        try await insertTest(base, dir: dir)
        try renderTest(base, dir: dir)
        try await MainActor.run { try editorTest(base) }
        try await gifTest(base, dir: dir)
        try await MediaFeatureTest.run(base: base, dir: dir)
    }

    private static func project(_ base: Project, _ change: (inout EditSettings) -> Void) -> Project {
        var s = base.settings
        s.removeEcho = false
        s.cuts = []; s.texts = []; s.trimStart = 0; s.trimEnd = nil; s.voiceOvers = []
        change(&s)
        return Project(url: base.url, info: base.info, cursor: base.cursor, settings: s)
    }

    private static func mixed(_ media: MediaComposition, _ settings: EditSettings, role: String) async throws -> [Float] {
        let tracks = media.audioTracks.filter { $0.role == role }.map(\.track)
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

    private static func rms(_ s: [Float], _ r: ClosedRange<Double>) -> Double {
        let a = max(0, Int(r.lowerBound * 48_000)), b = min(s.count, Int(r.upperBound * 48_000))
        guard b > a else { return 0 }
        return sqrt(s[a..<b].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(b - a))
    }

    private static func amplitude(_ s: [Float], _ r: ClosedRange<Double>, freq: Double) -> Double {
        let a = max(0, Int(r.lowerBound * 48_000)), b = min(s.count, Int(r.upperBound * 48_000))
        guard b > a else { return 0 }
        var re = 0.0, im = 0.0
        for i in a..<b {
            let ph = 2 * .pi * freq * Double(i) / 48_000
            re += Double(s[i]) * cos(ph); im += Double(s[i]) * sin(ph)
        }
        return 2 * sqrt(re * re + im * im) / Double(b - a)
    }

    // MARK: Pauses

    private static func pauseTest() throws {
        // 1 s speech, 1.5 s silence, 1 s speech, 0.3 s silence, 1 s speech (100 buckets per second).
        var peaks: [Float] = []
        func add(_ seconds: Double, _ level: Float) {
            for i in 0..<Int(seconds * 100) { peaks.append(level * (0.6 + 0.4 * Float(abs(sin(Double(i) * 0.7))))) }
        }
        add(1, 0.3); add(1.5, 0.002); add(1, 0.3); add(0.3, 0.002); add(1, 0.3)
        let pauses = PauseDetector.pauses(peaks, options: .init(minPause: 0.8, keep: 0.3, sensitivity: 0.5))
        guard pauses.count == 1, abs(pauses[0].lowerBound - 1.15) < 0.02, abs(pauses[0].upperBound - 2.35) < 0.02 else {
            throw fail("pauses: \(pauses)")
        }
        let speech = PauseDetector.speech(peaks, duration: 4.8)
        guard speech.count == 2, abs(speech[0].upperBound - 1.0) < 0.02, abs(speech[1].lowerBound - 2.5) < 0.02 else {
            throw fail("speech ranges: \(speech)")
        }
        print("✓ pause detection: 1.5 s pause found (cut 1.15–2.35 s, 0.3 s kept), 0.3 s gap kept; speech ranges for ducking")
    }

    // MARK: Voice enhancement

    private static func voiceTest() throws {
        let sr = 48_000.0
        // Loudness reference: 1 kHz sine at −20 dBFS → −23 LUFS (mono).
        let sine = (0..<Int(sr * 3)).map { Float(0.1 * sin(2 * .pi * 1000 * Double($0) / sr)) }
        let reference = VoiceProcessor.loudness(sine)
        guard abs(reference + 23.01) < 0.3 else { throw fail(String(format: "loudness reference %.2f LUFS", reference)) }
        // Quiet "speech" (bursts of a 300 Hz tone) over hiss.
        var rng = SystemRandomNumberGenerator()
        let signal = (0..<Int(sr * 8)).map { i -> Float in
            let t = Double(i) / sr
            let voiced = Int(t / 0.8) % 2 == 0
            let tone = voiced ? 0.04 * sin(2 * .pi * 300 * t) * (0.6 + 0.4 * sin(2 * .pi * 3 * t)) : 0
            return Float(tone) + Float.random(in: -0.01...0.01, using: &rng)
        }
        let (out, result) = VoiceProcessor.enhance(signal, settings: VoiceEnhancement(enabled: true, noiseReduction: 0.7, normalize: true, targetLUFS: -16))
        let peak = out.map(abs).max() ?? 0
        // Noise relative to speech in the result (the gain changes both).
        func level(_ x: [Float], _ r: ClosedRange<Double>) -> Double {
            let a = Int(r.lowerBound * sr), b = Int(r.upperBound * sr)
            return sqrt(x[a..<b].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(b - a))
        }
        let snrBefore = 20 * log10(level(signal, 0.1...0.7) / level(signal, 0.9...1.5))
        let snrAfter = 20 * log10(level(out, 0.1...0.7) / level(out, 0.9...1.5))
        guard abs(result.loudnessAfter + 16) < 1, peak <= 0.9, snrAfter - snrBefore > 6 else {   // gentle by design
            throw fail(String(format: "voice: %.1f → %.1f LUFS, peak %.2f, speech/noise %.1f → %.1f dB",
                              result.loudnessBefore, result.loudnessAfter, peak, snrBefore, snrAfter))
        }
        // Room noise alone is cleaned but not amplified.
        let hiss = (0..<Int(sr * 6)).map { _ in Float.random(in: -0.004...0.004, using: &rng) }
        let (_, noiseOnly) = VoiceProcessor.enhance(hiss, settings: VoiceEnhancement(enabled: true, noiseReduction: 0.6, normalize: true, targetLUFS: -16))
        guard noiseOnly.loudnessAfter < noiseOnly.loudnessBefore + 1 else {
            throw fail(String(format: "noise-only track amplified: %.1f → %.1f LUFS", noiseOnly.loudnessBefore, noiseOnly.loudnessAfter))
        }
        print(String(format: "✓ voice enhancement: loudness reference −23.0 LUFS ok; %.1f → %.1f LUFS, speech/noise %.0f → %.0f dB, peak %.2f; "
                     + "noise-only track not amplified (%.0f → %.0f LUFS)",
                     result.loudnessBefore, result.loudnessAfter, snrBefore, snrAfter, peak, noiseOnly.loudnessBefore, noiseOnly.loudnessAfter))
    }

    // MARK: Music

    /// 3 s of 330 Hz looped under a 4 s video with a cut; continuous, ducked under speech, fading out.
    private static func musicTest(_ base: Project) async throws {
        let file = "media/selftest-music.caf"
        let url = base.url.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EchoCanceller.writeCAF((0..<(48_000 * 3)).map { Float(0.3 * sin(2 * .pi * 330 * Double($0) / 48_000)) }, to: url)
        var music = BackgroundMusic(file: file, name: "Test")
        music.volume = 1; music.fadeIn = 0.01; music.fadeOut = 0.5; music.duckLevel = 0.25
        let p = project(base) { $0.music = music; $0.cuts = [CutRange(start: 1.5, end: 2.0)] }
        let kept = p.settings.keptSegments(duration: base.info.duration)
        let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30, segments: kept,
                                                speech: [0.6...0.9])
        let audio = try await mixed(media, p.settings, role: "music")
        let total = media.totalDuration   // 3.5 s
        // Every 0.25 s window from 0.2 s to 2.8 s carries music (incl. across the cut at 1.5 s and the loop at 3 s).
        var gaps: [Double] = []
        for t in stride(from: 0.2, to: total - 0.6, by: 0.25) where !(0.4...1.2).contains(t) {
            if rms(audio, t...(t + 0.2)) < 0.15 { gaps.append(t) }
        }
        let normal = rms(audio, 0.1...0.4), ducked = rms(audio, 0.7...0.85), end = rms(audio, (total - 0.06)...(total - 0.01))
        let pitch = amplitude(audio, 2.0...2.4, freq: 330) / 0.3
        guard gaps.isEmpty, abs(ducked / normal - 0.25) < 0.06, end < normal * 0.25, pitch > 0.8 else {
            throw fail(String(format: "music: gaps %@, level %.3f, ducked %.3f, end %.3f, 330 Hz %.2f", gaps.description, normal, ducked, end, pitch))
        }
        print(String(format: "✓ background music: continuous across the cut and the loop, ducked to %.0f %% under speech, fades out",
                     ducked / normal * 100))
    }

    // MARK: Inserted clip

    private static func insertTest(_ base: Project, dir: URL) async throws {
        let clipURL = base.url.appendingPathComponent("media/selftest-clip.mov")
        try? FileManager.default.removeItem(at: clipURL)
        try await SelfTest.writeSyntheticVideo(url: clipURL, width: 480, height: 270, fps: 30, duration: 1.0, audio: [(role: "system", freq: 880)])
        let length = try await AVURLAsset(url: clipURL).load(.duration).seconds
        let clip = InsertClip(file: "media/selftest-clip.mov", name: "Clip", at: 2.0, duration: length, fileDuration: length)
        let p = project(base) { $0.inserts = [clip] }
        let duration = base.info.duration
        let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30,
                                                segments: p.settings.keptSegments(duration: duration))
        guard abs(media.totalDuration - (duration + length - FreezeFrame.span)) < 0.02,
              abs(p.settings.outputDuration(duration: duration) - media.totalDuration) < 0.02 else {
            throw fail("insert: composition \(media.totalDuration) for clip \(length)")
        }
        let audio = try await mixed(media, p.settings, role: "insert")
        let inside = amplitude(audio, 2.2...2.8, freq: 880), outside = rms(audio, 0.5...1.5)
        let mic = try await mixed(media, p.settings, role: "mic")
        let micDuring = rms(mic, 2.2...2.8), micAfter = rms(mic, (2.0 + length + 0.2)...(2.0 + length + 0.8))
        let gen = AVAssetImageGenerator(asset: media.asset)
        gen.videoComposition = media.videoComposition
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let during = try await gen.image(at: CMTime(seconds: 2.5, preferredTimescale: 600)).image
        guard inside > 0.1, outside < 0.01, micDuring < 0.01, micAfter > 0.1, during.width > 0 else {
            throw fail(String(format: "insert sound: clip %.3f, outside %.3f, mic during %.3f, after %.3f", inside, outside, micDuring, micAfter))
        }
        print(String(format: "✓ inserted clip: +%.1f s, its picture and sound play while the recording waits, then the recording continues", length))
    }

    // MARK: Camera layouts, annotations, pictures, logo

    private static func meanDiff(_ a: CIImage, _ b: CIImage, in rect: CGRect, context: CIContext) -> Double {
        let diff = a.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: b])
            .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        var px = [Float](repeating: 0, count: 4)
        context.render(diff, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Double(px[0] + px[1] + px[2]) / 3 * 255
    }

    private static func average(_ image: CIImage, in rect: CGRect, context: CIContext) -> (r: Double, g: Double, b: Double) {
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        var px = [Float](repeating: 0, count: 4)
        context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return (Double(px[0]), Double(px[1]), Double(px[2]))
    }

    private static func renderTest(_ base: Project, dir: URL) throws {
        let ctx = CIContext()
        // Same size as the recording, so the UI mapping (outputPoint) matches the rendered layout.
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: base.info.pixelWidth, height: base.info.pixelHeight))
        let camera = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        // Camera layouts: normal (0–1 s), large (1–2), full frame (2–3), hidden (3–4).
        let p = project(base) {
            $0.background = .color(red: 0.5, green: 0.5, blue: 0.5)
            $0.cameraVisible = true
            $0.cameraLayouts = [CameraLayoutRange(start: 1, end: 2, layout: .large), CameraLayoutRange(start: 2.3, end: 3, layout: .fullscreen),
                                CameraLayoutRange(start: 3.3, end: 4, layout: .hidden)]
        }
        let r = FrameRenderer(project: p)
        let out = r.outputSize
        let full = CGRect(origin: .zero, size: out)
        func redShare(_ t: Double) -> Double {
            let img = r.render(source: source, camera: camera, time: t)
            let a = average(img, in: full, context: ctx)
            return max(0, a.r - (a.g + a.b) / 2)
        }
        let normal = redShare(0.3), large = redShare(1.5), fullscreen = redShare(2.6), hidden = redShare(3.7)
        guard large > normal * 2, fullscreen > 0.9, hidden < 0.01, normal > 0.02 else {
            throw fail(String(format: "camera layouts: red %.3f / %.3f / %.3f / %.3f", normal, large, fullscreen, hidden))
        }

        // Annotations on the recording.
        let frame = Annotation(kind: .frame, start: 0, end: 4, x: 0.3, y: 0.3, width: 0.4, height: 0.4, color: .red)
        let spot = Annotation(kind: .spotlight, start: 0, end: 4, x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let arrow = Annotation(kind: .arrow, start: 0, end: 4, x: 0.2, y: 0.2, width: 0.3, height: 0.3, color: .yellow)
        let plain = FrameRenderer(project: project(base) { $0.zoomSegments = [] })
        func rendered(_ a: Annotation) -> CIImage {
            FrameRenderer(project: project(base) { $0.zoomSegments = []; $0.annotations = [a] }).render(source: source, camera: nil, time: 2)
        }
        let without = plain.render(source: source, camera: nil, time: 2)
        let map = { (x: Double, y: Double) -> CGPoint in
            let q = plain.outputPoint(CGPoint(x: x, y: y), at: 2)
            return CGPoint(x: q.x, y: out.height - q.y)
        }
        func box(_ c: CGPoint, _ size: CGFloat = 8) -> CGRect { CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size) }
        let frameImg = rendered(frame), spotImg = rendered(spot), arrowImg = rendered(arrow)
        let onEdge = meanDiff(frameImg, without, in: box(map(0.3, 0.5)), context: ctx)
        let center = meanDiff(frameImg, without, in: box(map(0.5, 0.5), 30), context: ctx)
        let spotInside = meanDiff(spotImg, without, in: box(map(0.5, 0.5), 30), context: ctx)
        let spotOutside = average(spotImg, in: box(map(0.1, 0.1), 20), context: ctx).g / max(0.001, average(without, in: box(map(0.1, 0.1), 20), context: ctx).g)
        let arrowHead = meanDiff(arrowImg, without, in: box(map(0.49, 0.49), 10), context: ctx)
        guard onEdge > 40, center < 0.5, spotInside < 1, spotOutside < 0.6, arrowHead > 30 else {
            throw fail(String(format: "annotations: frame edge %.1f centre %.2f, spotlight inside %.2f outside %.2f, arrow %.1f",
                              onEdge, center, spotInside, spotOutside, arrowHead))
        }

        // Picture and logo (fixed in the output).
        let png = base.url.appendingPathComponent("media/selftest-logo.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 100).fill()
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])?.write(to: png)
        let overlay = ImageOverlay(file: "media/selftest-logo.png", start: 1, end: 3, x: 0.25, y: 0.25, width: 0.2)
        let mark = Watermark(file: "media/selftest-logo.png", corner: .bottomRight, size: 0.15, opacity: 1)
        let pr = FrameRenderer(project: project(base) { $0.zoomSegments = []; $0.images = [overlay]; $0.watermark = mark })
        let withPictures = pr.render(source: source, camera: nil, time: 2)
        guard let picRect = pr.imageFrame(overlay, out: out), let markRect = pr.watermarkFrame(mark, out: out) else { throw fail("picture frames") }
        let pic = average(withPictures, in: picRect.insetBy(dx: 4, dy: 4), context: ctx)
        let logo = average(withPictures, in: markRect.insetBy(dx: 4, dy: 4), context: ctx)
        let afterPicture = meanDiff(pr.render(source: source, camera: nil, time: 3.6), without, in: picRect, context: ctx)
        guard pic.g > 0.8, pic.r < 0.2, logo.g > 0.8, afterPicture < 0.5, markRect.maxX > out.width * 0.9, markRect.minY < out.height * 0.1 else {
            throw fail("pictures: overlay \(pic), logo \(logo), after \(afterPicture)")
        }
        if let cg = ctx.createCGImage(arrowImg, from: full) {
            try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("annotations.png"))
        }
        print(String(format: "✓ camera layouts (red share %.2f → large %.2f → full %.2f → hidden %.2f), frame/spotlight/arrow, picture and logo",
                     normal, large, fullscreen, hidden))
    }

    // MARK: Editor: chapters, transcript, styles

    @MainActor
    private static func editorTest(_ base: Project) throws {
        let p = project(base) { $0.cuts = [CutRange(start: 1.0, end: 1.5)]; $0.chapters = []; $0.words = [] }
        let editor = EditorModel(project: p)
        // Chapters: 0.8 s and 2.0 s (after a 0.5 s cut) → 0.8 s and 1.5 s in the video, plus "Start" at 0:00.
        editor.seek(to: 0.8); editor.addChapter()
        editor.seek(to: 2.0); editor.addChapter()
        let chapters = editor.outputChapters
        guard chapters.count == 3, chapters[0].time == 0, abs(chapters[1].time - 0.8) < 1e-6, abs(chapters[2].time - 1.5) < 1e-6,
              editor.youTubeChapterText.hasPrefix("0:00 Start\n0:00 Kapitel 1"), editor.youTubeChapterProblem != nil,
              editor.outputTime(ofSource: 1.2) == nil else {
            throw fail("chapters: \(chapters), text \(editor.youTubeChapterText)")
        }

        // Transcript: filler "äh", the repeated "das", cut and restore words.
        editor.settings.cuts = []
        editor.settings.words = [TranscriptWord(text: "Hallo", start: 0.1, end: 0.4), TranscriptWord(text: " äh", start: 0.5, end: 0.8),
                                 TranscriptWord(text: " das", start: 0.9, end: 1.2), TranscriptWord(text: " das", start: 1.3, end: 1.6),
                                 TranscriptWord(text: " ist", start: 1.8, end: 2.2), TranscriptWord(text: " gut.", start: 2.3, end: 2.7)]
        guard editor.fillerWordIndices == [1, 2] else { throw fail("filler words \(editor.fillerWordIndices)") }
        editor.removeFillerWords()
        guard editor.isWordRemoved(1), editor.isWordRemoved(2), !editor.isWordRemoved(3), !editor.isWordRemoved(0) else {
            throw fail("remove fillers: \(editor.settings.cuts)")
        }
        editor.restoreWords(1...1)
        guard !editor.isWordRemoved(1), editor.isWordRemoved(2) else { throw fail("restore word") }
        editor.selection = nil   // as a click on a word does
        editor.transcriptSelection = 4...5
        editor.deleteSelection()
        guard editor.isWordRemoved(4), editor.isWordRemoved(5), editor.transcriptSelection == nil else { throw fail("cut words") }
        editor.undo()
        guard !editor.isWordRemoved(4) else { throw fail("undo cut words") }

        // Style preset: look changes, content stays.
        let cutsBefore = editor.settings.cuts
        guard let borderless = StyleLibrary.builtIn.first(where: { $0.name == "Randlos" }) else { throw fail("built-in styles") }
        editor.applyStyle(borderless)
        guard editor.settings.padding == 0, editor.settings.cornerRadius == 0, editor.settings.cuts == cutsBefore,
              StyleLibrary.builtIn.map(\.id) == StyleLibrary.builtIn.map(\.id) else {
            throw fail("style preset")
        }
        print("✓ chapters (output times, YouTube text and check), transcript (filler words, repeats, cut/restore/undo), style preset")
    }

    // MARK: GIF

    private static func gifTest(_ base: Project, dir: URL) async throws {
        let p = project(base) { $0.trimEnd = 1.0 }
        let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30,
                                                segments: p.settings.keptSegments(duration: base.info.duration))
        let url = dir.appendingPathComponent("export.gif")
        try await GIFExporter.export(media: media, renderSize: FrameRenderer(project: p).outputSize, to: url) { _ in }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) >= 11,
              let first = CGImageSourceCreateImageAtIndex(source, 0, nil), first.width <= 720 else {
            throw fail("GIF export")
        }
        print("✓ GIF export: \(CGImageSourceGetCount(source)) frames, \(first.width)×\(first.height)")
    }
}
