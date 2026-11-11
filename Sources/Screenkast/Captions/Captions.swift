import Foundation
import AVFoundation
import Speech
import CoreText
import CoreImage

/// One subtitle (source time).
struct Caption: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
}

struct CaptionWord {
    var text: String
    var start: Double
    var end: Double
}

enum CaptionError: LocalizedError {
    case unsupportedOS, noAudio, localeUnsupported(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedOS: return "Untertitel brauchen macOS 26 oder neuer."
        case .noAudio: return "Keine Tonspur mit Sprache gefunden."
        case .localeUnsupported(let l): return "Die Sprache \(l) wird von der Spracherkennung nicht unterstützt."
        }
    }
}

/// Which sound the captions are made from.
enum CaptionSource: String, Codable, CaseIterable, Identifiable {
    case microphone, narration, everything
    var id: String { rawValue }
    var label: String {
        switch self {
        case .microphone: return "Mikrofon der Aufnahme"
        case .narration: return "Voice-over und eigene Audiodateien"
        case .everything: return "Alles Hörbare (ohne Musik)"
        }
    }
}

/// On-device speech recognition (Apple SpeechAnalyzer) → timed words → readable captions.
enum CaptionGenerator {
    static let maxCharacters = 42
    static let maxPause = 0.7

    /// Transcribes the chosen sound. `.microphone`: echo-free mic, else mic, else system audio.
    /// The others mix the lanes as they play (voice-overs, imported audio, inserted clips …) on
    /// the timeline and map the word times back to the recording's time.
    static func generate(project: Project, localeID: String, source: CaptionSource = .microphone,
                         progress: @escaping @Sendable (String) -> Void) async throws -> (captions: [Caption], words: [CaptionWord]) {
        guard #available(macOS 26.0, *) else { throw CaptionError.unsupportedOS }
        if source != .microphone {
            return try await generateFromMix(project: project, localeID: localeID, source: source, progress: progress)
        }
        let asset = AVURLAsset(url: project.videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let roles = await AudioRole.roles(of: tracks, fallback: project.info.audioRoles)
        let duration = try await asset.load(.duration).seconds

        let audioURL = project.url.appendingPathComponent(".captions-audio.caf")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let clean = EchoCanceller.cleanURL(for: project)
        if let imported = VoiceProcessor.importedMicURL(for: project, settings: project.settings) {
            try FileManager.default.copyItem(at: imported, to: audioURL)
        } else if project.settings.removeEcho, FileManager.default.fileExists(atPath: clean.path) {
            try FileManager.default.copyItem(at: clean, to: audioURL)
        } else if let i = roles.firstIndex(of: "mic") ?? roles.firstIndex(of: "system") {
            // Samples placed on the recording timeline, so word times are source times.
            let samples = try await EchoCanceller.readMono(track: tracks[i], asset: asset, duration: duration)
            try EchoCanceller.writeCAF(samples, to: audioURL)
        } else {
            throw CaptionError.noAudio
        }
        progress("Sprache wird erkannt …")
        let words = try await transcribe(url: audioURL, localeID: localeID, progress: progress)
        return (group(words), words.sorted { $0.start < $1.start })
    }

    @available(macOS 26.0, *)
    private static func generateFromMix(project: Project, localeID: String, source: CaptionSource,
                                        progress: @escaping @Sendable (String) -> Void) async throws -> (captions: [Caption], words: [CaptionWord]) {
        let media = try await MediaBuilder.make(project: project, renderer: FrameRenderer(project: project), fps: 30)
        let roles: Set<String> = source == .narration ? ["voiceover"] : ["mic", "system", "voiceover", "insert", "overlay"]
        let tracks = media.audioTracks.filter { roles.contains($0.role) && !$0.isDissolveB }.map(\.track)
        guard !tracks.isEmpty else { throw CaptionError.noAudio }
        let reader = try AVAssetReader(asset: media.asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        ])
        output.audioMix = media.audioMix(settings: project.settings)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CaptionError.noAudio }
        var samples = [Float](repeating: 0, count: Int(media.totalDuration * 48_000) + 4800)
        while let sb = output.copyNextSampleBuffer() {
            guard let block = sb.dataBuffer else { continue }
            let start = Int((sb.presentationTimeStamp.seconds * 48_000).rounded())
            let n = CMBlockBufferGetDataLength(block) / 4
            var chunk = [Float](repeating: 0, count: n)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            for i in 0..<n where start + i >= 0 && start + i < samples.count { samples[start + i] = chunk[i] }
        }
        guard samples.contains(where: { abs($0) > 0.001 }) else { throw CaptionError.noAudio }
        let audioURL = project.url.appendingPathComponent(".captions-audio.caf")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try EchoCanceller.writeCAF(samples, to: audioURL)
        progress("Sprache wird erkannt …")
        let heard = try await transcribe(url: audioURL, localeID: localeID, progress: progress)
        // Composition time → timeline time → source time (the intro lies before the recording).
        let map = project.settings.editMap(duration: project.info.duration)
        let offset = media.recordingOffset
        let words = heard.compactMap { w -> CaptionWord? in
            let a = w.start - offset, b = w.end - offset
            guard a >= 0, a < map.total else { return nil }
            return CaptionWord(text: w.text, start: map.source(a), end: map.source(min(b, map.total)))
        }
        return (group(words), words.sorted { $0.start < $1.start })
    }

    @available(macOS 26.0, *)
    static func transcribe(url: URL, localeID: String,
                           progress: @escaping @Sendable (String) -> Void) async throws -> [CaptionWord] {
        let locale = Locale(identifier: localeID)
        let supported = await SpeechTranscriber.supportedLocales
        guard let match = supported.first(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) })
                ?? supported.first(where: { $0.language.languageCode == locale.language.languageCode }) else {
            throw CaptionError.localeUnsupported(localeID)
        }
        let transcriber = SpeechTranscriber(locale: match, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress("Sprachmodell wird geladen …")
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        async let collected: [CaptionWord] = {
            var words: [CaptionWord] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    words.append(CaptionWord(text: text, start: range.start.seconds, end: range.end.seconds))
                }
            }
            return words
        }()
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }

    /// Groups words into captions: phrases split at sentence ends and pauses, then each phrase
    /// is divided into balanced chunks of ≤ maxCharacters, preferring breaks after commas.
    static func group(_ words: [CaptionWord]) -> [Caption] {
        func text(_ ws: ArraySlice<CaptionWord>) -> String {
            ws.map(\.text).joined().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "  ", with: " ")
        }
        func endsWith(_ w: CaptionWord, _ chars: String) -> Bool {
            w.text.trimmingCharacters(in: .whitespaces).last.map { chars.contains($0) } ?? false
        }
        // 1. Phrases
        var phrases: [[CaptionWord]] = []
        var current: [CaptionWord] = []
        for w in words.sorted(by: { $0.start < $1.start }) {
            if let last = current.last, w.start - last.end > maxPause {
                phrases.append(current)
                current = []
            }
            current.append(w)
            if endsWith(w, ".!?") {
                phrases.append(current)
                current = []
            }
        }
        if !current.isEmpty { phrases.append(current) }

        // 2. Balanced breaking per phrase (dynamic programming over break positions)
        var captions: [Caption] = []
        for phrase in phrases {
            let n = phrase.count
            var best = [Double](repeating: .infinity, count: n + 1)
            var from = [Int](repeating: 0, count: n + 1)
            best[0] = 0
            for end in 1...n {
                for start in stride(from: end - 1, through: 0, by: -1) {
                    let length = text(phrase[start..<end]).count
                    if length > maxCharacters && end - start > 1 { break }
                    let slack = Double(max(0, maxCharacters - length))
                    let penalty: Double = (end == n || endsWith(phrase[end - 1], ",;:")) ? 0 : 200
                    let cost = best[start] + slack * slack + penalty
                    if cost < best[end] { best[end] = cost; from[end] = start }
                }
            }
            var cuts: [Range<Int>] = []
            var end = n
            while end > 0 { cuts.append(from[end]..<end); end = from[end] }
            for r in cuts.reversed() {
                captions.append(Caption(start: phrase[r.lowerBound].start, end: phrase[r.upperBound - 1].end,
                                        text: text(phrase[r])))
            }
        }
        // 3. Keep captions a little longer on screen, but never overlapping the next one.
        for i in captions.indices {
            let next = i + 1 < captions.count ? captions[i + 1].start : .infinity
            captions[i].end = min(max(captions[i].end + 0.35, captions[i].start + 0.8), next)
        }
        return captions
    }

    // MARK: SRT

    /// SRT in output time (trim and cuts applied; `offset` = length of an intro before the recording).
    /// `map`: the edited timeline (else made from `kept`); `from`: no captions before this timeline time.
    /// A caption interrupted by an inserted clip becomes two entries with the same text.
    static func srt(_ captions: [Caption], kept: [ClosedRange<Double>], offset introOffset: Double = 0, map: TimeMap? = nil,
                    from: Double? = nil) -> String {
        let map = map ?? TimeMap(base: TimeMap(duration: kept.map(\.upperBound).max() ?? 0), parts: kept)
        func stamp(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        var out = ""
        var n = 1
        let entries = captions.flatMap { c in map.captionSpans(start: c.start, end: c.end, from: from).map { ($0, c.text) } }
        for (span, text) in entries.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) where span.upperBound - span.lowerBound > 0.05 {
            out += "\(n)\n\(stamp(introOffset + span.lowerBound)) --> \(stamp(introOffset + span.upperBound))\n\(text)\n\n"
            n += 1
        }
        return out
    }
}

