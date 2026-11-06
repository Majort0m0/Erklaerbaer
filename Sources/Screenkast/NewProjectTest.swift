import Foundation
import AVFoundation
import CoreImage

/// Selftests for projects without a recording: an own video (also an upright phone video) and an
/// empty canvas where inserted clips line up.
enum NewProjectTest {
    private static func fail(_ m: String) -> NSError {
        NSError(domain: "selftest", code: 96, userInfo: [NSLocalizedDescriptionKey: m])
    }

    static func run(base: Project, dir: URL) async throws {
        let library = dir.appendingPathComponent("new-projects", isDirectory: true)
        try? FileManager.default.removeItem(at: library)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: library) }
        try await ownVideoTest(base, library)
        try await rotatedTest(dir, library)
        try await emptyTest(base, library)
        try helpTest()
    }

    // MARK: Help

    private static func helpTest() throws {
        let topics = HelpContent.topics
        guard topics.count >= 15, Set(topics.map(\.id)).count == topics.count, topics.allSatisfy({ !$0.blocks.isEmpty }) else {
            throw fail("help topics")
        }
        // Search finds the right pages, every inline Markdown text parses.
        guard topics.filter({ $0.matches("Atem") }).contains(where: { $0.id == "sound" }),
              topics.filter({ $0.matches("⌘⇧1") }).contains(where: { $0.id == "screenshots" }),
              topics.filter({ $0.matches("xyzgibtsnicht") }).isEmpty else { throw fail("help search") }
        for topic in topics {
            for block in topic.blocks {
                for text in [block.searchText] where (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) == nil {
                    throw fail("help markdown in \(topic.id): \(text.prefix(40))")
                }
            }
        }
        let md = HelpContent.markdown
        guard topics.allSatisfy({ md.contains("## \($0.title)") }), md.count > 15_000 else { throw fail("help markdown export") }
        print("✓ Erklärbär-Hilfe: \(topics.count) Themen, Suche, \(md.count / 1000) kB Anleitung als Markdown")
    }

    private static func frame(_ project: Project, at t: Double) async throws -> CGImage {
        let media = try await MediaBuilder.make(project: project, renderer: FrameRenderer(project: project), fps: 30,
                                                segments: project.settings.keptSegments(duration: project.info.duration))
        let gen = AVAssetImageGenerator(asset: media.asset)
        gen.videoComposition = media.videoComposition
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        return try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }

    private static func average(_ image: CGImage, _ rect: CGRect) -> (Float, Float, Float) {
        let ci = CIImage(cgImage: image)
        let r = CGRect(x: rect.minX * ci.extent.width, y: rect.minY * ci.extent.height,
                       width: rect.width * ci.extent.width, height: rect.height * ci.extent.height)
        var px = [Float](repeating: 0, count: 4)
        CIContext().render(ci.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)]), toBitmap: &px,
                           rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return (px[0], px[1], px[2])
    }

    // MARK: Own video

    private static func ownVideoTest(_ base: Project, _ library: URL) async throws {
        let p = try await ProjectFactory.importVideo(base.videoURL, into: library)
        let loaded = try Project.load(from: p.url)
        guard loaded.info.pixelWidth == base.info.pixelWidth, abs(loaded.info.duration - base.info.duration) < 0.1,
              loaded.info.hasMicAudio == base.info.hasMicrophone, loaded.settings.padding == 0, loaded.cursor.samples.isEmpty,
              FileManager.default.fileExists(atPath: loaded.videoURL.path) else {
            throw fail("own video: \(loaded.info.pixelWidth)×\(loaded.info.pixelHeight), \(loaded.info.duration) s, padding \(loaded.settings.padding)")
        }
        // The picture fills the frame (no padding, no background around it).
        let size = FrameRenderer(project: loaded).outputSize
        let ratio = Double(size.width / size.height), source = Double(base.info.pixelWidth) / Double(base.info.pixelHeight)
        guard abs(ratio - source) < 0.02 else { throw fail("own video: output \(size) for \(base.info.pixelWidth)×\(base.info.pixelHeight)") }
        print("✓ new project from an own video: copied in as the main track, sound as microphone, full picture without frame")
    }

    // MARK: Upright phone video

    /// 320×180 pixels stored, shown upright (rotated by 90°): top half red, bottom half blue as stored.
    private static func writeRotated(_ url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? fail("writer") }
        writer.startSession(atSourceTime: .zero)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 90, width: 320, height: 90))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 90))
        let image = red.composited(over: blue)
        let ctx = CIContext()
        for i in 0..<20 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { break }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            ctx.render(image, to: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? fail("writer") }
    }

    private static func rotatedTest(_ dir: URL, _ library: URL) async throws {
        let url = dir.appendingPathComponent("upright.mov")
        try await writeRotated(url)
        defer { try? FileManager.default.removeItem(at: url) }
        let p = try await ProjectFactory.importVideo(url, into: library)
        guard p.info.pixelWidth == 180, p.info.pixelHeight == 320, p.info.rotation == 90, p.settings.aspect == .vertical else {
            throw fail("upright video: \(p.info.pixelWidth)×\(p.info.pixelHeight), rotation \(String(describing: p.info.rotation)), \(p.settings.aspect)")
        }
        // Turned upright: the stored top/bottom halves are now left/right.
        let image = try await frame(p, at: 0.5)
        let left = average(image, CGRect(x: 0.1, y: 0.3, width: 0.3, height: 0.4)), right = average(image, CGRect(x: 0.6, y: 0.3, width: 0.3, height: 0.4))
        let top = average(image, CGRect(x: 0.3, y: 0.6, width: 0.4, height: 0.3)), bottom = average(image, CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.3))
        guard image.height > image.width, abs(left.0 - right.0) > 0.5, abs(top.0 - bottom.0) < 0.15 else {
            throw fail("upright video picture: \(image.width)×\(image.height), left \(left), right \(right), top \(top), bottom \(bottom)")
        }
        print("✓ upright phone video: shown in portrait and turned the right way")
    }

    // MARK: Empty project

    private static func emptyTest(_ base: Project, _ library: URL) async throws {
        let p = try await ProjectFactory.empty(length: 10, aspect: .vertical, into: library)
        guard p.info.blank == true, p.info.pixelWidth == 1080, p.info.pixelHeight == 1920, abs(p.info.duration - 10) < 0.05,
              (try await AVURLAsset(url: p.videoURL).load(.duration).seconds) > 9.9 else {
            throw fail("empty project: \(p.info.pixelWidth)×\(p.info.pixelHeight), \(p.info.duration) s")
        }
        let length = min(3, base.info.duration)
        try await MainActor.run {
            let editor = EditorModel(project: p)
            guard let file = editor.importMedia(base.videoURL) else { throw fail("import media") }
            // Two clips, both dropped somewhere into the black: they line up from the start.
            editor.placeInsert(InsertClip(file: file, name: "A", at: 5, duration: length, fileDuration: base.info.duration))
            editor.placeInsert(InsertClip(file: file, name: "B", at: 7, duration: length, fileDuration: base.info.duration))
            let ats = editor.settings.inserts.map(\.at)
            let total = editor.settings.outputDuration(duration: editor.duration)
            guard ats.count == 2, ats[1] > ats[0], ats[1] - ats[0] < 0.01, abs(total - 2 * length) < 0.05 else {
                throw fail("empty project clips: at \(ats), length \(total) for 2 × \(length)")
            }
            // A text inside clip B moves with it when a clip is put between A and B.
            guard let b = editor.settings.inserts.last else { throw fail("no clip B") }
            editor.settings.texts = [TextOverlay(kind: .lowerThird, start: b.at - FreezeFrame.span / 2, end: b.at, title: "B")]
            editor.placeInsert(InsertClip(file: file, name: "C", at: editor.settings.inserts[0].at - FreezeFrame.span / 2,
                                          duration: 1, fileDuration: base.info.duration))
            // And one in front of the row.
            editor.placeInsert(InsertClip(file: file, name: "D", at: 0, duration: 1, fileDuration: base.info.duration))
            let order = editor.settings.inserts.sorted { $0.at < $1.at }.map(\.name)
            let movedB = editor.settings.inserts.first { $0.name == "B" }!
            guard order == ["D", "A", "C", "B"], movedB.sourceRange.contains(editor.settings.texts[0].start),
                  abs(editor.settings.outputDuration(duration: editor.duration) - (2 * length + 2)) < 0.05 else {
                throw fail("empty project order: \(order), text at \(editor.settings.texts[0].start) for B \(movedB.sourceRange)")
            }
            editor.settings.texts = []
            editor.saveNow()
        }
        let loaded = try Project.load(from: p.url)
        let media = try await MediaBuilder.make(project: loaded, renderer: FrameRenderer(project: loaded), fps: 30,
                                                segments: loaded.settings.keptSegments(duration: loaded.info.duration))
        guard abs(media.totalDuration - (2 * length + 2)) < 0.03 else { throw fail("empty project composition: \(media.totalDuration)") }
        // No black frame at the start, at the end or where one clip follows the next.
        let gen = AVAssetImageGenerator(asset: media.asset)
        gen.videoComposition = media.videoComposition
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        var times: [Double] = [0, media.totalDuration - 0.02]
        for edge in [1.0, 1.0 + length, 2.0 + length] { times += [edge - 0.01, edge + 0.005, edge + 0.017] }
        for t in times {
            let image = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 6000)).image
            let c = average(image, CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9))
            guard c.0 + c.1 + c.2 > 0.05 else { throw fail(String(format: "empty project: black frame at %.3f s", t)) }
        }
        print(String(format: "✓ empty project: black %d×%d canvas, clips line up one after another (%.1f s), the black rest is cut off", 1080, 1920, media.totalDuration))
    }
}
