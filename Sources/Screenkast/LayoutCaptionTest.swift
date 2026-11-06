import Foundation
import AVFoundation
import CoreImage
import AppKit

/// Selftests for layouts per format, caption styles and modes, captions from the voice-over lane,
/// clicks in the preview, external audio as narration and breath reduction.
enum LayoutCaptionTest {
    private static func fail(_ m: String) -> NSError {
        NSError(domain: "selftest", code: 70, userInfo: [NSLocalizedDescriptionKey: m])
    }

    static func run(base: Project, dir: URL) async throws {
        try layoutTest(base)
        try captionStyleTest(base)
        try breathTest()
        try await MainActor.run { try previewClickTest(base) }
        try await narrationTest(base, dir: dir)
        try await AssistantTest.run(base: base, dir: dir)
    }

    private static func project(_ base: Project, _ change: (inout EditSettings) -> Void) -> Project {
        var s = EditSettings()
        s.removeEcho = false
        s.zoomSegments = []
        change(&s)
        return Project(url: base.url, info: base.info, cursor: base.cursor, settings: s)
    }

    // MARK: Layout per format

    private static func layoutTest(_ base: Project) throws {
        var s = EditSettings()
        s.padding = 0.1                       // own choice in 16:9
        s.switchAspect(to: .vertical)
        let p = Project(url: base.url, info: base.info, cursor: base.cursor, settings: s)
        let out = FrameRenderer(project: p).outputSize
        let layout = FrameLayout(out: out, sourceSize: CGSize(width: base.info.pixelWidth, height: base.info.pixelHeight),
                                 padding: s.padding, contentY: s.contentY)
        let cam = FrameRenderer.cameraRect(settings: s, out: out, cameraAspect: 4.0 / 3.0).rect
        // Core Image: origin bottom-left. Recording in the upper half, camera below it, centered.
        guard out.height > out.width, layout.content.midY > out.height * 0.6, cam.midY < out.height * 0.35,
              abs(cam.midX - out.width / 2) < 2, cam.maxY < layout.content.minY else {
            throw fail("portrait layout: content \(layout.content), camera \(cam) in \(out)")
        }
        s.cameraY = 0.7                        // own change in 9:16
        s.switchAspect(to: .wide)
        guard abs(s.padding - 0.1) < 1e-9, s.contentY == nil, s.cameraX == nil else { throw fail("back to 16:9: \(s.currentLayout)") }
        s.switchAspect(to: .vertical)
        guard s.cameraY == 0.7, s.contentY != nil else { throw fail("portrait layout not remembered: \(s.currentLayout)") }
        print("✓ layout per format: portrait puts the recording at the top and the camera large below it; each format keeps its own changes")
    }

    // MARK: Caption styles

