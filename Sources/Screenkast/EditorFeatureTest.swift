import Foundation
import AVFoundation
import CoreImage
import AppKit

/// Selftest for audio lanes (mutes, ducking), voice-over placement, waveforms, text overlays
/// and intro/outro title cards. Uses the synthetic project of `SelfTest` (4 s, system 440 Hz,
/// mic 660 Hz, both 0.3 amplitude).
enum EditorFeatureTest {
    private static func fail(_ m: String) -> NSError {
        NSError(domain: "selftest", code: 40, userInfo: [NSLocalizedDescriptionKey: m])
    }

    static func run(base: Project, dir: URL) async throws {
        try await waveformTest(base)
        try await muteTest(base)
        try await voiceOverTest(base)
        try await textOverlayTest(base, dir: dir)
        try await introOutroTest(base, dir: dir)
        srtOffsetTest()
        try await voiceOverCrossfadeTest(base)
        try await cutDissolveTest(base, dir: dir)
        try await introOverlapTest(base)
        try await MainActor.run { try timelineModelTest(base) }
        try await MainActor.run { try editingModelTest(base) }
        try timeMapTest()
        try await speedTest(base)
        try await freezeTest(base)
        try await transitionStyleTest(base)
        try await fadeTest(base)
        try await MainActor.run { try speedFreezeModelTest(base) }
        try await ExtrasTest.run(base: base, dir: dir)
    }

    private static func project(_ base: Project, _ change: (inout EditSettings) -> Void) -> Project {
        var s = base.settings
        s.removeEcho = false
        s.micVolume = 1
        s.systemVolume = 1
        change(&s)
        return Project(url: base.url, info: base.info, cursor: base.cursor, settings: s)
    }