extension TimeMap {
    /// Where a caption (source `start`…`end`) is shown on the timeline. An inserted clip or a
    /// freeze frame the caption doesn't belong to interrupts it: the recording's sound pauses
    /// there, so nothing of it is said and the caption waits (an intro or outro video stays free).
    /// A caption heard in the clip or during the freeze (made from the mixed sound, e.g. a
    /// voice-over) starts or ends inside its tiny source range and stays over it.
    /// Nothing is shown before timeline time `from`.
    func captionSpans(start: Double, end: Double, from: Double? = nil) -> [ClosedRange<Double>] {
        guard let run = run(start, end) else { return [] }
        var spans = [run]
        for p in pieces where p.isFreeze && p.timeline.upperBound > run.lowerBound && p.timeline.lowerBound < run.upperBound {
            guard start < p.source.lowerBound - 1e-9, end > p.source.upperBound + 1e-9 else { continue }
            spans = spans.flatMap { s -> [ClosedRange<Double>] in
                var parts: [ClosedRange<Double>] = []
                if p.timeline.lowerBound > s.lowerBound { parts.append(s.lowerBound...min(s.upperBound, p.timeline.lowerBound)) }
                if p.timeline.upperBound < s.upperBound { parts.append(max(s.lowerBound, p.timeline.upperBound)...s.upperBound) }
                return parts
            }
        }
        if let from { spans = spans.compactMap { $0.upperBound > from ? max($0.lowerBound, from)...$0.upperBound : nil } }
        return spans.filter { $0.upperBound - $0.lowerBound > 1e-6 }
    }
}