    private static func captionStyleTest(_ base: Project) throws {
        let ctx = CIContext()
        let caption = Caption(start: 0.5, end: 2.5, text: "Hallo zusammen das ist ein Test")
        let source = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: base.info.pixelWidth, height: base.info.pixelHeight))
        func frame(_ change: (inout CaptionStyle) -> Void, at t: Double = 1.0) -> (CGRect?, CIImage) {
            let p = project(base) { $0.captions = [caption]; change(&$0.captionStyle) }
            let r = FrameRenderer(project: p)
            return (r.captionFrame(at: t), r.render(source: source, camera: nil, time: t))
        }
        let (sentence, _) = frame { $0.mode = .sentence }
        let (chunk, _) = frame { $0.mode = .chunks }
        let (word, _) = frame { $0.mode = .word }
        let (high, highImg) = frame { $0.mode = .highlight; $0.highlightColor = RGBAColor(r: 1, g: 0.85, b: 0); $0.box = .clear }
        let (top, _) = frame { $0.y = 0.15 }
        guard let sentence, let chunk, let word, let high, let top else { throw fail("captions not drawn") }
        // Highlighted word: some yellow pixels in the caption (R and G clearly above B).
        let avg = highImg.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: high)])
        var px = [Float](repeating: 0, count: 4)
        ctx.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        let out = FrameRenderer(project: project(base) { _ in }).outputSize
        guard word.width < chunk.width, chunk.width < sentence.width, top.midY > out.height * 0.7, sentence.midY < out.height * 0.3 else {
            throw fail("caption modes: sentence \(sentence.width), groups \(chunk.width), word \(word.width), top \(top.midY)")
        }
        // Words: the transcript's times when they match the caption, else spread by length.
        var s = EditSettings()
        s.words = [TranscriptWord(text: "Hallo", start: 0.6, end: 0.9), TranscriptWord(text: "Welt", start: 1.4, end: 1.8)]
        let matched = s.captionTokens(Caption(start: 0.5, end: 2.0, text: "Hallo Welt"))
        let spread = s.captionTokens(Caption(start: 0.5, end: 2.0, text: "Hallo liebe Welt"))
        guard matched.map(\.start) == [0.6, 1.4], spread.count == 3, abs(spread[0].start - 0.5) < 1e-9, abs(spread[2].end - 2.0) < 1e-9,
              EditSettings.captionGroups(["Hallo", "zusammen,", "das", "ist", "ein", "Test"]).map(\.count) == [2, 3, 1] else {
            throw fail("caption tokens: \(matched.map(\.start)), \(spread.map(\.start))")
        }
        guard px[0] > 0.7, px[1] > 0.6 else { throw fail("highlighted word not coloured: \(px)") }
        print(String(format: "✓ caption styles: sentence %.0f px, word groups %.0f px, word for word %.0f px wide, highlighted word, position at the top; word times from the transcript",
                     sentence.width, chunk.width, word.width))
    }

    // MARK: Breaths

    private static func breathTest() throws {
        let rate = 48_000.0
        var x = [Float](repeating: 0, count: Int(rate * 4.5))
        var seed: UInt32 = 7
        func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) * 2 - 1 }
        for i in x.indices { x[i] = 0.0008 * noise() }   // room
        // Voice: harmonics of 140 Hz, 0–1.2 s and 1.8–3.0 s.
        func voice(_ a: Double, _ b: Double) {
            for i in Int(a * rate)..<Int(b * rate) {
                let t = Double(i) / rate
                var v = 0.0
                for h in 1...8 { v += sin(2 * .pi * 140 * Double(h) * t) / Double(h) }
                x[i] += Float(0.25 * v * (0.8 + 0.2 * sin(2 * .pi * 3 * t)))
            }
        }
        voice(0, 1.2); voice(1.8, 3.0)
        // Breath 1.3–1.7 s: noise, low-passed (~2.5 kHz), about 26 dB below the voice.
        var lp: Float = 0
        let a1 = Float(exp(-2 * Double.pi * 2500 / rate))
        for i in Int(1.3 * rate)..<Int(1.7 * rate) { lp = a1 * lp + (1 - a1) * noise(); x[i] += 0.12 * lp }
        // "sch" 3.2–3.45 s: bright noise (high-passed), must stay.
        var prev: Float = 0
        for i in Int(3.2 * rate)..<Int(3.45 * rate) { let n = noise(); x[i] += 0.03 * (n - prev); prev = n }
        let found = VoiceProcessor.breaths(x, sensitivity: 0.5)
        guard found.count == 1, let b = found.first, b.lowerBound > 1.2, b.lowerBound < 1.4, b.upperBound > 1.6, b.upperBound < 1.8 else {
            throw fail("breaths found: \(found)")
        }
        func rms(_ s: [Float], _ a: Double, _ b: Double) -> Double {
            let lo = Int(a * rate), hi = Int(b * rate)
            return sqrt(s[lo..<hi].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(hi - lo))
        }
        var y = x
        VoiceProcessor.reduce(&y, ranges: found, byDB: 18)
        let breathDrop = 20 * log10(rms(x, 1.4, 1.6) / rms(y, 1.4, 1.6))
        let voiceChange = 20 * log10(rms(x, 0.2, 1.0) / rms(y, 0.2, 1.0))
        let schChange = 20 * log10(rms(x, 3.25, 3.4) / rms(y, 3.25, 3.4))
        guard abs(breathDrop - 18) < 1.5, abs(voiceChange) < 0.05, abs(schChange) < 0.05 else {
            throw fail(String(format: "breath reduction: breath −%.1f dB, voice %.2f dB, sch %.2f dB", breathDrop, voiceChange, schChange))
        }
        print(String(format: "✓ breaths: the breath between two phrases found (%.2f–%.2f s) and lowered by %.0f dB; voice and \"sch\" untouched",
                     b.lowerBound, b.upperBound, breathDrop))
    }

    // MARK: Clicks in the preview

    @MainActor
    private static func previewClickTest(_ base: Project) throws {
        var text = TextOverlay(kind: .lowerThird, start: 0, end: base.info.duration, title: "Titel", subtitle: "Untertitel")
        text.x = 0.06; text.y = 0.2
        let p = project(base) {
            $0.cameraVisible = true; $0.cameraCorner = .bottomRight
            $0.texts = [text]
            $0.captions = [Caption(start: 0, end: base.info.duration, text: "Untertitel im Bild")]
        }
        let editor = EditorModel(project: p)
        editor.seek(to: 1.0)
        let out = editor.renderer.outputSize
        let view = CGSize(width: 800, height: 800 * out.height / out.width)
        let k = view.width / out.width
        func viewPoint(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX * k, y: (out.height - r.midY) * k) }
        let cam = FrameRenderer.cameraRect(settings: editor.settings, out: out, cameraAspect: editor.cameraAspect).rect
        guard let captionRect = editor.renderer.captionFrame(at: editor.currentTime) else { throw fail("no caption frame") }
        let onCamera = editor.previewElement(at: viewPoint(cam), viewSize: view)
        let onText = editor.previewElement(at: viewPoint(editor.renderer.lowerThirdFrame(text)), viewSize: view)
        let onCaption = editor.previewElement(at: viewPoint(captionRect), viewSize: view)
        let onNothing = editor.previewElement(at: CGPoint(x: view.width / 2, y: view.height * 0.45), viewSize: view)
        guard onCamera == .panel(.camera), onText == .text(text.id), onCaption == .panel(.captions), onNothing == nil else {
            throw fail("preview clicks: camera \(String(describing: onCamera)), text \(String(describing: onText)), caption \(String(describing: onCaption)), nothing \(String(describing: onNothing))")
        }
        editor.previewClicked(at: viewPoint(cam), viewSize: view)
        guard editor.selection == .panel(.camera) else { throw fail("click on the camera") }
        editor.previewClicked(at: CGPoint(x: view.width / 2, y: view.height * 0.45), viewSize: view)
        guard editor.selection == nil, !editor.isPlaying else { throw fail("click beside ends the selection: \(String(describing: editor.selection))") }
        print("✓ preview clicks: camera bubble → camera settings, lower third → its settings, captions → caption style, a click beside ends the selection")
    }

    // MARK: Own audio as narration, captions from it

    private static func narrationTest(_ base: Project, dir: URL) async throws {
        let speech = dir.appendingPathComponent("speech.aiff")
        guard FileManager.default.fileExists(atPath: speech.path) else { print("– narration captions skipped (no speech file)"); return }
        let editor = await MainActor.run { EditorModel(project: project(base) { _ in }) }
        await MainActor.run { _ = editor.drop([speech], target: .narration, at: 0.5) }
        var clip: VoiceOverClip?
        for _ in 0..<100 {
            clip = await MainActor.run { editor.settings.voiceOvers.first }
            if clip != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard let clip, clip.file.hasPrefix("media/"), abs(clip.start - 0.5) < 0.01 else { throw fail("audio file as narration: \(String(describing: clip))") }
        guard #available(macOS 26.0, *) else { print("✓ own audio file as narration (captions skipped: macOS < 26)"); return }
        let p = project(base) { $0.voiceOvers = [clip]; $0.micMuted = true; $0.systemMuted = true }
        let (captions, _) = try await CaptionGenerator.generate(project: p, localeID: "de-DE", source: .narration) { _ in }
        guard let first = captions.first, first.start > 0.45, first.start < 1.3,
              captions.map(\.text).joined(separator: " ").lowercased().contains("hallo") else {
            throw fail("captions from the narration: \(captions.map { ($0.start, $0.text) })")
        }
        print(String(format: "✓ own audio file as narration (Voice-over lane), captions made from it start at %.2f s (clip at 0.50 s)", first.start))
    }
}
