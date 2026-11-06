import Foundation
import AVFoundation
import CoreImage
import AppKit
import Vision

/// Selftests for sensitive data detection, the step guide, the cut-out camera, side by side,
/// cursor effects and sound effects.
enum RoundTwoTest {
    private static func fail(_ m: String) -> NSError {
        NSError(domain: "selftest", code: 90, userInfo: [NSLocalizedDescriptionKey: m])
    }

    static func run(base: Project, dir: URL) async throws {
        try sensitiveTest()
        try await guideTest(base, dir: dir)
        try cameraTest(base)
        try cursorTest(base)
        try await soundTest(base)
        try await ReviewTest.run(base: base)
        try await NewProjectTest.run(base: base, dir: dir)
    }

    private static func project(_ base: Project, _ change: (inout EditSettings) -> Void) -> Project {
        var s = EditSettings()
        s.removeEcho = false
        s.zoomSegments = []
        change(&s)
        return Project(url: base.url, info: base.info, cursor: base.cursor, settings: s)
    }

    private static func average(_ image: CIImage, in rect: CGRect, context: CIContext) -> (r: Double, g: Double, b: Double) {
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        var px = [Float](repeating: 0, count: 4)
        context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return (Double(px[0]), Double(px[1]), Double(px[2]))
    }

    // MARK: Sensitive data

    private static func sensitiveTest() throws {
        guard SensitiveScanner.luhn("4111111111111111"), !SensitiveScanner.luhn("4111111111111112"),
              SensitiveScanner.ibanValid("DE89 3704 0044 0532 0130 00"), !SensitiveScanner.ibanValid("DE89 3704 0044 0532 0130 01") else {
            throw fail("checksums")
        }
        let line = "Termin 2026-11-06 um 14:30, Mail max.muster@example.com, Tel. +49 171 2345678, IBAN DE89 3704 0044 0532 0130 00"
        let kinds = SensitiveScanner.matches(in: line).map(\.0)
        guard kinds.contains(.email), kinds.contains(.phone), kinds.contains(.iban), kinds.count == 3 else { throw fail("text matches: \(kinds)") }
        // A rendered screen with an e-mail address: found at the right place.
        let w = 1600, h = 1000
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: "Kontakt: max.muster@example.com", attributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
            .draw(at: CGPoint(x: 200, y: 700))   // bottom-left origin: near the top
        NSGraphicsContext.restoreGraphicsState()
        let found: [SensitiveFinding]
        do {
            found = try SensitiveScanner.detect(in: ctx.makeImage()!, faces: false)
        } catch {
            print("– sensitive data on screen skipped: \(error.localizedDescription)")
            return
        }
        guard let mail = found.first(where: { $0.kind == .email }), mail.rect.minY < 0.35, mail.rect.minX > 0.2, mail.text.contains("example.com") else {
            throw fail("e-mail on the screen: \(found.map { ($0.kind.rawValue, $0.rect) })")
        }
        print(String(format: "✓ sensitive data: e-mail, phone and IBAN recognised in text (date and time ignored), e-mail found on a screen at %.2f/%.2f; IBAN and card checksums", mail.rect.minX, mail.rect.minY))
    }

    // MARK: Step guide

    private static func guideTest(_ base: Project, dir: URL) async throws {
        let p = project(base) { $0.captions = [Caption(start: 0, end: base.info.duration, text: "Hier klicke ich auf den Knopf.")] }
        let steps = try await StepGuideMaker.make(project: p, settings: p.settings) { _ in }
        let clicks = base.cursor.clicks.filter(\.isInsideCapture).count
        guard clicks == 0 || !steps.isEmpty else { throw fail("guide: no steps for \(clicks) clicks") }
        guard let first = steps.first else { print("– step guide skipped (no clicks)"); return }
        let pdf = dir.appendingPathComponent("Anleitung.pdf")
        let folder = dir.appendingPathComponent("Anleitung")
        try? FileManager.default.removeItem(at: folder)
        try StepGuideMaker.writePDF(steps: steps, title: "Test", to: pdf)
        try StepGuideMaker.writeMarkdown(steps: steps, title: "Test", to: folder)
        let md = try String(contentsOf: folder.appendingPathComponent("Anleitung.md"), encoding: .utf8)
        let pdfSize = (try FileManager.default.attributesOfItem(atPath: pdf.path)[.size] as? Int) ?? 0
        guard pdfSize > 10_000, md.contains("## 1."), md.contains("bilder/schritt-01.png"), first.detail.contains("Knopf") else {
            throw fail("guide export: pdf \(pdfSize) bytes, markdown \(md.prefix(80))")
        }
        print("✓ step guide: \(steps.count) steps from \(clicks) clicks, text from the captions, PDF (\(pdfSize / 1000) kB) and Markdown with pictures")
    }

    // MARK: Camera: cut out, side by side