/// Renders caption text into images (CoreText, thread-safe), cached per text and size.
final class CaptionImageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: CIImage] = [:]

    func image(text: String, fontSize: CGFloat, maxWidth: CGFloat) -> CIImage {
        let key = "\(Int(fontSize))|\(Int(maxWidth))|\(text)"
        if let img = lock.withLock({ cache[key] }) { return img }
        let img = Self.render(text: text, fontSize: fontSize, maxWidth: maxWidth)
        lock.withLock {
            if cache.count > 200 { cache.removeAll() }
            cache[key] = img
        }
        return img
    }

    private static func render(text: String, fontSize: CGFloat, maxWidth: CGFloat) -> CIImage {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let bold = CTFontCreateCopyWithSymbolicTraits(font, fontSize, nil, .boldTrait, .boldTrait) ?? font
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafeBytes(of: &alignment) { ptr in
            CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                            value: ptr.baseAddress!)], 1)
        }
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): bold,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let padX = fontSize * 0.6, padY = fontSize * 0.35
        let w = Int(ceil(fit.width + 2 * padX)), h = Int(ceil(fit.height + 2 * padY))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .empty() }
        let box = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: fontSize * 0.45, cornerHeight: fontSize * 0.45, transform: nil))
        // Core Image blends in linear light, so semi-transparent black looks lighter than in sRGB.
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.86))
        ctx.fillPath()
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: padX, y: padY, width: ceil(fit.width), height: ceil(fit.height)), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        guard let cg = ctx.makeImage() else { return .empty() }
        return CIImage(cgImage: cg)
    }
}
