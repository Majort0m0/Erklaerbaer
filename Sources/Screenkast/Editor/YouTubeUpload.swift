import SwiftUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Title and description for YouTube, kept in the project folder between uploads.
struct YouTubeDraft: Codable, Equatable {
    var title: String
    var description: String

    static let fileName = "youtube.json"
    static let titleLimit = 100
    static let descriptionLimit = 5000

    /// What YouTube Studio would refuse.
    var problems: [String] {
        var list: [String] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { list.append("Der Titel fehlt.") }
        if title.count > Self.titleLimit { list.append("Der Titel ist länger als \(Self.titleLimit) Zeichen.") }
        if description.count > Self.descriptionLimit { list.append("Die Beschreibung ist länger als \(Self.descriptionLimit) Zeichen.") }
        if (title + description).contains(where: { $0 == "<" || $0 == ">" }) { list.append("YouTube erlaubt keine spitzen Klammern < >.") }
        return list
    }
}

extension EditorModel {
    /// Description from the AI suggestions, the chapters and the tags.
    var youTubeDescriptionSuggestion: String {
        var parts: [String] = []
        if let d = aiSuggestions?.description, !d.isEmpty { parts.append(d) }
        if !settings.chapters.isEmpty { parts.append(youTubeChapterText) }
        if let tags = aiSuggestions?.tags, !tags.isEmpty { parts.append(tags.map { "#" + $0.replacingOccurrences(of: " ", with: "") }.joined(separator: " ")) }
        return parts.joined(separator: "\n\n")
    }

    /// The saved draft, else a suggestion (the chapters are always brought up to date).
    func loadYouTubeDraft() -> YouTubeDraft {
        let url = project.url.appendingPathComponent(YouTubeDraft.fileName)
        if var draft = (try? Data(contentsOf: url)).flatMap({ try? JSONDecoder().decode(YouTubeDraft.self, from: $0) }) {
            if !settings.chapters.isEmpty { draft.description = Self.replacingChapters(in: draft.description, with: youTubeChapterText) }
            return draft
        }
        return YouTubeDraft(title: aiSuggestions?.titles.first ?? project.name, description: youTubeDescriptionSuggestion)
    }

    func saveYouTubeDraft(_ draft: YouTubeDraft) {
        let url = project.url.appendingPathComponent(YouTubeDraft.fileName)
        try? JSONEncoder().encode(draft).write(to: url, options: .atomic)
    }

    /// The first block of "0:00 Title" lines in a description replaced by the current chapters
    /// (a description without one stays as it is).
    static func replacingChapters(in description: String, with chapters: String) -> String {
        let pattern = #/\d{1,2}:\d{2}(:\d{2})? .*/#
        var lines = description.components(separatedBy: "\n")
        let isChapter = { (line: String) in line.wholeMatch(of: pattern) != nil }
        guard let first = lines.firstIndex(where: isChapter) else { return description }
        var last = first
        while last + 1 < lines.count, isChapter(lines[last + 1]) { last += 1 }
        lines.replaceSubrange(first...last, with: chapters.components(separatedBy: "\n"))
        return lines.joined(separator: "\n")
    }

