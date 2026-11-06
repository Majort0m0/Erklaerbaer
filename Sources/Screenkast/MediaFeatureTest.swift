import Foundation
import AVFoundation
import CoreImage
import AppKit

/// Selftests for video overlays (picture in picture, synced second window), annotations inside
/// inserted clips, shapes, color grading, text designs, picture frames, audio ranges and clip
/// volumes, level matching, loudness on export, media drag and drop and the screenshot editor.
enum MediaFeatureTest {
    private static func fail(_ m: String) -> NSError {
        NSError(domain: "selftest", code: 60, userInfo: [NSLocalizedDescriptionKey: m])
    }

    static func run(base: Project, dir: URL) async throws {
        let clipURL = base.url.appendingPathComponent("media/selftest-clip.mov")
        if !FileManager.default.fileExists(atPath: clipURL.path) {
            try await SelfTest.writeSyntheticVideo(url: clipURL, width: 480, height: 270, fps: 30, duration: 1.0, audio: [(role: "system", freq: 880)])
        }
        try await overlayTest(base)
        try insertAnnotationTest(base)
        try styleTest(base)
        try await audioTest(base, dir: dir)
        try await editorTest(base)
        try await MainActor.run { try screenshotTest() }
        try await LayoutCaptionTest.run(base: base, dir: dir)
    }

    private static func project(_ base: Project, _ change: (inout EditSettings) -> Void) -> Project {
        var s = EditSettings()
        s.removeEcho = false
        s.zoomSegments = []
        change(&s)
        return Project(url: base.url, info: base.info, cursor: base.cursor, settings: s)
    }

    private static func ci(_ cg: CGImage) -> CIImage { CIImage(cgImage: cg) }

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

    private static func frame(_ media: MediaComposition, at t: Double) async throws -> CIImage {
        let gen = AVAssetImageGenerator(asset: media.asset)
        gen.videoComposition = media.videoComposition
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        return ci(try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image)
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

    // MARK: Video overlays

    private static func overlayTest(_ base: Project) async throws {
        let ctx = CIContext()
        let duration = base.info.duration
        var o = VideoOverlay(file: "media/selftest-clip.mov", name: "Clip", start: 1.0, duration: 0.8, fileDuration: 1.0)
        o.x = 0.72; o.y = 0.3; o.width = 0.3; o.frame = .none; o.shadow = false
        let p = project(base) { $0.videoOverlays = [o] }
        let plain = project(base) { _ in }
        let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30,
                                                segments: p.settings.keptSegments(duration: duration))
        let without = try await MediaBuilder.make(project: plain, renderer: FrameRenderer(project: plain), fps: 30,
                                                  segments: plain.settings.keptSegments(duration: duration))
        let out = FrameRenderer(project: p).outputSize
        let r = FrameRenderer.videoOverlayFrame(o, out: out).insetBy(dx: 6, dy: 6)
        let during = meanDiff(try await frame(media, at: 1.4), try await frame(without, at: 1.4), in: r, context: ctx)
        let after = meanDiff(try await frame(media, at: 2.4), try await frame(without, at: 2.4), in: r, context: ctx)
        let audio = try await mixed(media, p.settings, role: "overlay")
        let loud = rms(audio, 1.1...1.7), quiet = rms(audio, 2.0...2.8)
        var halfSettings = p.settings
        halfSettings.videoOverlays[0].volume = 0.5
        let half = rms(try await mixed(media, halfSettings, role: "overlay"), 1.1...1.7)
        guard during > 8, after < 0.5, loud > 0.05, quiet < 0.005, abs(half / loud - 0.5) < 0.08 else {
            throw fail(String(format: "video overlay: picture %.1f / after %.2f, sound %.3f / %.4f, half volume %.2f", during, after, loud, quiet, half / max(1e-6, loud)))
        }

        // Synced overlay (second recorded window): follows the recording, visible only in its range.
        guard let cam = base.info.cameraFile else { throw fail("no camera file for the synced overlay") }
        var synced = VideoOverlay(file: cam, name: "Fenster", start: 0.5, duration: 1.0, fileDuration: duration, synced: true)
        synced.x = 0.3; synced.y = 0.35; synced.width = 0.3; synced.aspect = 4.0 / 3.0; synced.frame = .none; synced.shadow = false
        let ps = project(base) { $0.videoOverlays = [synced]; $0.cameraVisible = false }
        let pn = project(base) { $0.cameraVisible = false }
        let ms = try await MediaBuilder.make(project: ps, renderer: FrameRenderer(project: ps), fps: 30, segments: ps.settings.keptSegments(duration: duration))
        let mn = try await MediaBuilder.make(project: pn, renderer: FrameRenderer(project: pn), fps: 30, segments: pn.settings.keptSegments(duration: duration))
        let sr = FrameRenderer.videoOverlayFrame(synced, out: out).insetBy(dx: 6, dy: 6)
        let sDuring = meanDiff(try await frame(ms, at: 1.0), try await frame(mn, at: 1.0), in: sr, context: ctx)
        let sAfter = meanDiff(try await frame(ms, at: 2.2), try await frame(mn, at: 2.2), in: sr, context: ctx)
        guard sDuring > 8, sAfter < 0.5 else { throw fail(String(format: "synced overlay: %.1f during, %.2f after", sDuring, sAfter)) }
        print(String(format: "✓ video overlay: picture in its range (diff %.0f, after %.1f), own sound (%.2f, outside %.3f, volume 50 %% → %.0f %%); synced window overlay %.0f / %.1f",
                     during, after, loud, quiet, half / loud * 100, sDuring, sAfter))
    }

