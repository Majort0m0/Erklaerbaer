import Foundation
import AVFoundation
import AppKit
import Vision

/// One step of a written guide: a click in the recording with a picture and text.
struct GuideStep: Identifiable {
    var id = UUID()
    /// Source time of the click.
    var time: Double
    /// Click position, normalized to the captured area (origin top-left).
    var point: CGPoint
    /// The screen right before the click, with the step number at the click.
    var image: CGImage
    var title: String
    var detail: String
}

/// Turns the clicks of a recording into a step-by-step guide (on the Mac: text recognition finds
/// what was clicked, the captions what was said about it).
enum StepGuideMaker {
    static func make(project: Project, settings: EditSettings, progress: @escaping @Sendable (Double) -> Void) async throws -> [GuideStep] {
        let kept = settings.keptSegments(duration: project.info.duration)
        var clicks: [ClickEvent] = []
        for c in project.cursor.clicks.sorted(by: { $0.t < $1.t }) where c.isInsideCapture {
            guard kept.contains(where: { $0.contains(c.t) }) else { continue }
            if let last = clicks.last, c.t - last.t < 0.8 { continue }   // double clicks count once
            clicks.append(c)
        }
        let asset = AVURLAsset(url: project.videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        gen.maximumSize = CGSize(width: 2400, height: 2400)
        var steps: [GuideStep] = []
        for (i, c) in clicks.enumerated() {
            if Task.isCancelled { break }
            guard let frame = try? await gen.image(at: CMTime(seconds: max(0, c.t - 0.08), preferredTimescale: 600)).image else { continue }
            let point = CGPoint(x: c.x, y: c.y)
            let label = clickedText(in: frame, at: point)
            let said = settings.captions.first { $0.start <= c.t + 0.3 && $0.end >= c.t - 0.3 }
                ?? settings.captions.first { $0.start > c.t && $0.start - c.t < 2 }
            steps.append(GuideStep(time: c.t, point: point, image: marked(frame, at: point, number: i + 1),
                                   title: label.map { "Klicke auf „\($0)“" } ?? "Klicke an die markierte Stelle",
                                   detail: said?.text ?? ""))
            progress(Double(i + 1) / Double(max(1, clicks.count)))
        }
        return steps
    }

    /// The text right under (or nearest to) the click.
    static func clickedText(in image: CGImage, at p: CGPoint) -> String? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let box = CGRect(x: p.x * w - 0.12 * w, y: p.y * h - 0.04 * h, width: 0.24 * w, height: 0.08 * h)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard box.width > 8, box.height > 8, let crop = image.cropping(to: box) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
        // Click position inside the crop (Vision: normalized, origin bottom-left).
        let local = CGPoint(x: (p.x * w - box.minX) / box.width, y: 1 - (p.y * h - box.minY) / box.height)
        let best = (request.results ?? []).compactMap { o -> (String, CGFloat)? in
            guard let s = o.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces), s.count >= 2 else { return nil }
            let r = o.boundingBox
            let dx = max(r.minX - local.x, 0, local.x - r.maxX), dy = max(r.minY - local.y, 0, local.y - r.maxY)
            return (s, hypot(dx, dy * 0.4))
        }.min { $0.1 < $1.1 }
        guard let best, best.1 < 0.25 else { return nil }
        return String(best.0.prefix(60))
    }

    /// The frame with a numbered marker at the click.
    static func marked(_ image: CGImage, at p: CGPoint, number: Int) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let unit = CGFloat(max(w, h)) / 120
        let c = CGPoint(x: p.x * CGFloat(w), y: (1 - p.y) * CGFloat(h))
        ctx.setStrokeColor(CGColor(srgbRed: 0.96, green: 0.23, blue: 0.2, alpha: 0.9))
        ctx.setLineWidth(unit * 0.5)
        ctx.strokeEllipse(in: CGRect(x: c.x - unit * 2.2, y: c.y - unit * 2.2, width: unit * 4.4, height: unit * 4.4))
        // Number badge up and to the right of the click.
        let badge = CGRect(x: c.x + unit * 1.6, y: c.y + unit * 1.6, width: unit * 3.2, height: unit * 3.2)
        ctx.setShadow(offset: CGSize(width: 0, height: -unit * 0.2), blur: unit * 0.8, color: CGColor(gray: 0, alpha: 0.4))
        ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.23, blue: 0.2, alpha: 1))
        ctx.fillEllipse(in: badge)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        let text = NSAttributedString(string: "\(number)", attributes: [.font: NSFont.systemFont(ofSize: unit * 1.9, weight: .heavy),
                                                                        .foregroundColor: NSColor.white])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let size = text.size()
        text.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage() ?? image
    }

    // MARK: Export

    static func png(_ image: CGImage, maxWidth: Int = 1600) -> Data? {
        let scale = min(1, CGFloat(maxWidth) / CGFloat(image.width))
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:])
    }

    /// A folder with "Anleitung.md" and one picture per step.
    static func writeMarkdown(steps: [GuideStep], title: String, to folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("bilder"), withIntermediateDirectories: true)
        var md = "# \(title)\n\n"
        for (i, s) in steps.enumerated() {
            let name = String(format: "schritt-%02d.png", i + 1)
            try png(s.image)?.write(to: folder.appendingPathComponent("bilder").appendingPathComponent(name))
            md += "## \(i + 1). \(s.title)\n\n"
            if !s.detail.isEmpty { md += "\(s.detail)\n\n" }
            md += "![Schritt \(i + 1)](bilder/\(name))\n\n"
        }
        try md.write(to: folder.appendingPathComponent("Anleitung.md"), atomically: true, encoding: .utf8)
    }

    /// The steps as plain text (for the clipboard).
    static func text(steps: [GuideStep], title: String) -> String {
        ([title, ""] + steps.enumerated().map { i, s in "\(i + 1). \(s.title)" + (s.detail.isEmpty ? "" : "\n   \(s.detail)") })
            .joined(separator: "\n")
    }

    /// A4 PDF: title, then each step with its text and picture.
    static func writePDF(steps: [GuideStep], title: String, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw RecorderError.writerFailed("PDF") }
        let margin: CGFloat = 48, width = box.width - 2 * margin
        var y: CGFloat = 0   // from the top of the page
        var open = false
        func newPage() {
            if open { ctx.endPDFPage() }
            ctx.beginPDFPage(nil)
            open = true
            y = margin
        }
        func draw(_ text: NSAttributedString) {
            let size = text.boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin]).size
            if y + size.height > box.height - margin { newPage() }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            text.draw(with: CGRect(x: margin, y: box.height - y - ceil(size.height), width: width, height: ceil(size.height)),
                      options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
            y += ceil(size.height) + 8
        }
        newPage()
        draw(NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .bold)]))
        y += 6
        for (i, s) in steps.enumerated() {
            let imageHeight = width * CGFloat(s.image.height) / CGFloat(max(1, s.image.width))
            if y + 60 + imageHeight > box.height - margin { newPage() }
            draw(NSAttributedString(string: "\(i + 1). \(s.title)", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)]))
            if !s.detail.isEmpty {
                draw(NSAttributedString(string: s.detail, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.darkGray]))
            }
            let rect = CGRect(x: margin, y: box.height - y - imageHeight, width: width, height: imageHeight)
            ctx.interpolationQuality = .high
            ctx.draw(s.image, in: rect)
            ctx.setStrokeColor(CGColor(gray: 0.8, alpha: 1))
            ctx.stroke(rect)
            y += imageHeight + 22
        }
        if open { ctx.endPDFPage() }
        ctx.closePDF()
    }
}
