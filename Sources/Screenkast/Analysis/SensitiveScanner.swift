import Foundation
import AVFoundation
import Vision

/// macOS's image recognition failed (it sometimes needs a restart of the Mac).
struct RecognitionUnavailable: LocalizedError {
    let underlying: Error
    var errorDescription: String? {
        "Die Text- und Bilderkennung von macOS ist gerade nicht verfügbar – ein Neustart des Macs hilft meist. (\(underlying.localizedDescription))"
    }
}

/// Something worth hiding that was found on the screen recording.
struct SensitiveFinding: Identifiable, Equatable {
    enum Kind: String {
        case email, phone, iban, card, secret, face
        var label: String {
            switch self {
            case .email: return "E-Mail-Adresse"
            case .phone: return "Telefonnummer"
            case .iban: return "IBAN"
            case .card: return "Kartennummer"
            case .secret: return "Schlüssel/Token"
            case .face: return "Gesicht"
            }
        }
    }
    var id = UUID()
    var kind: Kind
    var text: String
    /// Normalized to the captured area, origin top-left.
    var rect: CGRect
    var start: Double
    var end: Double
    var selected = true

    /// The text with most of it hidden (the list must not show it in full).
    var hint: String {
        guard kind != .face, text.count > 4 else { return text.isEmpty ? kind.label : "••••" }
        return String(text.prefix(2)) + String(repeating: "•", count: min(8, text.count - 4)) + String(text.suffix(2))
    }
}

/// Looks through the screen recording (on the Mac, with Apple's text and face recognition) for
/// e-mail addresses, phone numbers, IBANs, card numbers, API keys and faces.
enum SensitiveScanner {
    static func scan(project: Project, faces: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> [SensitiveFinding] {
        let asset = AVURLAsset(url: project.videoURL)
        let duration = try await asset.load(.duration).seconds
        let step = max(1.0, duration / 300)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
        gen.maximumSize = CGSize(width: 2400, height: 2400)
        var findings: [SensitiveFinding] = []
        var t = 0.0
        while t < duration {
            if Task.isCancelled { break }
            if let image = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                let found = try detect(in: image, faces: faces)
                for f in found { merge(f, at: t, step: step, into: &findings) }
            }
            progress(min(1, t / max(0.1, duration)))
            t += step
        }
        // A finding stays hidden from half a step before to half a step after it was seen.
        return findings.map { var f = $0; f.start = max(0, f.start - step / 2); f.end = min(duration, f.end + step / 2); return f }
    }

    /// Findings in one frame (rects normalized, origin top-left), slightly enlarged.
    static func detect(in image: CGImage, faces: Bool) throws -> [SensitiveFinding] {
        var out: [SensitiveFinding] = []
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        text.recognitionLanguages = ["de-DE", "en-US"]
        var requests: [VNRequest] = [text]
        let face = VNDetectFaceRectanglesRequest()
        if faces { requests.append(face) }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform(requests)
        } catch {
            throw RecognitionUnavailable(underlying: error)
        }
        for observation in text.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            for (kind, range) in matches(in: string) {
                guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
                out.append(SensitiveFinding(kind: kind, text: String(string[range]), rect: topLeft(box).insetBy(dx: -0.006, dy: -0.006),
                                            start: 0, end: 0))
            }
        }
        for f in face.results ?? [] {
            out.append(SensitiveFinding(kind: .face, text: "", rect: topLeft(f.boundingBox).insetBy(dx: -0.01, dy: -0.015), start: 0, end: 0))
        }
        return out.map { var f = $0; f.rect = f.rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)); return f }
    }

    private static func topLeft(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }

    private static let patterns: [(SensitiveFinding.Kind, NSRegularExpression)] = [
        (.email, try! NSRegularExpression(pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: .caseInsensitive)),
        (.secret, try! NSRegularExpression(pattern: #"\b(?:sk-ant-[A-Za-z0-9_\-]{12,}|sk-[A-Za-z0-9_\-]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9\-]{10,}|AIza[0-9A-Za-z_\-]{30,})\b"#)),
        (.iban, try! NSRegularExpression(pattern: #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,3})?\b"#)),
        (.card, try! NSRegularExpression(pattern: #"\b(?:\d[ \-]?){12,18}\d\b"#)),
        (.phone, try! NSRegularExpression(pattern: #"(?<![\w+])(?:\+|00|0)\d[\d \-/()]{6,18}\d(?!\w)"#)),
    ]

    /// Sensitive parts of a line of text.
    static func matches(in string: String) -> [(SensitiveFinding.Kind, Range<String.Index>)] {
        var result: [(SensitiveFinding.Kind, Range<String.Index>)] = []
        let ns = string as NSString
        for (kind, regex) in patterns {
            for m in regex.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
                guard let range = Range(m.range, in: string) else { continue }
                // One place is reported once (an IBAN is not also a phone number).
                if result.contains(where: { $0.1.overlaps(range) }) { continue }
                let value = String(string[range])
                let digits = value.filter(\.isNumber)
                switch kind {
                case .iban: guard ibanValid(value) else { continue }
                case .card: guard (13...19).contains(digits.count), luhn(digits) else { continue }
                case .phone: guard (8...15).contains(digits.count) else { continue }
                default: break
                }
                result.append((kind, range))
            }
        }
        return result
    }

    static func ibanValid(_ s: String) -> Bool {
        let raw = s.replacingOccurrences(of: " ", with: "").uppercased()
        guard raw.count >= 15, raw.count <= 34 else { return false }
        let moved = raw.dropFirst(4) + raw.prefix(4)
        var remainder = 0
        for c in moved {
            let value: Int
            if let d = c.wholeNumberValue { value = d } else if let a = c.asciiValue, c.isLetter { value = Int(a) - 55 } else { return false }
            for digit in String(value) { remainder = (remainder * 10 + Int(String(digit))!) % 97 }
        }
        return remainder == 1
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, c) in digits.reversed().enumerated() {
            guard var d = c.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    /// Adds a detection at time `t`: it continues a finding seen in the frame before at about the
    /// same place, or starts a new one.
    static func merge(_ f: SensitiveFinding, at t: Double, step: Double, into list: inout [SensitiveFinding]) {
        func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let i = a.intersection(b)
            guard !i.isNull else { return 0 }
            return (i.width * i.height) / max(1e-9, min(a.width * a.height, b.width * b.height))
        }
        if let i = list.lastIndex(where: { $0.kind == f.kind && ($0.kind == .face || $0.text == f.text)
                                       && t - $0.end <= step * 1.5 && overlap($0.rect, f.rect) > 0.3 }) {
            list[i].end = t
            list[i].rect = list[i].rect.union(f.rect)
        } else {
            var new = f
            new.start = t
            new.end = t
            list.append(new)
        }
    }
}
