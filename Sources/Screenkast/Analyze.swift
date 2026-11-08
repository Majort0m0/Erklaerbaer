import Foundation
import AVFoundation
import CoreImage

/// `Screenkast --analyze <project.screenkast>`: measures camera smoothness and render speed
/// of a real project (diagnostics for stuttering zooms).
enum Analyze {
    static func run(projectPath: String) -> Int32 {
        do {
            let project = try Project.load(from: URL(fileURLWithPath: projectPath))
            cameraReport(project)
            benchmark(project)
            return 0
        } catch {
            print("ANALYZE FAILED: \(error)")
            return 1
        }
    }

    /// Frame-to-frame movement of the visible area at 60 fps. A smooth camera changes
    /// speed gradually; a jump shows up as one frame moving far more than its neighbours.
    static func cameraReport(_ project: Project) {
        let s = project.settings
        let out = FrameRenderer.outputSize(info: project.info, settings: s)
        let layout = FrameLayout(out: out, sourceSize: CGSize(width: project.info.pixelWidth, height: project.info.pixelHeight),
                                 padding: s.padding)
        let motion = MotionPaths(track: project.cursor, duration: project.info.duration, smoothing: s.cursorSmoothing)
        let fps = 60.0
        var prev: CGPoint?
        var prevDelta = 0.0
        var deltas: [(t: Double, d: Double, jerk: Double, z: Double)] = []
        // Track where the four corners of the recording land: covers pan and zoom together.
        let probe = [CGPoint(x: layout.content.minX, y: layout.content.minY), CGPoint(x: layout.content.maxX, y: layout.content.maxY)]
        var t = 0.0
        while t <= project.info.duration {
            let cam = FrameRenderer.camera(at: t, layout: layout, segments: s.zoomSegments, motion: motion)
            let p = probe[0].applying(cam.transform), q = probe[1].applying(cam.transform)
            let mid = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
            if let prev {
                let d = hypot(mid.x - prev.x, mid.y - prev.y)
                deltas.append((t, d, abs(d - prevDelta), Double(cam.zoom)))
                prevDelta = d
            }
            prev = mid
            t += 1 / fps
        }
        let sortedJerk = deltas.sorted { $0.jerk > $1.jerk }
        let median = deltas.map(\.jerk).sorted()[deltas.count / 2]
        print("Kamera (\(Int(out.width))×\(Int(out.height))), Bewegung pro Frame in px:")
        print(String(format: "  max Bewegung %.1f px, Median Ruck %.2f px", deltas.map(\.d).max() ?? 0, median))
        print("  Größte Sprünge (Änderung der Geschwindigkeit von einem Frame zum nächsten):")
        for j in sortedJerk.prefix(6) {
            print(String(format: "    t=%6.2fs  Ruck %7.1f px  Bewegung %6.1f px  Zoom %.2f×", j.t, j.jerk, j.d, j.z))
        }
    }

    /// Render time per frame with the real frame size (as AVFoundation does it, into a pixel buffer).
    static func benchmark(_ project: Project) {
        let renderer = FrameRenderer(project: project)
        let asset = AVURLAsset(url: project.videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        let sem = DispatchSemaphore(value: 0)
        var frame: CGImage?
        gen.generateCGImageAsynchronously(for: CMTime(seconds: min(2, project.info.duration / 2), preferredTimescale: 600)) { img, _, _ in
            frame = img
            sem.signal()
        }
        sem.wait()
        guard let frame else { print("Kein Frame lesbar"); return }
        let source = CIImage(cgImage: frame)
        let size = renderer.outputSize
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let ctx = CIContext()
        let seg = project.settings.zoomSegments.first
        let t0 = seg?.start ?? 0
        // Warm-up
        for i in 0..<5 { ctx.render(renderer.render(source: source, time: t0 + Double(i) / 60), to: pb!) }
        let n = 120
        let start = Date()
        for i in 0..<n {
            ctx.render(renderer.render(source: source, time: t0 + Double(i) / 60), to: pb!)
        }
        CVPixelBufferLockBaseAddress(pb!, .readOnly)   // wait for GPU
        CVPixelBufferUnlockBaseAddress(pb!, .readOnly)
        let ms = Date().timeIntervalSince(start) * 1000 / Double(n)
        print(String(format: "Rendern: %.1f ms pro Frame bei %d×%d (Budget bei 60 fps: 16,7 ms)", ms, Int(size.width), Int(size.height)))
    }
}

extension Analyze {
    /// `Screenkast --echo <project> <output.caf>`: runs the echo removal without touching the project.
    static func echo(projectPath: String, outputPath: String) -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            do {
                let project = try Project.load(from: URL(fileURLWithPath: projectPath))
                let start = Date()
                let stats = try await EchoCanceller.process(project: project, outputURL: URL(fileURLWithPath: outputPath))
                print(String(format: "Echo: Verzögerung %.1f ms, linear −%.1f dB, gesamt −%.1f dB (%.1f s)",
                             stats.delayMs, stats.linearReductionDB, stats.totalReductionDB, Date().timeIntervalSince(start)))
            } catch {
                print("ECHO FAILED: \(error)")
                code = 1
            }
            sem.signal()
        }
        sem.wait()
        return code
    }
}

