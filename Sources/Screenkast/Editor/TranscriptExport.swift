import AppKit
import UniformTypeIdentifiers

/// The transcript as a file: plain text (with chapter headings), text with time marks, or subtitles.
/// Everything in the time of the finished video: what is cut out is not in it.
enum TranscriptFormat: String, CaseIterable, Identifiable {
    case text, timedText, srt, vtt
    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: return "Text (.txt)"
        case .timedText: return "Text mit Zeitmarken (.txt)"
        case .srt: return "Untertitel SRT (.srt)"
        case .vtt: return "Untertitel WebVTT (.vtt)"
        }
    }

    var fileExtension: String {
        switch self {
        case .text, .timedText: return "txt"
        case .srt: return "srt"
        case .vtt: return "vtt"
        }
    }

    var contentType: UTType { UTType(filenameExtension: fileExtension) ?? .plainText }
}

extension EditorModel {
    /// There is something to export (words or captions from "Transkript erstellen").
    var hasTranscript: Bool { !settings.words.isEmpty || !settings.captions.isEmpty }

    func transcriptText(_ format: TranscriptFormat) -> String {
        switch format {
        case .srt: return srtText()
        case .vtt: return Self.vtt(fromSRT: srtText())
        case .text: return paragraphsText(timed: false)
        case .timedText: return paragraphsText(timed: true)
        }
    }

    /// WebVTT is SRT with a header and dots instead of commas in the times.
    nonisolated static func vtt(fromSRT srt: String) -> String {
        var out = "WEBVTT\n\n"
        for line in srt.components(separatedBy: "\n") {
            if line.contains(" --> ") {
                out += line.replacingOccurrences(of: ",", with: ".") + "\n"
            } else {
                out += line + "\n"
            }
        }
        return out
    }

    /// Paragraphs (a new one after a pause of 1.5 s or more) under the chapter titles.
    private func paragraphsText(timed: Bool) -> String {
        // The spoken words that are still in the video, with their place in it.
        var items: [(text: String, start: Double, end: Double, output: Double)] = []
        if !settings.words.isEmpty {
            for (i, w) in settings.words.enumerated() where !isWordRemoved(i) {
                guard let at = outputTime(ofSource: (w.start + w.end) / 2) else { continue }
                items.append((w.text, w.start, w.end, at))
            }
        } else {
            for c in settings.captions {
                guard let at = outputTime(ofSource: (c.start + c.end) / 2) else { continue }
                items.append((c.text, c.start, c.end, at))
            }
        }
        let chapters = settings.chapters.sorted { $0.time < $1.time }
        var nextChapter = 0
        var out = ""
        var paragraph: [String] = []
        var paragraphStart: Double?
        var lastEnd: Double?
        func flush() {
            guard !paragraph.isEmpty else { return }
            let stamp = timed ? "[\(formatTime(paragraphStart ?? 0, fractional: false))] " : ""
            out += stamp + Self.joined(paragraph) + "\n\n"
            paragraph = []
            paragraphStart = nil
        }
        for item in items {
            // Chapter headings before the first word of their part.
            var heading: String?
            while nextChapter < chapters.count, chapters[nextChapter].time <= item.start + 0.05 {
                heading = chapters[nextChapter].title
                nextChapter += 1
            }
            if let heading {
                flush()
                out += "## " + (heading.isEmpty ? "Kapitel" : heading) + "\n\n"
            } else if let lastEnd, item.start - lastEnd >= 1.5 {
                flush()
            }
            if paragraph.isEmpty { paragraphStart = item.output }
            paragraph.append(item.text)
            lastEnd = item.end
        }
        flush()
        let title = project.name
        return "# \(title)\n\n" + out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Recognized words carry their own spaces: one space between words, none before punctuation.
    nonisolated static func joined(_ words: [String]) -> String {
        let text = words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        return text.replacingOccurrences(of: #"\s+([,.!?;:…])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    /// Asks where and writes the transcript; the result shows like an export.
    func exportTranscript(_ format: TranscriptFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = project.name + (format == .timedText ? " (Zeitmarken)" : "") + "." + format.fileExtension
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try transcriptText(format).write(to: url, atomically: true, encoding: .utf8)
            exportError = nil
            exportResult = url
        } catch {
            exportError = error.localizedDescription
        }
    }
}
