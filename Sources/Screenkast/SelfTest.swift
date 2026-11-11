import Foundation
import AVFoundation
import CoreImage
import AppKit

/// `Screenkast --selftest <dir>`: builds a synthetic recording (video + cursor track),
/// renders preview frames and runs the real export path. Needs no screen-recording permission.
enum SelfTest {
    static func run(outputDirectory: URL) -> Int32 {
        // The tests open and close parts of the inspector without touching the user's settings.
        MainActor.assumeIsolated { InspectorFolds.shared.keepInMemory(open: Set(InspectorFold.allCases)) }
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            do {
                try await runAsync(outputDirectory)
            } catch {
                print("SELFTEST FAILED: \(error)")
                code = 1
            }
            sem.signal()
        }
        while sem.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard code == 0 else { return code }
        // Directly on the main thread (not inside a main-queue job), so the editor's async
        // composition build can run while the test pumps events.
        do {
            let project = try Project.load(from: outputDirectory.appendingPathComponent("Test.\(Project.fileExtension)"))
            try MainActor.assumeIsolated { try UISelfTest.timeline(project: project) }
            try MainActor.assumeIsolated { try UISelfTest.previewHandles(project: project) }
        } catch {
            print("SELFTEST FAILED: \(error)")
            return 1
        }
        print("SELFTEST OK")
        return code
    }

    private static func runAsync(_ dir: URL) async throws {
        try await MainActor.run { try UISelfTest.run() }
        try await CrashSelfTest.run(dir: dir)
        try EchoSelfTest.run()
        try pauseGateTest()
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        let projectURL = dir.appendingPathComponent("Test.\(Project.fileExtension)")
        try fm.createDirectory(at: projectURL.appendingPathComponent("cursors"), withIntermediateDirectories: true)

        // 1. Synthetic "screen" video: 1440×900 px (720×450 pt @2x), 4 s, 30 fps.
        let w = 1440, h = 900, fps = 30, duration = 4.0
        let videoURL = projectURL.appendingPathComponent("screen.mov")
        // Audio roles deliberately in this order: system = 440 Hz, mic = 660 Hz.
        try await writeSyntheticVideo(url: videoURL, width: w, height: h, fps: fps, duration: duration,
                                      audio: [("system", 440), ("mic", 660)])
        try await writeSyntheticCamera(url: projectURL.appendingPathComponent("camera.mov"), duration: duration)
        print("✓ synthetic screen (+2 audio tracks) and camera video written")

        // 2. Cursor track: circle path, clicks at 1.0 s and 2.6 s.
        var track = CursorTrack()
        var t = 0.0
        while t <= duration {
            let a = t / duration * 2 * .pi
            track.samples.append(CursorSample(t: t, x: 0.5 + 0.3 * cos(a), y: 0.5 + 0.3 * sin(a), c: 0))
            t += 1.0 / 120
        }
        track.clicks = [ClickEvent(t: 1.0, x: 0.5 + 0.3 * cos(0.5 * .pi), y: 0.5 + 0.3 * sin(0.5 * .pi)),
                        ClickEvent(t: 2.6, x: 0.5 + 0.3 * cos(1.3 * .pi), y: 0.5 + 0.3 * sin(1.3 * .pi))]
        // Use the real arrow cursor as cursor image 0.
        let arrow = NSCursor.arrow
        var rect = CGRect(origin: .zero, size: CGSize(width: arrow.image.size.width * 2, height: arrow.image.size.height * 2))
        if let cg = arrow.image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try png.write(to: projectURL.appendingPathComponent("cursors/cursor-0.png"))
            track.images = [CursorImageInfo(file: "cursors/cursor-0.png", width: arrow.image.size.width,
                                            height: arrow.image.size.height, hotX: arrow.hotSpot.x, hotY: arrow.hotSpot.y)]
        }

        let info = RecordingInfo(pixelWidth: w, pixelHeight: h, pointPixelScale: 2, duration: duration,
                                 createdAt: Date(), sourceName: "Selbsttest", hasMicrophone: true,
                                 cameraFile: "camera.mov", audioTracks: ["system", "mic"])
        var settings = EditSettings()
        settings.zoomSegments = AutoZoom.segments(for: track.clicks, duration: duration, scale: settings.defaultZoom)
        let project = Project(url: projectURL, info: info, cursor: track, settings: settings)
        try project.saveAll()
        let reloaded = try Project.load(from: projectURL)
        guard reloaded.settings == settings, reloaded.cursor.samples.count == track.samples.count else {
            throw NSError(domain: "selftest", code: 1, userInfo: [NSLocalizedDescriptionKey: "project round-trip mismatch"])
        }
        print("✓ project saved & reloaded, zoom segments: \(settings.zoomSegments.map { String(format: "%.2f–%.2f", $0.start, $0.end) })")

        // Older edit.json without the new keys must still load and keep its values.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        for key in ["cameraSize", "cameraShape", "micVolume", "systemMuted"] { json.removeValue(forKey: key) }
        json["padding"] = 0.11
        let legacy = try JSONDecoder().decode(EditSettings.self, from: JSONSerialization.data(withJSONObject: json))
        guard legacy.padding == 0.11, legacy.cameraSize == EditSettings().cameraSize,
              legacy.zoomSegments == settings.zoomSegments else {
            throw NSError(domain: "selftest", code: 4, userInfo: [NSLocalizedDescriptionKey: "legacy settings decoding"])
        }
        print("✓ older edit.json (without camera/audio keys) decodes with defaults")

        // 3. Render single frames directly.
        let renderer = FrameRenderer(project: reloaded)
        let asset = AVURLAsset(url: videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let ctx = CIContext()
        for time in [0.2, 1.3, 2.7] {
            let (cg, _) = try await gen.image(at: CMTime(seconds: time, preferredTimescale: 600))
            let out = renderer.render(source: CIImage(cgImage: cg), time: time)
            let size = renderer.outputSize
            guard let rendered = ctx.createCGImage(out, from: CGRect(origin: .zero, size: size)) else {
                throw NSError(domain: "selftest", code: 2, userInfo: [NSLocalizedDescriptionKey: "render failed"])
            }
            let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])!
            try png.write(to: dir.appendingPathComponent(String(format: "frame-%.1f.png", time)))
            print("✓ rendered frame at \(time)s (zoom \(String(format: "%.2f", AutoZoom.zoom(at: time, segments: settings.zoomSegments)))) → \(rendered.width)×\(rendered.height)")
        }

        // 4. Full pipeline: composition with camera track, custom compositor, audio mix.
        let media = try await MediaBuilder.make(project: reloaded, renderer: renderer, fps: 60)
        let roles = media.audioTracks.map(\.role)
        guard roles == ["system", "mic"] else {
            throw NSError(domain: "selftest", code: 5, userInfo: [NSLocalizedDescriptionKey: "audio roles \(roles)"])
        }
        print("✓ audio roles from track metadata: \(roles)")
        // Every composition track must actually contain media (regression: released source assets).
        for track in media.asset.tracks {
            let filled = try await track.load(.segments).filter { !$0.isEmpty }.count
            guard filled > 0 else {
                throw NSError(domain: "selftest", code: 9, userInfo: [NSLocalizedDescriptionKey: "empty composition track \(track.trackID) (\(track.mediaType.rawValue))"])
            }
        }
        guard media.asset.tracks(withMediaType: .video).count == 2 else {
            throw NSError(domain: "selftest", code: 9, userInfo: [NSLocalizedDescriptionKey: "camera track missing"])
        }
        print("✓ all composition tracks (screen, camera, audio) contain media")
        let cgen = AVAssetImageGenerator(asset: media.asset)
        cgen.videoComposition = media.videoComposition
        cgen.requestedTimeToleranceBefore = .zero
        cgen.requestedTimeToleranceAfter = .zero
        for time in [0.2, 2.0] {
            let (cg, _) = try await cgen.image(at: CMTime(seconds: time, preferredTimescale: 600))
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
            try png.write(to: dir.appendingPathComponent(String(format: "composited-%.1f.png", time)))
            print("✓ compositor frame at \(time)s → \(cg.width)×\(cg.height)")
        }

        // 5. Export with trim and mic at 50 %.
        var exportSettings = reloaded.settings
        exportSettings.micVolume = 0.5
        guard let session = AVAssetExportSession(asset: media.asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "selftest", code: 3, userInfo: [NSLocalizedDescriptionKey: "no export session"])
        }
        session.videoComposition = media.videoComposition
        session.audioMix = media.audioMix(settings: exportSettings)
        session.timeRange = CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600),
                                        end: CMTime(seconds: 3.5, preferredTimescale: 600))
        let exportURL = dir.appendingPathComponent("export.mp4")
        let started = Date()
        try await session.export(to: exportURL, as: .mp4)
        let outAsset = AVURLAsset(url: exportURL)
        let outDuration = try await outAsset.load(.duration).seconds
        let track0 = try await outAsset.loadTracks(withMediaType: .video).first
        let natural = try await track0?.load(.naturalSize) ?? .zero
        let outAudio = try await outAsset.loadTracks(withMediaType: .audio).count
        print(String(format: "✓ exported %.2fs video %d×%d, %d audio track(s) in %.1fs → %@", outDuration, Int(natural.width),
                     Int(natural.height), outAudio, Date().timeIntervalSince(started), exportURL.path))
        try await cutTest(project: reloaded, renderer: renderer, dir: dir)
        try await clickSoundTest(project: reloaded, renderer: renderer)
        try await maskTest(project: reloaded, dir: dir)
        try await motionBlurTest(project: reloaded, dir: dir)
        var free = EditSettings()
        free.cameraX = 0.25
        free.cameraY = 0.3
        let r = FrameRenderer.cameraRect(settings: free, out: CGSize(width: 1920, height: 1080), cameraAspect: 16 / 9).rect
        guard abs(r.midX - 480) < 0.5, abs(r.midY - 756) < 0.5 else {
            throw NSError(domain: "selftest", code: 12, userInfo: [NSLocalizedDescriptionKey: "free camera position \(r)"])
        }
        free.cameraX = 0.99   // clamped inside the frame
        let clamped = FrameRenderer.cameraRect(settings: free, out: CGSize(width: 1920, height: 1080), cameraAspect: 16 / 9).rect
        guard clamped.maxX <= 1920.001 else {
            throw NSError(domain: "selftest", code: 12, userInfo: [NSLocalizedDescriptionKey: "camera not clamped \(clamped)"])
        }
        print("✓ free camera position and clamping")
        try await captionTest(project: reloaded, dir: dir)
        try await shortcutTest(project: reloaded, dir: dir)
        try await EditorFeatureTest.run(base: reloaded, dir: dir)
    }

    /// - Parameter killAfter: crash simulation: the process kills itself (SIGKILL) once this
    ///   much media is written, without finishing the file (used with a crash-safe writer).
    static func writeSyntheticVideo(url: URL, width: Int, height: Int, fps: Int, duration: Double,
                                    audio: [(role: String, freq: Double)] = [],
                                    crashSafe: Bool = false, killAfter: Double? = nil) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        if crashSafe { RecordingRecovery.prepare(writer) }
        var videoSettings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height]
        if crashSafe {
            // Like the recorder: a key frame every second, so fragments can end every second.
            videoSettings[AVVideoCompressionPropertiesKey] = RecordingRecovery.keyFrameProperties(fps: fps)
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        input.expectsMediaDataInRealTime = !audio.isEmpty
        writer.add(input)
        var audioInputs: [(AVAssetWriterInput, Double)] = []
        for a in audio {
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
            ])
            aIn.metadata = AudioRole.metadata(a.role)
            aIn.expectsMediaDataInRealTime = true   // no interleaving stalls (sparse video, continuous audio)
            writer.add(aIn)
            audioInputs.append((aIn, a.freq))
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = Int(duration * Double(fps))
        let samplesPerFrame = 48_000 / fps
        for i in 0..<frames {
            if let killAfter, Double(i) / Double(fps) >= killAfter {
                try await Task.sleep(for: .milliseconds(300))   // let the writer flush its last fragment
                kill(getpid(), SIGKILL)
            }
            for (aIn, freq) in audioInputs {
                var waited = 0
                while !aIn.isReadyForMoreMediaData && waited < 1000 { try await Task.sleep(for: .milliseconds(2)); waited += 1 }
                if let sb = pcmBuffer(freq: freq, startFrame: i * samplesPerFrame, frames: samplesPerFrame, sampleRate: 48_000) {
                    aIn.append(sb)
                }
            }
            // Like ScreenCaptureKit on a static screen: only sparse frames between 1 s and 3 s.
            if i > fps && i < 3 * fps && i % 15 != 0 { continue }
            var waited = 0
            while !input.isReadyForMoreMediaData && waited < 1000 { try await Task.sleep(for: .milliseconds(2)); waited += 1 }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            drawFakeDesktop(ctx, width: width, height: height, frame: i)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        audioInputs.forEach { $0.0.markAsFinished() }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? RecorderError.writerFailed("synthetic video") }
    }

    /// Cuts: kept segments, composition time → source time mapping, export length.
    private static func cutTest(project: Project, renderer: FrameRenderer, dir: URL) async throws {
        func fail(_ m: String) -> NSError { NSError(domain: "selftest", code: 7, userInfo: [NSLocalizedDescriptionKey: "Cuts: \(m)"]) }
        var settings = project.settings
        settings.trimStart = 0.5
        settings.trimEnd = 3.5
        settings.cuts = [CutRange(start: 1.0, end: 2.0), CutRange(start: 1.5, end: 1.8)]
        let kept = settings.keptSegments(duration: 4)
        guard kept == [0.5...1.0, 2.0...3.5] else { throw fail("kept \(kept)") }

        let cutMedia = try await MediaBuilder.make(project: project, renderer: renderer, fps: 60, segments: kept)
        let fullMedia = try await MediaBuilder.make(project: project, renderer: renderer, fps: 60)
        let cutDuration = try await cutMedia.asset.load(.duration).seconds
        guard abs(cutDuration - 2.0) < 0.02 else { throw fail("duration \(cutDuration)") }

        func frame(_ media: MediaComposition, _ t: Double) async throws -> CGImage {
            let gen = AVAssetImageGenerator(asset: media.asset)
            gen.videoComposition = media.videoComposition
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            return try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        }
        func meanDiff(_ a: CGImage, _ b: CGImage) -> Double {
            func pixels(_ img: CGImage) -> [UInt8] {
                var buf = [UInt8](repeating: 0, count: 192 * 108 * 4)
                let ctx = CGContext(data: &buf, width: 192, height: 108, bitsPerComponent: 8, bytesPerRow: 192 * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: 192, height: 108))
                return buf
            }
            let pa = pixels(a), pb = pixels(b)
            return zip(pa, pb).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(pa.count)
        }
        // Composition 0.75 s lies in the second segment → source 2.0 + 0.25 = 2.25 s.
        let same = meanDiff(try await frame(cutMedia, 0.75), try await frame(fullMedia, 2.25))
        let other = meanDiff(try await frame(cutMedia, 0.75), try await frame(fullMedia, 0.75))
        print(String(format: "✓ cuts: kept %@, length %.2fs, frame match %.2f (vs. unmapped %.2f)",
                     kept.map { String(format: "%.1f–%.1f", $0.lowerBound, $0.upperBound) }.joined(separator: ", "),
                     cutDuration, same, other))
        guard same < 1.0, other > same * 3 else { throw fail("time mapping (same \(same), other \(other))") }

        guard let session = AVAssetExportSession(asset: cutMedia.asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw fail("export session")
        }
        session.videoComposition = cutMedia.videoComposition
        session.audioMix = cutMedia.audioMix(settings: settings)
        let url = dir.appendingPathComponent("export-cuts.mp4")
        try await session.export(to: url, as: .mp4)
        let exported = try await AVURLAsset(url: url).load(.duration).seconds
        guard abs(exported - 2.0) < 0.05 else { throw fail("exported length \(exported)") }
        print(String(format: "✓ export with cuts: %.2fs", exported))
    }

    /// Click sounds land at the click times (source time, and mapped through cuts).
    private static func clickSoundTest(project: Project, renderer: FrameRenderer) async throws {
        func fail(_ m: String) -> NSError { NSError(domain: "selftest", code: 8, userInfo: [NSLocalizedDescriptionKey: "Clicks: \(m)"]) }
        let saved = project.settings
        defer { project.settings = saved }
        project.settings.clickSound = true
        func clickTimes(_ media: MediaComposition) async throws -> [Double] {
            guard let track = media.audioTracks.first(where: { $0.role == "clicks" })?.track else { throw fail("no click track") }
            let segments = try await track.load(.segments)
            return segments.filter { !$0.isEmpty }.map { ($0.timeMapping.target.start.seconds * 1000).rounded() / 1000 }
        }
        let full = try await clickTimes(MediaBuilder.make(project: project, renderer: renderer, fps: 60))
        guard full == [1.0, 2.6] else { throw fail("full \(full)") }
        let cut = try await clickTimes(MediaBuilder.make(project: project, renderer: renderer, fps: 60,
                                                         segments: [0.5...1.0, 2.0...3.5]))
        guard cut == [1.1] else { throw fail("with cuts \(cut)") }
        print("✓ click sounds at \(full)s; with cuts at \(cut)s")
    }

    /// Masks change pixels only inside their rectangle; UI mapping round-trips under zoom.
    private static func maskTest(project: Project, dir: URL) async throws {
        func fail(_ m: String) -> NSError { NSError(domain: "selftest", code: 10, userInfo: [NSLocalizedDescriptionKey: "Masks: \(m)"]) }
        let saved = project.settings
        defer { project.settings = saved }
        let plain = FrameRenderer(project: project)
        project.settings.masks = [BlurMask(start: 0, end: 4, x: 0.3, y: 0.12, width: 0.5, height: 0.3)]
        let masked = FrameRenderer(project: project)

        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: project.videoURL))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let src = CIImage(cgImage: try await gen.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image)
        let ctx = CIContext()
        let size = masked.outputSize
        func pixels(_ r: FrameRenderer) -> [UInt8] {
            let cg = ctx.createCGImage(r.render(source: src, time: 0.2), from: CGRect(origin: .zero, size: size))!
            var buf = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
            let c = CGContext(data: &buf, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                              bytesPerRow: Int(size.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(cg, in: CGRect(origin: .zero, size: size))
            if r === masked {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("mask-0.2.png"))
            }
            return buf
        }
        let a = pixels(plain), b = pixels(masked)
        // Mask rectangle in output pixels (top-left origin), shrunk by 3 px against edge resampling.
        let p0 = masked.outputPoint(CGPoint(x: 0.3, y: 0.12), at: 0.2)
        let p1 = masked.outputPoint(CGPoint(x: 0.8, y: 0.42), at: 0.2)
        let inner = CGRect(x: p0.x, y: p0.y, width: p1.x - p0.x, height: p1.y - p0.y).insetBy(dx: 3, dy: 3)
        let outer = inner.insetBy(dx: -8, dy: -8)
        var inDiff = 0.0, inCount = 0.0, outDiff = 0.0, outCount = 0.0
        let W = Int(size.width)
        for y in stride(from: 0, to: Int(size.height), by: 2) {
            for x in stride(from: 0, to: W, by: 2) {
                let i = (y * W + x) * 4
                let d = (0..<3).reduce(0.0) { $0 + abs(Double(a[i + $1]) - Double(b[i + $1])) } / 3
                let pt = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if inner.contains(pt) { inDiff += d; inCount += 1 }
                else if !outer.contains(pt) { outDiff += d; outCount += 1 }
            }
        }
        let inside = inDiff / max(1, inCount), outside = outDiff / max(1, outCount)
        let p = CGPoint(x: 0.42, y: 0.61)
        let back = masked.normalizedPoint(fromOutput: masked.outputPoint(p, at: 1.3), at: 1.3)
        let roundTrip = hypot(back.x - p.x, back.y - p.y)
        print(String(format: "✓ mask: change inside %.1f, outside %.3f; zoomed UI mapping round-trip error %.1e", inside, outside, roundTrip))
        guard inside > 3, outside < 0.05 else { throw fail("inside \(inside), outside \(outside)") }
        guard roundTrip < 1e-6 else { throw fail("mapping round trip \(roundTrip)") }
    }

    /// Motion blur changes frames while the camera zooms, only the cursor area otherwise.
    private static func motionBlurTest(project: Project, dir: URL) async throws {
        func fail(_ m: String) -> NSError { NSError(domain: "selftest", code: 11, userInfo: [NSLocalizedDescriptionKey: "Motion blur: \(m)"]) }
        let saved = project.settings
        defer { project.settings = saved }
        project.settings.motionBlur = 0
        let sharp = FrameRenderer(project: project)
        project.settings.motionBlur = 0.8
        let blurred = FrameRenderer(project: project)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: project.videoURL))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let ctx = CIContext()
        let size = sharp.outputSize
        func bitmap(_ img: CIImage) -> [UInt8] {
            let cg = ctx.createCGImage(img, from: CGRect(origin: .zero, size: size))!
            var buf = [UInt8](repeating: 0, count: 480 * 270 * 4)
            let c = CGContext(data: &buf, width: 480, height: 270, bitsPerComponent: 8, bytesPerRow: 480 * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(cg, in: CGRect(x: 0, y: 0, width: 480, height: 270))
            return buf
        }
        func diff(at t: Double) async throws -> Double {
            let src = CIImage(cgImage: try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image)
            let blurredImage = blurred.render(source: src, time: t)
            if t == 0.75 {
                let cg = ctx.createCGImage(blurredImage, from: CGRect(origin: .zero, size: size))!
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("motionblur-0.75.png"))
            }
            let a = bitmap(sharp.render(source: src, time: t)), b = bitmap(blurredImage)
            return zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
        }
        let ramp = try await diff(at: 0.75)      // zooming in
        let noZoom = try await diff(at: 0.2)     // before the zoom: only the moving cursor
        print(String(format: "✓ motion blur: mean change while zooming %.2f, before zoom (cursor only) %.3f", ramp, noZoom))
        guard ramp > 0.5 else { throw fail("no blur while zooming (\(ramp))") }
        guard noZoom > 0, noZoom < 0.1 else { throw fail("unexpected change without zoom (\(noZoom))") }
    }

    /// Speech → captions (on-device), grouping, SRT with cuts, rendering.
    private static func captionTest(project: Project, dir: URL) async throws {
        func fail(_ m: String) -> NSError { NSError(domain: "selftest", code: 13, userInfo: [NSLocalizedDescriptionKey: "Captions: \(m)"]) }
        // SRT time mapping through cuts.
        let srt = CaptionGenerator.srt([Caption(start: 1.0, end: 2.0, text: "A"), Caption(start: 2.5, end: 3.0, text: "B"),
                                        Caption(start: 5, end: 6, text: "C")], kept: [0.5...2.2, 2.8...4.0])
        let expected = "1\n00:00:00,500 --> 00:00:01,500\nA\n\n2\n00:00:01,700 --> 00:00:01,900\nB\n\n"
        guard srt == expected else { throw fail("SRT:\n\(srt)") }
        print("✓ SRT export maps caption times through cuts")

        guard #available(macOS 26.0, *) else { print("– speech recognition skipped (macOS < 26)"); return }
        let speech = dir.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Anna", "-o", speech.path,
                         "Hallo zusammen. In diesem Video zeige ich euch, wie man eine Bildschirmaufnahme bearbeitet. Danach exportieren wir das Ergebnis als Video."]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { print("– speech recognition skipped (say failed)"); return }
        let start = Date()
        let words = try await CaptionGenerator.transcribe(url: speech, localeID: "de-DE") { _ in }
        let captions = CaptionGenerator.group(words)
        let all = captions.map(\.text).joined(separator: " ")
        print(String(format: "✓ speech recognized in %.1fs: %d words → %d captions", Date().timeIntervalSince(start), words.count, captions.count))
        for c in captions { print(String(format: "    %5.2f–%5.2f  %@", c.start, c.end, c.text)) }
        guard all.lowercased().contains("bildschirmaufnahme") else { throw fail("text '\(all)'") }
        guard captions.count >= 3, captions.allSatisfy({ $0.text.count <= CaptionGenerator.maxCharacters + 20 }) else {
            throw fail("grouping \(captions.map(\.text))")
        }
        guard zip(captions, captions.dropFirst()).allSatisfy({ $0.0.end <= $0.1.start + 1e-9 }) else { throw fail("overlap") }

        // Render one caption into a frame.
        let saved = project.settings
        defer { project.settings = saved }
        project.settings.captions = [Caption(start: 0, end: 4, text: captions.first?.text ?? "Test")]
        let renderer = FrameRenderer(project: project)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: project.videoURL))
        let src = CIImage(cgImage: try await gen.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image)
        let ctx = CIContext()
        let cg = ctx.createCGImage(renderer.render(source: src, time: 0.3), from: CGRect(origin: .zero, size: renderer.outputSize))!
        try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("caption.png"))
    }

    /// Only ⌘/⌃/⌥ combinations become labels; badge renders.
    private static func shortcutTest(project: Project, dir: URL) async throws {
        func fail(_ m: String) -> NSError { NSError(domain: "selftest", code: 14, userInfo: [NSLocalizedDescriptionKey: "Shortcuts: \(m)"]) }
        let cases: [(UInt16, String?, NSEvent.ModifierFlags, String?)] = [
            (1, "s", [.command, .shift], "⇧⌘S"),
            (8, "c", [.command], "⌘C"),
            (36, "\r", [.command], "⌘↩"),
            (123, nil, [.control, .option], "⌃⌥←"),
            (1, "s", [], nil),            // plain typing: never recorded
            (1, "S", [.shift], nil),      // shift only: never recorded
        ]
        for (code, chars, flags, expected) in cases {
            let got = KeyShortcuts.label(keyCode: code, characters: chars, flags: flags)
            guard got == expected else { throw fail("\(code) \(flags.rawValue): \(got ?? "nil") ≠ \(expected ?? "nil")") }
        }
        let saved = project.cursor
        defer { project.cursor = saved }
        project.cursor.keys = [KeyEvent(t: 0.1, label: "⇧⌘S")]
        let renderer = FrameRenderer(project: project)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: project.videoURL))
        let src = CIImage(cgImage: try await gen.image(at: CMTime(seconds: 0.4, preferredTimescale: 600)).image)
        let cg = CIContext().createCGImage(renderer.render(source: src, time: 0.4), from: CGRect(origin: .zero, size: renderer.outputSize))!
        try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("shortcut.png"))
        print("✓ shortcut labels (plain typing ignored) and badge rendering")
    }

    /// Pauses: samples inside are dropped, later ones shift back by the paused time.
    private static func pauseGateTest() throws {
        let gate = PauseGate()
        gate.pause(at: 10)
        gate.resume(at: 13)
        gate.pause(at: 20)
        func check(_ cond: Bool, _ msg: String) throws {
            if !cond { throw NSError(domain: "selftest", code: 6, userInfo: [NSLocalizedDescriptionKey: "PauseGate: \(msg)"]) }
        }
        try check(gate.adjust(5) == 5, "before pause")
        try check(gate.adjust(11) == nil, "inside pause")
        try check(gate.adjust(15) == 12, "after first pause")
        try check(gate.adjust(21) == nil, "inside open pause")
        try check(gate.recordingTime(at: 25) == 17, "recording time while paused")
        gate.resume(at: 22)
        try check(gate.adjust(30) == 25, "after two pauses")
        guard let sb = pcmBuffer(freq: 440, startFrame: 30 * 48_000, frames: 480, sampleRate: 48_000),
              let shifted = gate.retime(sb) else { try check(false, "retime nil"); return }
        try check(abs(shifted.presentationTimeStamp.seconds - 25) < 1e-6, "retimed PTS \(shifted.presentationTimeStamp.seconds)")
        try check(CMSampleBufferGetNumSamples(shifted) == 480, "sample count")
        let inside = pcmBuffer(freq: 440, startFrame: 11 * 48_000, frames: 480, sampleRate: 48_000)!
        try check(gate.retime(inside) == nil, "sample inside pause dropped")
        print("✓ pause gate: drops paused samples, shifts later ones (incl. sample buffers)")
    }

    private static func pcmBuffer(freq: Double, startFrame: Int, frames: Int, sampleRate: Double) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        let bytes = frames * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let fmt, let block else { return nil }
        let samples = (0..<frames).map { Float(0.3 * sin(2 * .pi * freq * Double(startFrame + $0) / sampleRate)) }
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt,
                                                             sampleCount: frames,
                                                             presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate)),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }

    /// 640×360 "webcam": warm background with a moving head-like circle.
    private static func writeSyntheticCamera(url: URL, duration: Double) async throws {
        let width = 640, height = 360, fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<Int(duration * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(CGColor(red: 0.55, green: 0.42, blue: 0.35, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let dx = CGFloat(sin(Double(i) / 10) * 40)
            ctx.setFillColor(CGColor(red: 0.95, green: 0.8, blue: 0.68, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 250 + dx, y: 90, width: 140, height: 170))
            ctx.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.6, alpha: 1))
            ctx.fill(CGRect(x: 200 + dx, y: 0, width: 240, height: 80))
            // Marker on the left so mirroring is visible
            ctx.setFillColor(CGColor(red: 1, green: 0.85, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 20, y: 150, width: 60, height: 60))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? RecorderError.writerFailed("synthetic camera") }
    }

    private static func drawFakeDesktop(_ ctx: CGContext, width: Int, height: Int, frame: Int) {
        let W = CGFloat(width), H = CGFloat(height)
        ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        // Title bar
        ctx.setFillColor(CGColor(red: 0.88, green: 0.88, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: H - 70, width: W, height: 70))
        for (i, c) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 28 + CGFloat(i) * 40, y: H - 48, width: 26, height: 26))
        }
        // Sidebar + content blocks
        ctx.setFillColor(CGColor(red: 0.9, green: 0.91, blue: 0.94, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: H - 70))
        for row in 0..<8 {
            ctx.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.9, alpha: row == (frame / 15) % 8 ? 0.9 : 0.25))
            ctx.fill(CGRect(x: 360, y: H - 150 - CGFloat(row) * 90, width: W - 420, height: 56))
        }
        // Moving element so frames differ
        ctx.setFillColor(CGColor(red: 0.95, green: 0.3, blue: 0.4, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 40 + CGFloat(frame * 4 % 200), y: 60, width: 60, height: 60))
    }
}