    /// Mixed audio of the tracks with `role` (48 kHz mono), with the project's audio mix.
    private static func mixedAudio(_ media: MediaComposition, settings: EditSettings, role: String) async throws -> [Float] {
        let tracks = media.audioTracks.filter { $0.role == role }.map(\.track)
        guard !tracks.isEmpty else { throw fail("no \(role) track in composition") }
        let reader = try AVAssetReader(asset: media.asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        ])
        output.audioMix = media.audioMix(settings: settings)
        output.audioTimePitchAlgorithm = .spectral
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? fail("audio reader") }
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

    /// Frequency by zero crossings.
    private static func frequency(_ s: [Float], _ r: ClosedRange<Double>) -> Double {
        let a = Int(r.lowerBound * 48_000), b = min(s.count, Int(r.upperBound * 48_000))
        var crossings = 0
        for i in (a + 1)..<b where (s[i - 1] < 0) != (s[i] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (r.upperBound - r.lowerBound)
    }

    // MARK: Waveform

    private static func waveformTest(_ base: Project) async throws {
        let asset = AVURLAsset(url: base.videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let roles = await AudioRole.roles(of: tracks, fallback: base.info.audioRoles)
        guard let mic = roles.firstIndex(of: "mic") else { throw fail("waveform: no mic") }
        let peaks = try await Waveform.peaks(track: tracks[mic], asset: asset)
        let middle = Array(peaks[50..<350]).sorted()
        let median = middle[middle.count / 2]
        guard peaks.count >= 390, abs(median - 0.3) < 0.06 else {
            throw fail("waveform peaks: \(peaks.count) buckets, median \(median)")
        }
        print(String(format: "✓ waveform: %d buckets, peak %.2f (tone 0.30)", peaks.count, median))
    }

    // MARK: Muted ranges

    private static func muteTest(_ base: Project) async throws {
        let p = project(base) { $0.audioMutes = [AudioMute(lane: .mic, start: 1.0, end: 2.0)] }
        let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30)
        let mic = try await mixedAudio(media, settings: p.settings, role: "mic")
        let sys = try await mixedAudio(media, settings: p.settings, role: "system")
        let before = rms(mic, 0.3...0.9), inside = rms(mic, 1.1...1.9), after = rms(mic, 2.1...2.9)
        let sysInside = rms(sys, 1.1...1.9)
        guard before > 0.15, after > 0.15, inside < 0.01, sysInside > 0.15 else {
            throw fail(String(format: "mute: mic %.3f / %.3f / %.3f, system inside %.3f", before, inside, after, sysInside))
        }
        // Envelope: breakpoints in order, silent inside.
        let pts = VolumeEnvelope.points(base: 1, dips: [.init(start: 1, end: 2, level: 0, rampIn: 0.015, rampOut: 0.015),
                                                        .init(start: 1.5, end: 3, level: 0.25, rampIn: 0.25, rampOut: 0.4)], total: 4)
        guard zip(pts, pts.dropFirst()).allSatisfy({ $0.time < $1.time }),
              VolumeEnvelope.value(at: 1.5, base: 1, dips: [.init(start: 1, end: 2, level: 0, rampIn: 0.015, rampOut: 0.015)]) == 0 else {
            throw fail("volume envelope breakpoints")
        }
        print(String(format: "✓ muted range: mic %.2f → %.3f → %.2f, system unaffected (%.2f)", before, inside, after, sysInside))
    }

    // MARK: Voice-over

    private static func voiceOverTest(_ base: Project) async throws {
        // 2 s narration file: 880 Hz for 1.25 s, then 1320 Hz.
        let file = "voiceover/selftest.caf"
        let url = base.url.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let samples = (0..<96_000).map { i -> Float in
            let t = Double(i) / 48_000
            return Float(0.3 * sin(2 * .pi * (t < 1.25 ? 880 : 1320) * t))
        }
        try EchoCanceller.writeCAF(samples, to: url)

        // File 0.5–2.0 s plays at source 1.0–2.5; the cut 1.5–2.0 removes the middle.
        let clip = VoiceOverClip(file: file, fileOffset: 0.5, start: 1.0, duration: 1.5)
        let p = project(base) {
            $0.voiceOvers = [clip]
            $0.cuts = [CutRange(start: 1.5, end: 2.0)]
            $0.duckUnderVoiceOver = true
            $0.duckLevel = 0.25
        }
        let kept = p.settings.keptSegments(duration: base.info.duration)
        let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30, segments: kept)
        let vo = try await mixedAudio(media, settings: p.settings, role: "voiceover")
        let mic = try await mixedAudio(media, settings: p.settings, role: "mic")
        // Composition: source 1.0–1.5 → 1.0–1.5 (file 0.5–1.0, 880 Hz); source 2.0–2.5 → 1.5–2.0 (file 1.5–2.0, 1320 Hz).
        let silentBefore = rms(vo, 0.2...0.8), first = rms(vo, 1.1...1.4), second = rms(vo, 1.6...1.9), silentAfter = rms(vo, 2.3...3.2)
        let f1 = frequency(vo, 1.1...1.4), f2 = frequency(vo, 1.6...1.9)
        guard silentBefore < 0.01, silentAfter < 0.01, first > 0.15, second > 0.15,
              abs(f1 - 880) < 30, abs(f2 - 1320) < 30 else {
            throw fail(String(format: "voice-over placement: rms %.3f/%.3f/%.3f/%.3f, freq %.0f/%.0f",
                              silentBefore, first, second, silentAfter, f1, f2))
        }
        let micNormal = rms(mic, 0.2...0.6), micDucked = rms(mic, 1.1...1.4)
        guard abs(micDucked / micNormal - 0.25) < 0.05 else {
            throw fail(String(format: "ducking: mic %.3f → %.3f", micNormal, micDucked))
        }
        print(String(format: "✓ voice-over across a cut: right place and part of the file (%.0f/%.0f Hz), original ducked to %.0f %%",
                     f1, f2, micDucked / micNormal * 100))
    }

    // MARK: Text overlays

    private static func meanDiff(_ a: CIImage, _ b: CIImage, in rect: CGRect, context: CIContext) -> Double {
        let diff = a.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: b])
            .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        var px = [Float](repeating: 0, count: 4)
        context.render(diff, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Double(px[0] + px[1] + px[2]) / 3 * 255
    }

    private static func textOverlayTest(_ base: Project, dir: URL) async throws {
        let lower = TextOverlay(kind: .lowerThird, start: 0.5, end: 3.0, title: "Max Mustermann", subtitle: "Screenkast-Demo")
        let card = TextOverlay(kind: .titleCard, placement: .overlay, start: 3.2, end: 3.9, title: "Kapitel 2", style: .dark, align: .center)
        let p = project(base) { $0.texts = [lower, card] }
        let renderer = FrameRenderer(project: p)
        let plain = FrameRenderer(project: project(base) { $0.texts = [] })
        let source = CIImage(color: CIColor(red: 0.5, green: 0.55, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        let ctx = CIContext()
        let out = renderer.outputSize
        let withText = renderer.render(source: source, camera: nil, time: 1.5)
        let without = plain.render(source: source, camera: nil, time: 1.5)
        let rect = renderer.lowerThirdFrame(lower)
        let inside = meanDiff(withText, without, in: rect, context: ctx)
        let outside = meanDiff(withText, without, in: CGRect(x: out.width * 0.6, y: out.height * 0.6, width: out.width * 0.3, height: out.height * 0.3), context: ctx)
        guard rect.minX >= 0, rect.maxX <= out.width, rect.width > 100, inside > 20, outside < 0.5 else {
            throw fail(String(format: "lower third: rect %@, change inside %.1f, outside %.2f", NSStringFromRect(rect), inside, outside))
        }
        // Covering title card at full opacity in its middle: the recording is hidden.
        let covered = renderer.render(source: source, camera: nil, time: 3.55)
        let uncovered = plain.render(source: source, camera: nil, time: 3.55)
        let cover = meanDiff(covered, uncovered, in: CGRect(origin: .zero, size: out), context: ctx)
        guard cover > 30 else { throw fail(String(format: "overlay title card change %.1f", cover)) }
        if let cg = ctx.createCGImage(withText, from: CGRect(origin: .zero, size: out)) {
            try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("lower-third.png"))
        }
        print(String(format: "✓ lower third (change inside %.0f, outside %.2f) and covering title card", inside, outside))
    }

    // MARK: Intro / outro

    private static func introOutroTest(_ base: Project, dir: URL) async throws {
        let intro = TextOverlay(kind: .titleCard, placement: .intro, start: 0, end: 1.5, title: "Willkommen", subtitle: "Eine Demo",
                                style: .dark, align: .center)
        let outro = TextOverlay(kind: .titleCard, placement: .outro, start: 0, end: 1.0, title: "Danke", style: .light, align: .center)
        let p = project(base) { $0.texts = [intro, outro]; $0.cuts = [] ; $0.trimStart = 0; $0.trimEnd = nil }
        let kept = p.settings.keptSegments(duration: base.info.duration)
        let expected = p.settings.outputDuration(duration: base.info.duration)
        guard abs(expected - (1.5 + base.info.duration + 1.0)) < 0.01 else { throw fail("output duration \(expected)") }
        let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30, segments: kept)
        guard let session = AVAssetExportSession(asset: media.asset, presetName: AVAssetExportPreset1280x720) else { throw fail("export session") }
        session.videoComposition = media.videoComposition
        session.audioMix = media.audioMix(settings: p.settings)
        let url = dir.appendingPathComponent("export-intro-outro.mp4")
        try? FileManager.default.removeItem(at: url)
        try await session.export(to: url, as: .mp4)
        let asset = AVURLAsset(url: url)
        let length = try await asset.load(.duration).seconds
        guard abs(length - expected) < 0.08 else { throw fail(String(format: "exported %.2f s, expected %.2f s", length, expected)) }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        func pixels(_ cg: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: 64 * 36 * 4)
            let ctx = CGContext(data: &buf, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 36))
            return buf
        }
        func brightness(_ t: Double) async throws -> Double {
            let buf = pixels(try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image)
            var sum = 0.0
            for i in stride(from: 0, to: buf.count, by: 4) { sum += Double(buf[i]) + Double(buf[i + 1]) + Double(buf[i + 2]) }
            return sum / Double(64 * 36 * 3)
        }
        let introB = try await brightness(0.7), outroB = try await brightness(length - 0.5)
        // The recording starts right after the intro: export 3.5 s = recording 2.0 s.
        let plain = project(base) { $0.texts = [] }
        let plainMedia = try await MediaBuilder.make(project: plain, renderer: FrameRenderer(project: plain), fps: 30)
        let pgen = AVAssetImageGenerator(asset: plainMedia.asset)
        pgen.videoComposition = plainMedia.videoComposition
        pgen.requestedTimeToleranceBefore = .zero
        pgen.requestedTimeToleranceAfter = .zero
        let exported = pixels(try await gen.image(at: CMTime(seconds: 3.5, preferredTimescale: 600)).image)
        let reference = pixels(try await pgen.image(at: CMTime(seconds: 2.0, preferredTimescale: 600)).image)
        let match = zip(exported, reference).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(exported.count)
        guard introB < 45, outroB > 200, match < 6 else {
            throw fail(String(format: "card frames: intro %.0f, outro %.0f, recording match %.1f", introB, outroB, match))
        }
        // Audio: silent during the intro, the recording's sound starts after it.
        let audio = try await EchoCanceller.readMono(track: try await asset.loadTracks(withMediaType: .audio)[0], asset: asset, duration: length)
        func level(_ r: ClosedRange<Double>) -> Double {
            let a = Int(r.lowerBound * EchoCanceller.sampleRate), b = min(audio.count, Int(r.upperBound * EchoCanceller.sampleRate))
            return sqrt(audio[a..<b].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, b - a)))
        }
        let introAudio = level(0.2...1.3), recAudio = level(2.0...3.0)
        guard introAudio < 0.01, recAudio > 0.05 else { throw fail(String(format: "intro audio %.3f, recording %.3f", introAudio, recAudio)) }
        print(String(format: "✓ intro + outro: %.2f s exported (1.5 + %.1f + 1.0), card brightness %.0f / %.0f, recording shifted by the intro (diff %.1f), audio starts after it",
                     length, base.info.duration, introB, outroB, match))
    }

    private static func srtOffsetTest() {
        let srt = CaptionGenerator.srt([Caption(start: 1.0, end: 2.0, text: "A")], kept: [0...4], offset: 1.5)
        precondition(srt.contains("00:00:02,500 --> 00:00:03,500"), "SRT offset: \(srt)")
        print("✓ SRT times include the intro")
    }

    // MARK: Crossfades and dissolves

    /// Amplitude of the `freq` component in `r` (correlation with sine and cosine).
    private static func amplitude(_ s: [Float], _ r: ClosedRange<Double>, freq: Double) -> Double {
        let a = max(0, Int(r.lowerBound * 48_000)), b = min(s.count, Int(r.upperBound * 48_000))
        guard b > a else { return 0 }
        var re = 0.0, im = 0.0
        for i in a..<b {
            let phase = 2 * .pi * freq * Double(i) / 48_000
            re += Double(s[i]) * cos(phase)
            im += Double(s[i]) * sin(phase)
        }
        return 2 * sqrt(re * re + im * im) / Double(b - a)
    }

    private static func frame(_ media: MediaComposition, _ t: Double) async throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: media.asset)
        gen.videoComposition = media.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        return try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }

    private static func smallPixels(_ img: CGImage) -> [Double] {
        var buf = [UInt8](repeating: 0, count: 160 * 90 * 4)
        let ctx = CGContext(data: &buf, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 160 * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 160, height: 90))
        return buf.enumerated().filter { $0.offset % 4 != 3 }.map { Double($0.element) }
    }

    private static func diff(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0.0) { $0 + abs($1.0 - $1.1) } / Double(max(1, a.count))
    }

    /// Two voice-over clips pushed over each other: equal-power crossfade over the overlap.
    private static func voiceOverCrossfadeTest(_ base: Project) async throws {
        func tone(_ name: String, _ f: Double) throws -> String {
            let file = "voiceover/\(name).caf"
            let url = base.url.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try EchoCanceller.writeCAF((0..<96_000).map { Float(0.3 * sin(2 * .pi * f * Double($0) / 48_000)) }, to: url)
            return file
        }
        let a = VoiceOverClip(file: try tone("xfade-a", 880), fileOffset: 0, start: 0.5, duration: 2.0)    // 0.5–2.5
        let b = VoiceOverClip(file: try tone("xfade-b", 1320), fileOffset: 0, start: 1.5, duration: 2.0)   // 1.5–3.5
        let p = project(base) { $0.voiceOvers = [a, b]; $0.duckUnderVoiceOver = false }
        let fades = VoiceOverClip.crossfades([a, b])
        guard abs((fades[a.id]?.fadeOut ?? 0) - 1) < 1e-9, abs((fades[b.id]?.fadeIn ?? 0) - 1) < 1e-9,
              fades[a.id]?.fadeIn == 0, fades[b.id]?.fadeOut == 0 else { throw fail("crossfade lengths \(fades)") }
        let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30)
        guard media.audioTracks.filter({ $0.role == "voiceover" }).count == 2 else { throw fail("crossfade: clips not on two layers") }
        let vo = try await mixedAudio(media, settings: p.settings, role: "voiceover")
        // Overlap 1.5–2.5: A follows cos, B sin of the progress.
        var report: [String] = []
        for t in [1.0, 1.6, 2.0, 2.4, 3.0] {
            let progress = min(1, max(0, t - 1.5))
            let ga = t < 1.5 ? 1 : (t > 2.5 ? 0 : cos(progress * .pi / 2))
            let gb = t < 1.5 ? 0 : (t > 2.5 ? 1 : sin(progress * .pi / 2))
            let r = (t - 0.02)...(t + 0.02)
            let ma = amplitude(vo, r, freq: 880) / 0.3, mb = amplitude(vo, r, freq: 1320) / 0.3
            report.append(String(format: "%.1fs %.2f/%.2f", t, ma, mb))
            guard abs(ma - ga) < 0.06, abs(mb - gb) < 0.06 else {
                throw fail(String(format: "crossfade at %.1f s: A %.2f (want %.2f), B %.2f (want %.2f)", t, ma, ga, mb, gb))
            }
        }
        let single = rms(vo, 0.8...1.2), middle = rms(vo, 1.9...2.1)
        guard abs(middle / single - 1) < 0.08 else { throw fail(String(format: "crossfade power %.3f vs %.3f", middle, single)) }
        print("✓ voice-over crossfade (equal power, A/B): " + report.joined(separator: ", "))
    }

    /// Cut 1.5–2.0 with a 0.5 s dissolve: the part after the cut is pushed over the end of the part before it.
    private static func cutDissolveTest(_ base: Project, dir: URL) async throws {
        let duration = base.info.duration
        let p = project(base) { $0.cuts = [CutRange(start: 1.5, end: 2.0, dissolve: 0.5)]; $0.trimStart = 0; $0.trimEnd = nil }
        let layout = p.settings.cutLayout(duration: duration)
        guard layout.segments == [0...1.5, 2.5...duration], layout.dissolves.count == 1,
              abs(p.settings.outputDuration(duration: duration) - (duration - 1.0)) < 1e-9 else {
            throw fail("dissolve layout \(layout)")
        }
        let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30, segments: layout.segments)
        guard abs(media.totalDuration - (duration - 1.0)) < 0.01, media.dissolves.count == 1,
              abs(media.dissolves[0].start - 1.0) < 1e-3, media.joins.isEmpty else {
            throw fail("dissolve composition: \(media.totalDuration) s, \(media.dissolves), joins \(media.joins)")
        }
        let plain = project(base) { $0.cuts = []; $0.trimStart = 0; $0.trimEnd = nil }
        let plainMedia = try await MediaBuilder.make(project: plain, renderer: FrameRenderer(project: plain), fps: 30)
        // Middle of the dissolve (output 1.25): half source 1.25, half source 2.25.
        let mid = smallPixels(try await frame(media, 1.25))
        let fa = smallPixels(try await frame(plainMedia, 1.25)), fb = smallPixels(try await frame(plainMedia, 2.25))
        let blend = zip(fa, fb).map { ($0 + $1) / 2 }
        let toBlend = diff(mid, blend), apart = diff(fa, fb)
        // After it (output 2.0) the recording continues at source 3.0.
        let after = diff(smallPixels(try await frame(media, 2.0)), smallPixels(try await frame(plainMedia, 3.0)))
        // The editor preview (whole recording in source time) shows the same dissolve at source 1.25.
        let previewMedia = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30)
        let preview = diff(smallPixels(try await frame(previewMedia, 1.25)), mid)
        guard apart > 2, toBlend < apart * 0.25, after < 1.5, preview < 1.5 else {
            throw fail(String(format: "dissolve frames: to blend %.2f, A↔B %.2f, after %.2f, preview %.2f", toBlend, apart, after, preview))
        }
        // Sound: no gap or click where the incoming part moves back to the main track (output 1.5).
        let mic = try await mixedAudio(media, settings: p.settings, role: "mic")
        let normal = rms(mic, 0.3...0.9)
        var lowest = 9.0, highest = 0.0
        for t in stride(from: 1.49, to: 1.56, by: 0.004) {
            let level = rms(mic, t...(t + 0.004)) / normal
            lowest = min(lowest, level); highest = max(highest, level)
        }
        guard lowest > 0.85, highest < 1.15 else { throw fail(String(format: "dissolve sound at the join %.2f…%.2f", lowest, highest)) }

        guard let session = AVAssetExportSession(asset: media.asset, presetName: AVAssetExportPreset1280x720) else { throw fail("export session") }
        session.videoComposition = media.videoComposition
        session.audioMix = media.audioMix(settings: p.settings)
        let url = dir.appendingPathComponent("export-dissolve.mp4")
        try? FileManager.default.removeItem(at: url)
        try await session.export(to: url, as: .mp4)
        let exported = try await AVURLAsset(url: url).load(.duration).seconds
        guard abs(exported - (duration - 1.0)) < 0.08 else { throw fail(String(format: "dissolve export %.2f s", exported)) }
        print(String(format: "✓ cross dissolve at a cut: %.2f s exported (0.5 s cut + 0.5 s overlap), mid frame = blend (%.2f vs A↔B %.2f), "
                     + "same in the preview (%.2f), continues at the right frame (%.2f), sound level at the join %.2f…%.2f",
                     exported, toBlend, apart, preview, after, lowest, highest))
    }

    /// Intro (1.5 s) pushed 0.5 s over the recording: the recording starts under the card.
    private static func introOverlapTest(_ base: Project) async throws {
        let duration = base.info.duration
        let intro = TextOverlay(kind: .titleCard, placement: .intro, start: 0, end: 1.5, title: "Hallo", style: .dark, align: .center)
        let p = project(base) { $0.texts = [intro]; $0.introOverlap = 0.5; $0.cuts = []; $0.trimStart = 0; $0.trimEnd = nil }
        guard abs(p.settings.introLead(duration: duration) - 1.0) < 1e-9,
              abs(p.settings.outputDuration(duration: duration) - (duration + 1.0)) < 1e-9 else { throw fail("intro overlap lengths") }
        let kept = p.settings.keptSegments(duration: duration)
        let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30, segments: kept)
        guard abs(media.totalDuration - (duration + 1.0)) < 0.01 else { throw fail("intro overlap composition \(media.totalDuration)") }
        let plain = project(base) { $0.texts = []; $0.cuts = []; $0.trimStart = 0; $0.trimEnd = nil }
        let plainMedia = try await MediaBuilder.make(project: plain, renderer: FrameRenderer(project: plain), fps: 30)
        // Mean brightness in linear light (Core Image blends there).
        func brightness(_ px: [Double]) -> Double {
            px.reduce(0) { $0 + pow(($1 / 255 + 0.055) / 1.055, 2.4) } / Double(px.count)
        }
        let card = brightness(smallPixels(try await frame(media, 0.5)))
        let recording = brightness(smallPixels(try await frame(plainMedia, 0.25)))
        let middle = brightness(smallPixels(try await frame(media, 1.25)))
        let after = diff(smallPixels(try await frame(media, 1.6)), smallPixels(try await frame(plainMedia, 0.6)))
        guard abs(recording - card) > 0.1, abs(middle - (card + recording) / 2) < abs(recording - card) * 0.15, after < 1.5 else {
            throw fail(String(format: "intro dissolve: card %.3f, recording %.3f, middle %.3f, after %.2f", card, recording, middle, after))
        }
        let mic = try await mixedAudio(media, settings: p.settings, role: "mic")
        let silent = rms(mic, 0.2...0.8), under = rms(mic, 1.1...1.4)
        guard silent < 0.01, under > 0.15 else { throw fail(String(format: "intro overlap sound %.3f / %.3f", silent, under)) }
        print(String(format: "✓ intro pushed over the recording: %.1f s output, dissolve brightness (linear) %.2f → %.2f → %.2f, sound starts under the card",
                     media.totalDuration, card, middle, recording))
    }

    // MARK: Timeline model (zoom, playback over dissolves)

    @MainActor
    private static func timelineModelTest(_ base: Project) throws {
        let p = project(base) { $0.cuts = [CutRange(start: 1.5, end: 2.0, dissolve: 0.5)]; $0.texts = []; $0.trimStart = 0; $0.trimEnd = nil }
        let editor = EditorModel(project: p)
        editor.timelineWidth = 200   // closest zoom: 0.25 s
        let total = editor.totalSpan
        guard !editor.isZoomed, editor.visibleStart == editor.timelineStart, abs(editor.visibleSpan - total) < 1e-9 else {
            throw fail("timeline zoom: not fitted at start")
        }
        // Zoom in around 2.0 s: the anchor keeps its place on screen.
        let fraction = (2.0 - editor.visibleStart) / editor.visibleSpan
        editor.zoom(by: 4, around: 2.0)
        let newFraction = (2.0 - editor.visibleStart) / editor.visibleSpan
        guard editor.isZoomed, abs(editor.visibleSpan - total / 4) < 1e-9, abs(newFraction - fraction) < 1e-9 else {
            throw fail("timeline zoom: span \(editor.visibleSpan), anchor \(fraction) → \(newFraction)")
        }
        editor.pan(by: 100)
        guard abs(editor.visibleStart + editor.visibleSpan - editor.displayEnd) < 1e-9 else { throw fail("timeline pan past the end") }
        editor.zoom(by: 1000)
        guard abs(editor.visibleSpan - editor.minSpan) < 1e-9, abs(editor.zoomLevel - 1) < 1e-9 else { throw fail("timeline zoom limit") }
        editor.zoomLevel = 0.5
        guard abs(editor.zoomLevel - 0.5) < 1e-6 else { throw fail("zoom slider round trip \(editor.zoomLevel)") }
        editor.zoomToFit()
        guard !editor.isZoomed else { throw fail("zoom to fit") }
        // The timeline closes up over the cut and the part the dissolve already showed.
        guard abs(editor.display(1.0) - 1.0) < 1e-6, abs(editor.display(2.5) - 1.5) < 1e-6, abs(editor.display(2.6) - 1.6) < 1e-6,
              abs(editor.display(2.2) - 1.5) < 1e-6, !editor.timeMap.contains(source: 2.2),
              abs(editor.sourceTime(1.6) - 2.6) < 1e-6, abs(editor.timeMap.total - (base.info.duration - 1)) < 1e-6 else {
            throw fail("closed timeline: \(editor.display(2.5)) \(editor.display(2.2)) total \(editor.timeMap.total)")
        }
        print("✓ timeline zoom (anchor kept, limits, slider) and the timeline closes up over a cut with a dissolve")
    }

    // MARK: Editing (text position, undo, split, snapping, adding in lanes)

    @MainActor
    private static func editingModelTest(_ base: Project) throws {
        let p = project(base) { $0.cuts = []; $0.splits = []; $0.texts = []; $0.zoomSegments = []; $0.masks = []; $0.voiceOvers = []
            $0.trimStart = 0; $0.trimEnd = nil }
        let editor = EditorModel(project: p)
        let out = editor.renderer.outputSize

        // Text alignment: the box stays where it is, only the anchor changes.
        editor.addLowerThird(start: 0.5)
        guard let id = editor.selectedTextID, let text = editor.selectedText else { throw fail("no lower third") }
        guard let cell = editor.anchorCell(text), cell.column == 0, cell.row == 2 else { throw fail("default lower third not bottom left") }
        let before = editor.renderer.lowerThirdFrame(text)
        for align in [TextAlign.center, .right, .left] {
            editor.setTextAlign(id: id, align)
            let now = editor.renderer.lowerThirdFrame(editor.selectedText!)
            guard abs(now.minX - before.minX) < 1, abs(now.minY - before.minY) < 1 else {
                throw fail("alignment \(align) moved the box from \(before) to \(now)")
            }
        }
        // Dragging far past the edge keeps the box on screen and leaves no dead zone.
        let origin = editor.selectedText!
        editor.moveLowerThird(id: id, from: origin, dx: -2, dy: 0)
        let atEdge = editor.renderer.lowerThirdFrame(editor.selectedText!)
        editor.moveLowerThird(id: id, from: editor.selectedText!, dx: 0.05, dy: 0)
        let back = editor.renderer.lowerThirdFrame(editor.selectedText!)
        guard atEdge.minX == 0, abs(back.minX - 0.05 * out.width) < 1 else {
            throw fail("drag past the edge: at edge \(atEdge.minX), back \(back.minX)")
        }
        // Near the middle it snaps to the center.
        let centerDx = Double((out.width / 2 - back.midX + out.width * 0.006) / out.width)
        editor.moveLowerThird(id: id, from: editor.selectedText!, dx: centerDx, dy: 0)
        let centered = editor.renderer.lowerThirdFrame(editor.selectedText!)
        guard abs(centered.midX - out.width / 2) < 0.5, editor.textCenterGuide else {
            throw fail("center snap: midX \(centered.midX) of \(out.width), guide \(editor.textCenterGuide)")
        }
        editor.endInteraction()
        editor.placeLowerThird(id: id, column: 2, row: 0)
        guard let corner = editor.anchorCell(editor.selectedText!), corner.column == 2, corner.row == 0,
              editor.renderer.lowerThirdFrame(editor.selectedText!).maxX > out.width * 0.9 else { throw fail("position grid top right") }

        // Undo / redo: a burst of changes is one step.
        editor.commitUndoStep()
        let padding = editor.settings.padding
        editor.settings.padding = 0.1
        editor.settings.padding = 0.15
        editor.commitUndoStep()
        editor.undo()
        guard editor.settings.padding == padding, editor.canRedo else { throw fail("undo: padding \(editor.settings.padding)") }
        editor.redo()
        guard editor.settings.padding == 0.15 else { throw fail("redo: padding \(editor.settings.padding)") }

        // Split at the playhead, select the part after it and remove it; undo brings it back.
        editor.seek(to: 1.0)
        editor.splitAtPlayhead()
        guard editor.videoSegments == [0...1.0, 1.0...base.info.duration] else { throw fail("split: \(editor.videoSegments)") }
        editor.seek(to: 3.0)
        editor.splitAtPlayhead()
        editor.selection = .segment(1.0)
        editor.deleteSelection()
        let kept = editor.settings.keptSegments(duration: base.info.duration)
        guard kept == [0...1.0, 3.0...base.info.duration], editor.selection == nil else { throw fail("remove part: kept \(kept)") }
        editor.undo()
        guard editor.settings.cuts.isEmpty, editor.settings.splits.count == 2 else { throw fail("undo remove: \(editor.settings.cuts)") }
        editor.selection = .segment(1.0)
        editor.joinWithNext(1.0...3.0)
        guard editor.videoSegments.count == 2 else { throw fail("join: \(editor.videoSegments)") }

        // A selected voice-over clip under the playhead is split instead of the recording.
        editor.settings.voiceOvers = [VoiceOverClip(file: "voiceover/none.caf", fileOffset: 0.2, start: 0.5, duration: 2.0)]
        editor.selectedVoiceOverID = editor.settings.voiceOvers[0].id
        editor.seek(to: 1.5)
        editor.splitAtPlayhead()
        let clips = editor.settings.voiceOvers.sorted { $0.start < $1.start }
        guard clips.count == 2, abs(clips[0].end - 1.5) < 1e-9, abs(clips[1].start - 1.5) < 1e-9,
              abs(clips[1].fileOffset - 1.2) < 1e-9, abs(clips[1].end - 2.5) < 1e-9 else { throw fail("voice-over split: \(clips)") }

        // Snapping: an edge near the playhead lands on it; off, nothing changes.
        editor.seek(to: 2.0)
        // The switch is remembered for the app: leave it as the user set it.
        let userSnapping = editor.snapping
        defer { editor.snapping = userSnapping }
        editor.snapping = true
        let snappedDelta = editor.snapDelta(.move, dt: 0.97, start: 0, end: 1.0, tolerance: 0.05, excluding: nil)
        editor.snapping = false
        let free = editor.snapDelta(.move, dt: 0.97, start: 0, end: 1.0, tolerance: 0.05, excluding: nil)
        editor.snapping = true
        guard abs(snappedDelta - 1.0) < 1e-9, free == 0.97 else { throw fail("snapping: \(snappedDelta), off \(free)") }

        // Clicking into an empty lane: a new item fits up to the next one.
        editor.settings.zoomSegments = [ZoomSegment(start: 1.0, end: 3.0, scale: 2)]
        guard editor.freeRange(.zoom, at: 0.2) == 0.2...1.0, editor.freeRange(.zoom, at: 2.0) == nil,
              editor.freeRange(.zoom, at: 0.8) == nil, editor.freeRange(.mask, at: 0.2) == 0.2...3.2 else {
            throw fail("free ranges")
        }
        editor.add(.zoom, range: 0.2...1.0)
        guard editor.settings.zoomSegments.count == 2, editor.selectedZoomIndex != nil else { throw fail("add zoom in lane") }
        print("✓ editing: text alignment keeps the box, drag stays on screen and snaps to the center, position grid, "
              + "undo/redo, split/remove/join, voice-over split, snapping, adding in empty lanes")
    }

    // MARK: Speed, freeze frames, transition styles, fades

    private static func timeMapTest() throws {
        let speed = TimeMap(duration: 4, speeds: [SpeedRange(start: 1, end: 3, rate: 2)])
        guard abs(speed.total - 3) < 1e-9, abs(speed.timeline(2) - 1.5) < 1e-9, abs(speed.source(1.5) - 2) < 1e-9,
              abs(speed.timeline(3.5) - 2.5) < 1e-9, abs(speed.timeline(5) - 4) < 1e-9, speed.timeline(-1) == -1 else {
            throw fail("time map with 2×: total \(speed.total), 2 s → \(speed.timeline(2))")
        }
        let freeze = TimeMap(duration: 4, freezes: [FreezeFrame(at: 2, duration: 1.5)])
        let inside = freeze.source(2.7)
        // The freeze is made of a 1 ms piece of the recording stretched to 1.5 s.
        guard abs(freeze.total - (5.5 - FreezeFrame.span)) < 1e-9, abs(freeze.timeline(2) - (2 + 1.5 - FreezeFrame.span)) < 1e-9,
              inside > 2 - FreezeFrame.span, inside < 2, abs(freeze.timeline(inside) - 2.7) < 1e-9,
              freeze.isFrozen(atTimeline: 2.7), !freeze.isFrozen(atTimeline: 1), abs(freeze.source(4.5) - (3.0 + FreezeFrame.span)) < 1e-9 else {
            throw fail("time map with freeze: total \(freeze.total), inside \(inside)")
        }
        print("✓ time map: 2× part and freeze frame map both ways (every moment of a freeze has its own source time)")
    }

    private static func plainMedia(_ base: Project) async throws -> MediaComposition {
        let plain = project(base) { $0.cuts = []; $0.texts = []; $0.speeds = []; $0.freezes = []; $0.trimStart = 0; $0.trimEnd = nil }
        return try await MediaBuilder.make(project: plain, renderer: FrameRenderer(project: plain), fps: 30)
    }

    /// 1–3 s at 2×: 1 s shorter, the right frames, the tone keeps its pitch.
    private static func speedTest(_ base: Project) async throws {
        let duration = base.info.duration
        let p = project(base) { $0.speeds = [SpeedRange(start: 1, end: 3, rate: 2)]; $0.cuts = []; $0.texts = []; $0.trimStart = 0; $0.trimEnd = nil }
        guard abs(p.settings.outputDuration(duration: duration) - (duration - 1)) < 1e-9 else { throw fail("speed: output duration") }
        let kept = p.settings.keptSegments(duration: duration)
        let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30, segments: kept)
        let plain = try await plainMedia(base)
        guard abs(media.totalDuration - (duration - 1)) < 0.01 else { throw fail("speed: composition \(media.totalDuration)") }
        let mid = diff(smallPixels(try await frame(media, 1.5)), smallPixels(try await frame(plain, 2.0)))
        let after = diff(smallPixels(try await frame(media, 2.5)), smallPixels(try await frame(plain, 3.5)))
        guard mid < 1.5, after < 1.5 else { throw fail(String(format: "speed frames: %.2f / %.2f", mid, after)) }
        let mic = try await mixedAudio(media, settings: p.settings, role: "mic")
        let pitch = amplitude(mic, 1.3...1.7, freq: 660) / 0.3, octave = amplitude(mic, 1.3...1.7, freq: 1320) / 0.3
        guard pitch > 0.6, octave < 0.2 else { throw fail(String(format: "speed sound: 660 Hz %.2f, 1320 Hz %.2f", pitch, octave)) }
        print(String(format: "✓ speed 2×: %.1f s instead of %.1f s, frames match (%.2f/%.2f), pitch kept (660 Hz at %.0f %%)",
                     media.totalDuration, duration, mid, after, pitch * 100))
    }

    /// Freeze frame at 2 s for 1.5 s: the picture stands still and is silent, then the recording continues.
    private static func freezeTest(_ base: Project) async throws {
        let duration = base.info.duration
        let p = project(base) { $0.freezes = [FreezeFrame(at: 2, duration: 1.5)]; $0.cuts = []; $0.texts = []; $0.trimStart = 0; $0.trimEnd = nil }
        let kept = p.settings.keptSegments(duration: duration)
        let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30, segments: kept)
        let preview = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30)
        let plain = try await plainMedia(base)
        guard abs(media.totalDuration - (duration + 1.5)) < 0.01, abs(preview.totalDuration - (duration + 1.5)) < 0.01 else {
            throw fail("freeze: composition \(media.totalDuration) / preview \(preview.totalDuration)")
        }
        let early = smallPixels(try await frame(media, 2.3)), late = smallPixels(try await frame(media, 3.3))
        let still = diff(early, late)
        let held = diff(early, smallPixels(try await frame(plain, 2.0 - FreezeFrame.span)))
        let after = diff(smallPixels(try await frame(media, 4.0)), smallPixels(try await frame(plain, 2.5)))
        let inPreview = diff(smallPixels(try await frame(preview, 3.0)), early)
        guard still < 0.5, held < 1.5, after < 1.5, inPreview < 1.5 else {
            throw fail(String(format: "freeze frames: still %.2f, held %.2f, after %.2f, preview %.2f", still, held, after, inPreview))
        }
        let mic = try await mixedAudio(media, settings: p.settings, role: "mic")
        let before = rms(mic, 1.0...1.8), during = rms(mic, 2.1...3.4), behind = rms(mic, 3.7...4.8)
        guard before > 0.15, during < 0.01, behind > 0.15 else {
            throw fail(String(format: "freeze sound: %.3f / %.3f / %.3f", before, during, behind))
        }
        print(String(format: "✓ freeze frame: +1.5 s, picture stands still (%.2f), same in the preview, silent, then continues at the right frame (%.2f)",
                     still, after))
    }

    /// "Über Schwarz" is black in the middle, "Schieben" shows the right half of A next to the left half of B.
    private static func transitionStyleTest(_ base: Project) async throws {
        let duration = base.info.duration
        let plain = try await plainMedia(base)
        let a = smallPixels(try await frame(plain, 1.25)), b = smallPixels(try await frame(plain, 2.25))
        func media(_ style: TransitionStyle) async throws -> MediaComposition {
            let p = project(base) { $0.cuts = [CutRange(start: 1.5, end: 2.0, dissolve: 0.5, transition: style)]; $0.texts = []
                $0.trimStart = 0; $0.trimEnd = nil }
            return try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30,
                                               segments: p.settings.keptSegments(duration: duration))
        }
        let dip = smallPixels(try await frame(try await media(.dipToBlack), 1.25))
        let darkness = dip.reduce(0, +) / Double(dip.count)
        let push = smallPixels(try await frame(try await media(.push), 1.25))
        func column(_ px: [Double], _ x: Int) -> [Double] { (0..<90).flatMap { y in (0..<3).map { px[(y * 160 + x) * 3 + $0] } } }
        var leftDiff = 0.0, rightDiff = 0.0
        for x in 4..<76 { leftDiff += diff(column(push, x), column(a, x + 80)) }
        for x in 84..<156 { rightDiff += diff(column(push, x), column(b, x - 80)) }
        leftDiff /= 72; rightDiff /= 72
        guard darkness < 4, leftDiff < 3, rightDiff < 3 else {
            throw fail(String(format: "transition styles: dip brightness %.1f, push %.2f / %.2f", darkness, leftDiff, rightDiff))
        }
        print(String(format: "✓ transition styles: dip to black (brightness %.1f in the middle), push (halves match %.2f / %.2f)",
                     darkness, leftDiff, rightDiff))
    }

    /// 1 s fade from black at the start and to black at the end, picture and sound.
    private static func fadeTest(_ base: Project) async throws {
        let duration = base.info.duration
        let p = project(base) { $0.fadeIn = 1; $0.fadeOut = 1; $0.cuts = []; $0.texts = []; $0.trimStart = 0; $0.trimEnd = nil }
        let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30,
                                                segments: p.settings.keptSegments(duration: duration))
        let plain = try await plainMedia(base)
        func brightness(_ px: [Double]) -> Double { px.reduce(0, +) / Double(px.count) }
        let first = brightness(smallPixels(try await frame(media, 0.0)))
        let last = brightness(smallPixels(try await frame(media, duration - 0.04)))
        let middle = diff(smallPixels(try await frame(media, 2.0)), smallPixels(try await frame(plain, 2.0)))
        let mic = try await mixedAudio(media, settings: p.settings, role: "mic")
        let startLevel = rms(mic, 0.0...0.05), midLevel = rms(mic, 1.5...2.5), endLevel = rms(mic, (duration - 0.05)...duration)
        let half = brightness(smallPixels(try await frame(media, 0.5))), full = brightness(smallPixels(try await frame(plain, 0.5)))
        // Perceived brightness falls evenly: half way through the fade about half as bright.
        guard first < 4, last < 20, middle < 1.5, abs(half / full - 0.5) < 0.12,
              startLevel < 0.03, midLevel > 0.15, endLevel < 0.03 else {
            throw fail(String(format: "fades: picture %.1f/%.2f/%.1f, half way %.0f %%, sound %.3f/%.3f/%.3f", first, middle, last,
                              half / full * 100, startLevel, midLevel, endLevel))
        }
        print(String(format: "✓ fade in/out: starts black (%.1f) and silent, half way %.0f %% as bright, ends dark (%.1f) and silent, middle unchanged",
                     first, half / full * 100, last))
    }

    @MainActor
    private static func speedFreezeModelTest(_ base: Project) throws {
        let p = project(base) { $0.cuts = []; $0.splits = []; $0.texts = []; $0.speeds = []; $0.freezes = []; $0.voiceOvers = []
            $0.trimStart = 0; $0.trimEnd = nil }
        let editor = EditorModel(project: p)
        editor.seek(to: 2.0)
        editor.splitAtPlayhead()
        editor.selection = .segment(0)
        editor.setSpeed(2, for: 0...2.0)
        guard abs(editor.timeMap.total - 3) < 1e-9, editor.speed(of: 0...2.0) == 2, abs(editor.display(2.0) - 1.0) < 1e-9 else {
            throw fail("speed in the editor: total \(editor.timeMap.total)")
        }
        editor.insertFreeze()   // end of the selected part
        guard editor.settings.freezes.count == 1, let freeze = editor.selectedFreeze, abs(freeze.at - 2.0) < 1e-9,
              abs(editor.timeMap.total - 5) < 0.001, abs(editor.outputDuration - editor.timeMap.total) < 1e-9 else {
            throw fail("freeze in the editor: \(editor.settings.freezes), total \(editor.timeMap.total)")
        }
        editor.setFreezeDuration(id: freeze.id, 1.0)
        // Playhead inside the freeze: a source time in its tiny range, output time where it is shown.
        editor.seek(to: editor.sourceTime(1.5))
        guard editor.currentTime > 2.0 - FreezeFrame.span, editor.currentTime < 2.0, abs(editor.outputTime - 1.5) < 1e-6 else {
            throw fail("playhead in the freeze: \(editor.currentTime), output \(editor.outputTime)")
        }
        editor.step(by: 1.0)   // leaves the freeze: 0.5 s after it
        guard abs(editor.currentTime - 2.5) < 0.002 else { throw fail("step over the freeze: \(editor.currentTime)") }
        editor.selection = .freeze(freeze.id)
        editor.deleteSelection()
        guard editor.settings.freezes.isEmpty, abs(editor.timeMap.total - 3) < 1e-9 else { throw fail("delete freeze") }
        editor.undo()
        guard editor.settings.freezes.count == 1 else { throw fail("undo delete freeze") }
        print("✓ editor with speed and freeze: 2× part, freeze at its end, playhead inside the freeze, stepping over it, delete/undo")
    }
}