    // MARK: Annotations inside an inserted clip

    private static func insertAnnotationTest(_ base: Project) throws {
        let ctx = CIContext()
        let clip = InsertClip(file: "media/selftest-clip.mov", name: "Clip", at: 2.0, duration: 1.0, fileDuration: 1.0)
        let settings = project(base) { $0.inserts = [clip] }.settings
        let map = settings.timeMap(duration: base.info.duration)
        let t0 = map.timeline(clip.sourceRange.lowerBound)
        // Spotlight from 0.2 s to 0.8 s into the inserted clip.
        let spot = Annotation(kind: .spotlight, start: map.source(t0 + 0.2), end: map.source(t0 + 0.8), x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let onRecording = Annotation(kind: .spotlight, start: 0.5, end: 3.5, x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let frameImg = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 480, height: 270))
        func render(_ a: [Annotation], at T: Double) -> CIImage {
            let p = project(base) { $0.inserts = [clip]; $0.annotations = a; $0.background = .color(red: 0, green: 0, blue: 1) }
            return FrameRenderer(project: p).render(source: frameImg, camera: nil, time: map.source(T), plain: true)
        }
        let r = FrameRenderer(project: project(base) { $0.inserts = [clip] })
        _ = r.render(source: frameImg, camera: nil, time: map.source(t0 + 0.5), plain: true)   // learns the clip's size
        let corner = r.outputPoint(CGPoint(x: 0.1, y: 0.1), at: map.source(t0 + 0.5))
        let out = r.outputSize
        let probe = CGRect(x: corner.x - 6, y: out.height - corner.y - 6, width: 12, height: 12)
        let plainImg = render([], at: t0 + 0.5)
        let dimmed = average(render([spot], at: t0 + 0.5), in: probe, context: ctx).g / max(0.001, average(plainImg, in: probe, context: ctx).g)
        let fading = average(render([spot], at: t0 + 0.25), in: probe, context: ctx).g / max(0.001, average(plainImg, in: probe, context: ctx).g)
        let foreign = average(render([onRecording], at: t0 + 0.5), in: probe, context: ctx).g / max(0.001, average(plainImg, in: probe, context: ctx).g)
        guard dimmed < 0.6, fading > dimmed + 0.05, fading < 0.99, foreign > 0.99 else {
            throw fail(String(format: "annotation in an inserted clip: dimmed %.2f, fading %.2f, recording's annotation %.2f", dimmed, fading, foreign))
        }
        print(String(format: "✓ annotations in an inserted clip: spotlight dims to %.0f %% (fades in over 0.2 s of the clip), annotations of the recording stay off it",
                     dimmed * 100))
    }

    // MARK: Shapes, color grading, text designs, picture frames