    /// The captions in output time, as an SRT file next to the video (nil without captions).
    func writeUploadCaptions(nextTo video: URL) -> URL? {
        guard !settings.captions.isEmpty else { return nil }
        let url = video.deletingPathExtension().appendingPathExtension("srt")
        return (try? srtText().write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    /// The picture at output time `t` of the exported video as a JPEG for YouTube (1280 pixels
    /// on the long side, under 2 MB).
    nonisolated static func writeThumbnail(from video: URL, at t: Double) async throws -> URL {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        let image = try await gen.image(at: CMTime(seconds: max(0, t), preferredTimescale: 600)).image
        let url = video.deletingPathExtension().appendingPathExtension("vorschaubild.jpg")
        var quality = 0.92
        while true {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { break }
            if data.length < 2_000_000 || quality < 0.45 {
                try (data as Data).write(to: url, options: .atomic)
                return url
            }
            quality -= 0.1
        }
        throw RecorderError.writerFailed("Vorschaubild")
    }
}

/// Upload helper: YouTube Studio's upload page, the files to drag into it and the texts to copy.
/// (A real upload through the YouTube API would need a Google Cloud project that passed Google's
/// audit, otherwise every video stays locked to private.)
@MainActor
final class YouTubeUploadModel: ObservableObject {
    @Published var draft = YouTubeDraft(title: "", description: "")
    @Published var captions: URL?
    @Published var thumbnail: URL?
    @Published var thumbnailImage: NSImage?
    @Published var thumbnailError: String?
    @Published var copied: String?
    var loaded = false
}

struct YouTubeUploadView: View {
    @ObservedObject var editor: EditorModel
    let video: URL
    let close: () -> Void
    @StateObject private var m = YouTubeUploadModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Auf YouTube hochladen").font(.title3.bold())
            step(1, "Upload-Seite öffnen") {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://www.youtube.com/upload")!)
                } label: { Label("YouTube Studio öffnen", systemImage: "safari") }
                Text("Im Browser bei deinem Kanal angemeldet sein.").font(.caption).foregroundStyle(.secondary)
            }
            step(2, "Video hineinziehen") {
                FileDragTile(url: video, hint: "In das Upload-Fenster im Browser ziehen")
            }
            step(3, "Titel und Beschreibung einfügen") {
                HStack {
                    TextField("Titel", text: $m.draft.title).textFieldStyle(.roundedBorder)
                    counter(m.draft.title.count, YouTubeDraft.titleLimit)
                    copyButton("Titel", m.draft.title)
                }
                HStack(alignment: .top) {
                    TextEditor(text: $m.draft.description)
                        .font(.callout)
                        .frame(height: 120)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
                        .overlay(alignment: .topLeading) {
                            if m.draft.description.isEmpty {
                                Text("Beschreibung – Vorschläge samt Kapiteln und Schlagwörtern liefern die KI-Vorschläge (⌘K › „KI“).")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .allowsHitTesting(false)
                            }
                        }
                    VStack(alignment: .trailing) {
                        counter(m.draft.description.count, YouTubeDraft.descriptionLimit)
                        copyButton("Beschreibung", m.draft.description)
                    }
                }
                ForEach(m.draft.problems + [editor.youTubeChapterProblem].compactMap { $0 }, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            if let captions = m.captions {
                step(4, "Untertitel hochladen") {
                    FileDragTile(url: captions, hint: "In YouTube Studio: Untertitel › Sprache \(captionLanguage) › Datei hochladen › „Mit Timing“")
                }
            }
            step(m.captions == nil ? 4 : 5, "Vorschaubild (optional)") {
                HStack {
                    if let thumbnail = m.thumbnail {
                        FileDragTile(url: thumbnail, image: m.thumbnailImage, hint: "Unter „Vorschaubild“ hineinziehen")
                    }
                    Button(m.thumbnail == nil ? "Bild an der Abspielposition (\(formatTime(playheadTime)))" : "Neu (\(formatTime(playheadTime)))") {
                        makeThumbnail()
                    }
                    .help("Das Bild des exportierten Videos an der Stelle des Abspielkopfs, 1280 Pixel breit")
                }
                if let thumbnailError = m.thumbnailError { Text(thumbnailError).font(.caption).foregroundStyle(.red) }
            }
            Text("Sichtbarkeit, Playlists und „Für Kinder“ stellst du direkt in YouTube Studio ein.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Fertig") {
                    editor.saveYouTubeDraft(m.draft)
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            guard !m.loaded else { return }
            m.loaded = true
            m.draft = editor.loadYouTubeDraft()
            m.captions = editor.writeUploadCaptions(nextTo: video)
        }
        .onDisappear { editor.saveYouTubeDraft(m.draft) }
    }

    private var playheadTime: Double { min(max(0, editor.outputTime), editor.outputDuration) }

    private var captionLanguage: String {
        let code = String(editor.settings.captionLanguage.prefix(2))
        return Locale(identifier: "de").localizedString(forLanguageCode: code) ?? editor.settings.captionLanguage
    }

    private func makeThumbnail() {
        m.thumbnailError = nil
        let video = self.video, t = playheadTime, m = self.m
        Task {
            do {
                let url = try await EditorModel.writeThumbnail(from: video, at: t)
                m.thumbnail = url
                m.thumbnailImage = NSImage(contentsOf: url)
            } catch {
                m.thumbnailError = "Vorschaubild ging nicht: \(error.localizedDescription)"
            }
        }
    }

    private func step(_ number: Int, _ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.callout.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
            }
        }
    }

    private func counter(_ count: Int, _ limit: Int) -> some View {
        Text("\(count)/\(limit)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(count > limit ? .red : .secondary)
    }

    private func copyButton(_ name: String, _ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            m.copied = name
            editor.saveYouTubeDraft(m.draft)
        } label: {
            Image(systemName: m.copied == name ? "checkmark" : "doc.on.doc")
        }
        .help("\(name) kopieren")
    }
}

/// A file to drag into another app (the browser), with its icon or a picture.
struct FileDragTile: View {
    let url: URL
    var image: NSImage? = nil
    let hint: String

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: image == nil ? 32 : 64, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Im Finder zeigen")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(object: url as NSURL) }
        .help("Ziehen, um die Datei abzulegen")
    }
}