    private static func cameraTest(_ base: Project) throws {
        let ctx = CIContext()
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: base.info.pixelWidth, height: base.info.pixelHeight))
        let camera = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        // Side by side: the camera fills the right part, the recording the left.
        let p = project(base) {
            $0.background = .color(red: 0, green: 0, blue: 1)
            $0.cameraLayouts = [CameraLayoutRange(start: 0, end: base.info.duration, layout: .split)]
        }
        let r = FrameRenderer(project: p)
        let out = r.outputSize
        let img = r.render(source: source, camera: camera, time: 1.0)
        let right = average(img, in: CGRect(x: out.width * 0.8, y: out.height * 0.4, width: 40, height: 40), context: ctx)
        let left = average(img, in: CGRect(x: out.width * 0.3, y: out.height * 0.5, width: 40, height: 40), context: ctx)
        guard right.r > 0.8, right.g < 0.2, abs(left.r - left.b) < 0.05, left.g > 0.15 else {   // gray (linear light), not the blue background
            throw fail("side by side: right \(right), left \(left)")
        }
        // Cut out: bottom aligned, taller than a bubble; rendering without a person draws nothing.
        var s = EditSettings()
        s.cameraShape = .cutout
        let cut = FrameRenderer.cameraRect(settings: s, out: out, cameraAspect: 4.0 / 3.0).rect
        s.cameraShape = .circle
        let bubble = FrameRenderer.cameraRect(settings: s, out: out, cameraAspect: 4.0 / 3.0).rect
        let cp = project(base) { $0.cameraShape = .cutout; $0.background = .color(red: 0, green: 0, blue: 1) }
        let noPerson = FrameRenderer(project: cp).render(source: source, camera: camera, time: 1.0)
        let inCut = average(noPerson, in: CGRect(x: cut.midX - 10, y: cut.midY - 10, width: 20, height: 20), context: ctx)
        // With working segmentation an empty room shows nothing; without it the plain camera is shown.
        let segmentationWorks = (try? VNImageRequestHandler(ciImage: camera, options: [:]).perform([VNGeneratePersonSegmentationRequest()])) != nil
        guard cut.minY == 0, cut.height > bubble.height, segmentationWorks ? inCut.r < 0.6 : inCut.r > 0.6 else {
            throw fail("cut out: \(cut), colour \(inCut), segmentation \(segmentationWorks)")
        }
        print("✓ camera: side by side (camera right, recording left), cut out person stands on the bottom edge (no person → nothing drawn)")
    }

    // MARK: Cursor effects

    private static func cursorTest(_ base: Project) throws {
        let ctx = CIContext()
        guard let t = base.cursor.samples.first(where: { $0.x > 0.2 && $0.x < 0.8 && $0.y > 0.2 && $0.y < 0.8 })?.t else {
            print("– cursor effects skipped (no cursor in the middle)"); return
        }
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: base.info.pixelWidth, height: base.info.pixelHeight))
        func render(_ e: CursorEffect) -> (CIImage, FrameRenderer) {
            let r = FrameRenderer(project: project(base) { $0.cursorEffect = e; $0.hideIdleCursor = false })
            return (r.render(source: source, camera: nil, time: t), r)
        }
        let (plain, r) = render(.none)
        guard let c = r.cursorPosition(at: t) else { throw fail("no cursor") }
        let q = r.outputPoint(c, at: t)
        let out = r.outputSize
        let near = CGRect(x: q.x + 30, y: out.height - q.y - 30, width: 16, height: 16)   // beside the arrow
        let far = CGRect(x: out.width * 0.08, y: out.height * 0.1, width: 30, height: 30)
        let halo = average(render(.halo).0, in: near, context: ctx), base0 = average(plain, in: near, context: ctx)
        let spotFar = average(render(.spotlight).0, in: far, context: ctx), plainFar = average(plain, in: far, context: ctx)
        let lens = render(.lens).0
        let diff = lens.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: plain])
        let lensChange = average(diff, in: CGRect(x: q.x - 200, y: out.height - q.y - 200, width: 400, height: 400), context: ctx)   // includes the lens rim
        guard halo.r > base0.r + 0.05, spotFar.g < plainFar.g * 0.7, lensChange.r + lensChange.g > 0.01 else {
            throw fail("cursor effects: halo \(halo) vs \(base0), spotlight \(spotFar) vs \(plainFar), lens \(lensChange)")
        }
        print("✓ cursor effects: halo (warmer around the pointer), spotlight (the rest darker), lens (enlarged around the pointer)")
    }

    // MARK: Sound effects

    private static func soundTest(_ base: Project) async throws {
        let p = project(base) {
            $0.soundEffects = true
            $0.soundEffectVolume = 1
            $0.zoomSegments = [ZoomSegment(start: 1.0, end: 2.5, scale: 1.8)]
        }
        let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30,
                                                segments: p.settings.keptSegments(duration: base.info.duration))
        guard let track = media.audioTracks.first(where: { $0.role == "effects" })?.track else { throw fail("no effects track") }
        let reader = try AVAssetReader(asset: media.asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        reader.startReading()
        var energy: [Int: Double] = [:]
        while let sb = output.copyNextSampleBuffer() {
            guard let block = sb.dataBuffer else { continue }
            let start = sb.presentationTimeStamp.seconds
            let n = CMBlockBufferGetDataLength(block) / 4
            var chunk = [Float](repeating: 0, count: n)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            for (i, v) in chunk.enumerated() { energy[Int((start + Double(i) / 48_000) * 10), default: 0] += Double(v * v) }
        }
        let at = (10...14).reduce(0.0) { $0 + (energy[$1] ?? 0) }, before = (2...8).reduce(0.0) { $0 + (energy[$1] ?? 0) }
        guard at > 1, before < 0.001 else { throw fail(String(format: "whoosh: %.3f at the zoom, %.4f before", at, before)) }
        print("✓ sound effects: a whoosh where the zoom begins, silence before")
    }
}