    private static func styleTest(_ base: Project) throws {
        let ctx = CIContext()
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: base.info.pixelWidth, height: base.info.pixelHeight))
        let plain = FrameRenderer(project: project(base) { _ in })
        let out = plain.outputSize
        func at(_ x: Double, _ y: Double, _ size: CGFloat = 8) -> CGRect {
            let q = plain.outputPoint(CGPoint(x: x, y: y), at: 1)
            return CGRect(x: q.x - size / 2, y: out.height - q.y - size / 2, width: size, height: size)
        }
        // Spotlight shapes: a point inside the rectangle but outside the ellipse.
        func spot(_ shape: AnnotationShape) -> Double {
            let a = Annotation(kind: .spotlight, start: 0, end: 3, x: 0.3, y: 0.3, width: 0.4, height: 0.4, shape: shape)
            let img = FrameRenderer(project: project(base) { $0.annotations = [a] }).render(source: source, camera: nil, time: 1)
            return average(img, in: at(0.345, 0.345), context: ctx).g / max(0.001, average(plain.render(source: source, camera: nil, time: 1), in: at(0.345, 0.345), context: ctx).g)
        }
        let rect = spot(.rectangle), ellipse = spot(.ellipse)
        guard rect > 0.97, ellipse < 0.7 else { throw fail(String(format: "spotlight shapes: rectangle %.2f, ellipse %.2f at the corner", rect, ellipse)) }

        // Color grading of the screen.
        func graded(_ change: (inout ColorGrade) -> Void, source: CIImage) -> (r: Double, g: Double, b: Double) {
            let img = FrameRenderer(project: project(base) { change(&$0.color) }).render(source: source, camera: nil, time: 1)
            return average(img, in: at(0.5, 0.5, 40), context: ctx)
        }
        let neutral = graded({ _ in }, source: source)
        let warm = graded({ $0.temperature = 0.8; $0.applyToScreen = true }, source: source)
        let bright = graded({ $0.exposure = 1; $0.applyToScreen = true }, source: source)
        let red = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.2)).cropped(to: source.extent)
        let gray = graded({ $0.saturation = 0; $0.applyToScreen = true }, source: red)
        let off = graded({ $0.temperature = 0.8 }, source: source)   // screen not selected
        guard warm.r > warm.b + 0.04, bright.g > neutral.g + 0.1, abs(gray.r - gray.g) < 0.03, abs(off.r - neutral.r) < 0.005 else {
            throw fail("color grading: neutral \(neutral), warm \(warm), bright \(bright), gray \(gray), off \(off)")
        }

        // Text design (yellow label) and a picture in the box.
        var text = TextOverlay(kind: .lowerThird, start: 0, end: 3, title: "Titel", subtitle: "Untertitel")
        text.design = TextDesign.presets.first { $0.name == "Etikett" }
        let tp = project(base) { $0.texts = [text] }
        let tr = FrameRenderer(project: tp)
        let box = tr.lowerThirdFrame(text)
        let img = tr.render(source: source, camera: nil, time: 1.5)
        let edge = average(img, in: CGRect(x: box.minX + 3, y: box.minY + 3, width: 6, height: 6), context: ctx)
        var withPicture = text
        withPicture.image = "media/selftest-logo.png"
        let wide = FrameRenderer(project: project(base) { $0.texts = [withPicture] }).lowerThirdFrame(withPicture)
        guard edge.r > 0.8, edge.b < 0.3, wide.width > box.width + 20 else {
            throw fail("text design: box colour \(edge), width \(box.width) → with picture \(wide.width)")
        }

        // Picture frame: a circle leaves the corners free.
        let overlay = ImageOverlay(file: "media/selftest-logo.png", start: 0, end: 3, x: 0.5, y: 0.5, width: 0.3, frame: .circle, shadow: false)
        let pr = FrameRenderer(project: project(base) { $0.images = [overlay] })
        guard let pic = pr.imageFrame(overlay, out: out) else { throw fail("picture frame") }
        let framed = pr.render(source: source, camera: nil, time: 1.5)
        let center = average(framed, in: CGRect(x: pic.midX - 4, y: pic.midY - 4, width: 8, height: 8), context: ctx)
        let cornerDiff = meanDiff(framed, plain.render(source: source, camera: nil, time: 1.5),
                                  in: CGRect(x: pic.minX + 2, y: pic.minY + 2, width: 5, height: 5), context: ctx)
        guard center.g > 0.8, cornerDiff < 1 else { throw fail(String(format: "circle frame: centre %.2f, corner diff %.2f", center.g, cornerDiff)) }
        print(String(format: "✓ spotlight shapes (rectangle %.2f / ellipse %.2f at the corner), color grading (warm R−B %+.2f, +1 EV, black and white, screen only when chosen), text design + picture in the box, round picture frame",
                     rect, ellipse, warm.r - warm.b))
    }

    // MARK: Audio ranges, clip volume, level matching, loudness on export

    private static func audioTest(_ base: Project, dir: URL) async throws {
        let duration = base.info.duration
        var range = AudioMute(lane: .mic, start: 1.0, end: 2.0)
        range.gain = 0.5
        let p = project(base) { $0.audioMutes = [range] }
        let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30, segments: p.settings.keptSegments(duration: duration))
        let mic = try await mixed(media, p.settings, role: "mic")
        let ratio = rms(mic, 1.2...1.8) / max(1e-6, rms(mic, 0.3...0.8))
        guard abs(ratio - 0.5) < 0.08 else { throw fail(String(format: "range at 50 %%: level ratio %.2f", ratio)) }

        // Level matching: speech in front, system sound and music below, nothing above 100 %.
        let v = AudioMastering.suggestedVolumes(.init(mic: -20, micHasSpeech: true, system: -18, voiceOver: nil, music: -14))
        guard let m = v.mic, let s = v.system, let mu = v.music, m > 0.99, s < m, mu < s, abs(v.quietBy - 4) < 0.1 else {
            throw fail("level matching: \(v)")
        }
        let noSpeech = AudioMastering.suggestedVolumes(.init(mic: -50, micHasSpeech: false, system: -20, voiceOver: nil, music: nil))
        guard noSpeech.mic == nil, noSpeech.system != nil else { throw fail("level matching without speech: \(noSpeech)") }

        // Loudness of the finished video.
        let url = dir.appendingPathComponent("master.mp4")
        try? FileManager.default.removeItem(at: url)
        let plain = project(base) { _ in }
        let exportMedia = try await MediaBuilder.make(project: plain, renderer: FrameRenderer(project: plain), fps: 30,
                                                      segments: plain.settings.keptSegments(duration: duration))
        guard let session = AVAssetExportSession(asset: exportMedia.asset, presetName: AVAssetExportPreset1280x720) else { throw fail("export") }
        session.videoComposition = exportMedia.videoComposition
        session.audioMix = exportMedia.audioMix(settings: plain.settings)
        try await session.export(to: url, as: .mp4)
        guard let result = try await AudioMastering.normalize(file: url, target: -16) else { throw fail("loudness: nothing measured") }
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .audio).first!
        let channels = try await AudioMastering.readStereo(track: track, asset: asset, duration: try await asset.load(.duration).seconds)
        let measured = AudioMastering.loudness(channels: channels)
        let videoTracks = try await asset.loadTracks(withMediaType: .video).count
        let newDuration = try await asset.load(.duration).seconds
        guard abs(measured - -16) < 1.2, videoTracks == 1, abs(newDuration - exportMedia.totalDuration) < 0.1 else {
            throw fail(String(format: "loudness: %.1f → %.1f LUFS (measured %.1f), video tracks %d, %.2f s", result.before, result.after, measured, videoTracks, newDuration))
        }
        print(String(format: "✓ audio: range at 50 %% (level %.2f), level matching (speech 100 %%, system %.0f %%, music %.0f %%), export loudness %.1f → %.1f LUFS with the video copied",
                     ratio, s * 100, mu * 100, result.before, measured))
    }

    // MARK: Editor: drop, split, reveal, ranges inside clips

    @MainActor
    private static func editorTest(_ base: Project) async throws {
        let clip = InsertClip(file: "media/selftest-clip.mov", name: "Clip", at: 2.0, duration: 1.0, fileDuration: 1.0)
        let p = project(base) { $0.inserts = [clip] }
        let editor = EditorModel(project: p)
        let logo = base.url.appendingPathComponent("media/selftest-logo.png")
        let movie = base.url.appendingPathComponent("media/selftest-clip.mov")
        editor.drop([logo], target: .overlay, at: 0.5)
        guard editor.settings.images.count == 1, abs(editor.settings.images[0].start - 0.5) < 0.01,
              abs(editor.display(editor.settings.images[0].end) - editor.display(0.5) - 4) < 0.01 else {
            throw fail("drop picture: \(editor.settings.images)")
        }
        editor.drop([movie], target: .overlay, at: 0.3)
        editor.drop([movie], target: .mainTrack, at: 1.0)
        for _ in 0..<100 where editor.settings.videoOverlays.isEmpty || editor.settings.inserts.count < 2 {
            try await Task.sleep(for: .milliseconds(30))
        }
        guard let overlay = editor.settings.videoOverlays.first, abs(overlay.aspect - 16.0 / 9.0) < 0.01, editor.settings.inserts.count == 2 else {
            throw fail("drop movie: overlays \(editor.settings.videoOverlays.count), inserts \(editor.settings.inserts.count)")
        }
        // S splits the selected overlay at the playhead; the second part continues in the file.
        editor.selection = .videoOverlay(overlay.id)
        editor.seek(to: editor.sourceTime(editor.display(overlay.start) + 0.4))
        editor.splitAtPlayhead()
        let parts = editor.settings.videoOverlays.sorted { $0.start < $1.start }
        guard parts.count == 2, abs(parts[0].duration - 0.4) < 0.01, abs(parts[1].fileOffset - 0.4) < 0.01 else {
            throw fail("split overlay: \(parts.map { ($0.start, $0.duration, $0.fileOffset) })")
        }
        // A selected lane is cut at the playhead into a range with its own volume.
        editor.selection = .audioLane(.mic)
        editor.seek(to: 0.8)
        editor.splitAtPlayhead()
        guard let r = editor.settings.audioMutes.first, abs(r.start - 0.8) < 0.01, r.level == 1 else {
            throw fail("lane cut: \(editor.settings.audioMutes)")
        }
        // Selecting an item moves the playhead into it.
        editor.settings.annotations = [Annotation(kind: .frame, start: 3.2, end: 3.8)]
        editor.selection = nil
        editor.seek(to: 0.2)
        editor.selection = .annotation(editor.settings.annotations[0].id)
        guard editor.currentTime > 3.2, editor.currentTime < 3.8 else { throw fail("reveal selection: playhead \(editor.currentTime)") }
        // Inside an inserted clip, lengths are timeline seconds.
        let inside = clip.sourceRange.lowerBound + FreezeFrame.span * 0.3
        editor.updateAnnotation(id: editor.settings.annotations[0].id) { $0.start = inside; $0.end = inside }
        let a = editor.settings.annotations[0]
        guard abs(editor.display(a.end) - editor.display(a.start) - 0.2) < 0.01 else {
            throw fail("range inside a clip: \(editor.display(a.end) - editor.display(a.start)) s")
        }
        print("✓ editor: dropping pictures and videos (overlay or inserted), S splits an overlay and cuts a lane, selecting moves the playhead into the item, ranges inside an inserted clip")
    }

    // MARK: Screenshot editor

    @MainActor
    private static func screenshotTest() throws {
        // Checkerboard 400×300 (blur changes it visibly).
        let w = 400, h = 300
        let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in stride(from: 0, to: h, by: 10) {
            for x in stride(from: 0, to: w, by: 10) {
                cg.setFillColor((x / 10 + y / 10) % 2 == 0 ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1))
                cg.fill(CGRect(x: x, y: y, width: 10, height: 10))
            }
        }
        let doc = ShotDocument(image: cg.makeImage()!, name: "Test")
        doc.styled = false
        doc.items = [
            ShotItem(kind: .arrow, a: CGPoint(x: 20, y: 20), b: CGPoint(x: 120, y: 80), color: .red, width: 1),
            ShotItem(kind: .rectangle, a: CGPoint(x: 200, y: 40), b: CGPoint(x: 300, y: 120), color: .blue, width: 1),
            ShotItem(kind: .text, a: CGPoint(x: 40, y: 200), b: CGPoint(x: 40, y: 200), color: .yellow, width: 1, text: "Hallo"),
            ShotItem(kind: .number, a: CGPoint(x: 350, y: 250), b: CGPoint(x: 350, y: 250), color: .red, width: 1, number: 1),
            ShotItem(kind: .blur, a: CGPoint(x: 200, y: 180), b: CGPoint(x: 300, y: 280), color: .red, width: 1),
        ]
        guard let flat = doc.render(), flat.width == w, flat.height == h else { throw fail("screenshot render") }
        let ctx = CIContext()
        let original = CIImage(cgImage: doc.image), result = CIImage(cgImage: flat)
        // CI coordinates: origin bottom-left.
        func rect(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat = 8) -> CGRect { CGRect(x: x - s / 2, y: CGFloat(h) - y - s / 2, width: s, height: s) }
        let blurred = meanDiff(result, original, in: rect(250, 230, 40), context: ctx)
        let arrowRed = average(result, in: rect(70, 50, 4), context: ctx)
        let untouched = meanDiff(result, original, in: rect(150, 260, 20), context: ctx)
        guard blurred > 40, arrowRed.r > 0.8, arrowRed.g < 0.4, untouched < 0.5 else {
            throw fail(String(format: "screenshot: blur %.1f, arrow %@, untouched %.2f", blurred, "\(arrowRed)", untouched))
        }
        doc.styled = true
        guard let styled = doc.render(), styled.width > w + 20, styled.height > h + 20 else { throw fail("screenshot frame") }
        doc.crop = CGRect(x: 50, y: 50, width: 200, height: 100)
        doc.applyCrop()
        guard doc.image.width == 200, doc.image.height == 100, abs(doc.items[0].a.x - -30) < 0.01 else { throw fail("screenshot crop") }
        doc.undo()
        guard doc.image.width == w, doc.items.count == 5 else { throw fail("screenshot undo") }
        print("✓ screenshot editor: arrow, frame, text, number and blur drawn; background frame; crop and undo")
    }
}