extension Analyze {
    /// `Screenkast --export <project> <output.mp4>`: full pipeline without UI (echo removal, composition, export).
    static func export(projectPath: String, outputPath: String) -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            do {
                let project = try Project.load(from: URL(fileURLWithPath: projectPath))
                let s = project.settings
                if project.info.hasMicAudio && project.info.hasSystemAudio && s.removeEcho
                    && !FileManager.default.fileExists(atPath: EchoCanceller.cleanURL(for: project).path) {
                    let stats = try await EchoCanceller.process(project: project)
                    print(String(format: "Echo entfernt: −%.1f dB", stats.totalReductionDB))
                }
                let renderer = FrameRenderer(project: project)
                let kept = s.keptSegments(duration: project.info.duration)
                let media = try await MediaBuilder.make(project: project, renderer: renderer, fps: s.exportFPS, segments: kept)
                for track in media.asset.tracks {
                    let filled = try await track.load(.segments).filter { !$0.isEmpty }.count
                    let entry = media.audioTracks.first { $0.track.trackID == track.trackID }
                    let role = entry.map { $0.role + ($0.isDissolveB ? " B" : "") + ($0.layer.map { " Ebene \($0 + 1)" } ?? "") }
                        ?? [MediaBuilder.cameraTrackID: "camera", MediaBuilder.screenBTrackID: "screen B", MediaBuilder.cameraBTrackID: "camera B"][track.trackID] ?? "screen"
                    print("Spur \(track.trackID) \(track.mediaType.rawValue) [\(role)]: \(filled) Segment(e)")
                }
                guard let session = AVAssetExportSession(asset: media.asset, presetName: s.exportHEVC ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality) else {
                    throw RecorderError.writerFailed("Export")
                }
                session.videoComposition = media.videoComposition
                session.audioMix = media.audioMix(settings: s)
                session.audioTimePitchAlgorithm = .spectral
                let url = URL(fileURLWithPath: outputPath)
                try? FileManager.default.removeItem(at: url)
                let start = Date()
                try await session.export(to: url, as: .mp4)
                print(String(format: "Export fertig in %.1f s → %@", Date().timeIntervalSince(start), outputPath))
            } catch {
                print("EXPORT FAILED: \(error)")
                code = 1
            }
            sem.signal()
        }
        sem.wait()
        return code
    }

    /// `--voice <project>`: voice enhancement of microphone and voice-overs (writes the processed
    /// files into the project, as the editor would) and prints loudness before/after.
    static func voice(projectPath: String) -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            do {
                let project = try Project.load(from: URL(fileURLWithPath: projectPath))
                var settings = project.settings
                settings.voice.enabled = true
                for file in Set(settings.voiceOvers.map(\.file)) {
                    let samples = try await VoiceProcessor.readFile(project.url.appendingPathComponent(file))
                    let (_, r) = VoiceProcessor.enhance(samples, settings: settings.voice)
                    print(String(format: "%@: %.1f → %.1f LUFS, Rauschen −%.1f dB", file, r.loudnessBefore, r.loudnessAfter, r.noiseReductionDB))
                }
                let start = Date()
                let r = try await VoiceProcessor.process(project: project, settings: settings)
                print(String(format: "Mikrofon: %@ (%.1f s)", r.map { String(format: "%.1f → %.1f LUFS, Rauschen −%.1f dB", $0.loudnessBefore, $0.loudnessAfter, $0.noiseReductionDB) } ?? "–",
                             Date().timeIntervalSince(start)))
            } catch {
                print("Fehler: \(error.localizedDescription)")
                code = 1
            }
            sem.signal()
        }
        sem.wait()
        return code
    }

    /// `--mockups <project> <folder>`: a picture of the project in every scene, landscape and portrait.
    static func mockups(projectPath: String, outputFolder: String) -> Int32 {
        do {
            let base = try Project.load(from: URL(fileURLWithPath: projectPath))
            let folder = URL(fileURLWithPath: outputFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: base.videoURL))
            gen.appliesPreferredTrackTransform = true
            var frame: CGImage?
            let sem = DispatchSemaphore(value: 0)
            gen.generateCGImageAsynchronously(for: CMTime(seconds: min(5, base.info.duration / 2), preferredTimescale: 600)) { img, _, _ in
                frame = img
                sem.signal()
            }
            sem.wait()
            guard let frame else { return 1 }
            let context = CIContext()
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            for kind in MockupKind.allCases {
                for aspect in [OutputAspect.wide, .vertical] {
                    var s = base.settings
                    s.mockup = kind
                    s.aspect = aspect
                    s.exportShortSide = 720
                    s.zoomSegments = []
                    s.texts = []
                    let p = Project(url: base.url, info: base.info, cursor: base.cursor, settings: s)
                    let r = FrameRenderer(project: p)
                    let image = r.render(source: CIImage(cgImage: frame), camera: nil, time: min(5, base.info.duration / 2))
                    let url = folder.appendingPathComponent("\(kind.rawValue)-\(aspect == .wide ? "quer" : "hoch").png")
                    try context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: space)
                }
            }
            print("Szenen → \(outputFolder)")
            return 0
        } catch {
            print("Fehler: \(error)")
            return 1
        }
    }

    /// `--breaths <project> [<output.caf>]`: finds breath sounds in the microphone (echo-free when
    /// available) and lists them; with an output file, writes the track with breaths lowered by 18 dB.
    static func breaths(projectPath: String, outputPath: String?) -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            do {
                let project = try Project.load(from: URL(fileURLWithPath: projectPath))
                let clean = EchoCanceller.cleanURL(for: project)
                var x: [Float]
                if FileManager.default.fileExists(atPath: clean.path) {
                    x = try await VoiceProcessor.readFile(clean)
                } else {
                    let asset = AVURLAsset(url: project.videoURL)
                    let tracks = try await asset.loadTracks(withMediaType: .audio)
                    let roles = await AudioRole.roles(of: tracks, fallback: project.info.audioRoles)
                    guard let i = roles.firstIndex(of: "mic") else { print("Kein Mikrofon"); code = 1; sem.signal(); return }
                    x = try await EchoCanceller.readMono(track: tracks[i], asset: asset, duration: try await asset.load(.duration).seconds)
                }
                VoiceProcessor.highPass(&x, cutoff: 80)
                x = VoiceProcessor.denoise(x, strength: 0.6)
                print(String(format: "Sprache erkannt: %@, Lautheit %.1f LUFS", VoiceProcessor.hasSpeech(x) ? "ja" : "nein", VoiceProcessor.loudness(x)))
                for sensitivity in [0.0, 0.5, 1.0] {
                    let found = VoiceProcessor.breaths(x, sensitivity: sensitivity)
                    print(String(format: "Empfindlichkeit %.1f: %d Atemgeräusche", sensitivity, found.count)
                          + (found.isEmpty ? "" : " – " + found.map { String(format: "%.2f–%.2f", $0.lowerBound, $0.upperBound) }.joined(separator: ", ")))
                }
                // Check against speech recognition: a breath must not lie on a recognized word.
                if #available(macOS 26.0, *) {
                    let temp = project.url.appendingPathComponent(".breaths-check.caf")
                    try EchoCanceller.writeCAF(x, to: temp)
                    defer { try? FileManager.default.removeItem(at: temp) }
                    let words = try await CaptionGenerator.transcribe(url: temp, localeID: project.settings.captionLanguage) { _ in }
                    print("Erkannte Wörter: \(words.count) – " + words.map { String(format: "%.2f %@", $0.start, $0.text.trimmingCharacters(in: .whitespaces)) }.joined(separator: " | "))
                    for sensitivity in [0.0, 0.5, 1.0] {
                        let found = VoiceProcessor.breaths(x, sensitivity: sensitivity)
                        let onWords = found.filter { r in
                            let covered = words.reduce(0.0) { $0 + max(0, min(r.upperBound, $1.end) - max(r.lowerBound, $1.start)) }
                            return covered > 0.3 * (r.upperBound - r.lowerBound)
                        }
                        print(String(format: "Empfindlichkeit %.1f: %d von %d Treffern liegen auf Wörtern", sensitivity, onWords.count, found.count)
                              + (onWords.isEmpty ? "" : " – " + onWords.map { String(format: "%.2f–%.2f", $0.lowerBound, $0.upperBound) }.joined(separator: ", ")))
                    }
                }
                if let outputPath {
                    var y = x
                    VoiceProcessor.reduce(&y, ranges: VoiceProcessor.breaths(x, sensitivity: 0.5), byDB: 18)
                    try EchoCanceller.writeCAF(y, to: URL(fileURLWithPath: outputPath))
                }
            } catch {
                print("Fehler: \(error.localizedDescription)")
                code = 1
            }
            sem.signal()
        }
        sem.wait()
        return code
    }
}

