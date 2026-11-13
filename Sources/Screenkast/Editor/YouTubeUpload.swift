import SwiftUI
import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Title and description for YouTube, kept in the project folder between uploads.
struct YouTubeDraft: Codable, Equatable {
    var title: String
    var description: String
    /// The last video exported as MP4 (absolute path), and a fingerprint of the edit it shows.
    var video: String? = nil
    var videoEdit: String? = nil

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

    /// Fingerprint of the edit: tells whether an exported video still shows the project as it is.
    var editFingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(settings) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// An exported MP4 is remembered with the project, so the upload helper finds it any time later.
    func rememberExport(_ url: URL) {
        var draft = loadYouTubeDraft()
        draft.video = url.path
        draft.videoEdit = editFingerprint
        saveYouTubeDraft(draft)
    }

    /// Opens the export sheet (from the YouTube helper: it leads back there when done).
    func openExportSheet(forYouTube: Bool = false) {
        pause()
        if !isExporting {
            exportResult = nil
            exportError = nil
        }
        exportForYouTube = forYouTube
        showExportSheet = true
    }

    /// Called when a sheet has closed: opens the one asked for next.
    func openNextSheet() {
        guard let next = nextSheet else { return }
        nextSheet = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch next {
            case .export: self.openExportSheet(forYouTube: true)
            case .youTube: self.showYouTubeSheet = true
            case .ai: self.showAISheet = true
            }
        }
    }

    /// True for a "0:00 Title" line of a description.
    static func isChapterLine(_ line: String) -> Bool { line.wholeMatch(of: #/\d{1,2}:\d{2}(:\d{2})? .*/#) != nil }

    /// The first block of "0:00 Title" lines in a description replaced by the current chapters
    /// (a description without one stays as it is).
    static func replacingChapters(in description: String, with chapters: String) -> String {
        var lines = description.components(separatedBy: "\n")
        let isChapter = isChapterLine
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

/// Sheets of the editor that lead to one another (only one can be open at a time).
enum EditorSheet { case export, youTube, ai }

/// Upload helper: YouTube Studio's upload page, the files to drag into it and the texts to copy.
/// The one place for everything YouTube needs; it can be opened any time (toolbar, ⌘K, after an
/// export), the last exported video is remembered with the project.
/// (A real upload through the YouTube API would need a Google Cloud project that passed Google's
/// audit, otherwise every video stays locked to private.)
@MainActor
final class YouTubeUploadModel: ObservableObject {
    @Published var draft = YouTubeDraft(title: "", description: "")
    @Published var video: URL?
    /// Name of a remembered video that is no longer where it was.
    @Published var missingVideo: String?
    /// The project was changed after the video was exported.
    @Published var outdated = false
    @Published var captions: URL?
    @Published var thumbnail: URL?
    @Published var thumbnailImage: NSImage?
    @Published var thumbnailError: String?
    @Published var copied: String?
    var loaded = false
}

struct YouTubeUploadView: View {
    @ObservedObject var editor: EditorModel
    /// Shows this video instead of the remembered one (UI snapshots).
    var videoOverride: URL? = nil
    let close: () -> Void
    @StateObject private var m = YouTubeUploadModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Auf YouTube veröffentlichen").font(.title3.bold())
                Spacer()
                Button {
                    editor.saveYouTubeDraft(m.draft)
                    editor.nextSheet = .ai
                    close()
                } label: { Label("KI-Vorschläge …", systemImage: "sparkles") }
                .help("Titel, Beschreibung, Kapitel und Schlagwörter aus dem Transkript vorschlagen lassen")
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 12)
            ScrollView {
                steps
                    .padding(.horizontal, 22)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("Sichtbarkeit, Playlists und „Für Kinder“ stellst du direkt in YouTube Studio ein. Alles hier bleibt beim Projekt gespeichert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Fertig") {
                    editor.saveYouTubeDraft(m.draft)
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 620, height: 720)
        .onAppear(perform: load)
        .onDisappear { editor.saveYouTubeDraft(m.draft) }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 16) {
            step(1, "Upload-Seite öffnen") {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://www.youtube.com/upload")!)
                } label: { Label("YouTube Studio öffnen", systemImage: "safari") }
                Text("Im Browser bei deinem Kanal angemeldet sein.").font(.caption).foregroundStyle(.secondary)
            }
            step(2, "Video hineinziehen") { videoStep }
            step(3, "Titel und Beschreibung einfügen") { textStep }
            if let captions = m.captions {
                step(4, "Untertitel hochladen") {
                    FileDragTile(url: captions, hint: "In YouTube Studio: Untertitel › Sprache \(captionLanguage) › Datei hochladen › „Mit Timing“")
                }
            }
            step(m.captions == nil ? 4 : 5, "Vorschaubild (optional)") { thumbnailStep }
        }
    }

    @ViewBuilder
    private var videoStep: some View {
        if let video = m.video {
            FileDragTile(url: video, hint: "In das Upload-Fenster im Browser ziehen")
            HStack {
                if m.outdated {
                    Label("Das Projekt wurde seit diesem Export geändert.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let date = (try? video.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    Text("Exportiert \(date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Neu exportieren …") { exportFirst() }
                Button("Andere Datei …") { chooseVideo() }
            }
            .controlSize(.small)
        } else {
            Text(m.missingVideo.map { "„\($0)“ ist nicht mehr da – verschoben oder gelöscht?" } ?? "Noch kein Video exportiert.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button { exportFirst() } label: { Label("Video exportieren …", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
                    .help("Öffnet den Export; danach geht es hier weiter")
                Button("Vorhandenes Video wählen …") { chooseVideo() }
            }
        }
    }

    @ViewBuilder
    private var textStep: some View {
        HStack {
            TextField("Titel", text: $m.draft.title).textFieldStyle(.roundedBorder)
            if let titles = editor.aiSuggestions?.titles, !titles.isEmpty {
                Menu {
                    ForEach(titles, id: \.self) { title in Button(title) { m.draft.title = title } }
                } label: { Image(systemName: "sparkles") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Einen Titel aus den KI-Vorschlägen nehmen")
            }
            counter(m.draft.title.count, YouTubeDraft.titleLimit)
            copyButton("Titel", m.draft.title)
        }
        HStack(alignment: .top) {
            TextEditor(text: $m.draft.description)
                .font(.callout)
                .frame(height: 150)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
                .overlay(alignment: .topLeading) {
                    if m.draft.description.isEmpty {
                        Text("Beschreibung – einen Vorschlag samt Kapiteln und Schlagwörtern machen die KI-Vorschläge (oben rechts).")
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
        let chapters = !editor.settings.chapters.isEmpty
        let hasAI = !(editor.aiSuggestions?.description ?? "").isEmpty
        if chapters || hasAI {
            HStack {
                if hasAI {
                    Button("KI-Beschreibung einsetzen") { m.draft.description = editor.youTubeDescriptionSuggestion }
                        .help("Ersetzt die Beschreibung durch den KI-Vorschlag mit Kapiteln und Schlagwörtern")
                }
                if chapters, !m.draft.description.components(separatedBy: "\n").contains(where: EditorModel.isChapterLine) {
                    Button("Kapitel einfügen") {
                        let text = m.draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
                        m.draft.description = text.isEmpty ? editor.youTubeChapterText : text + "\n\n" + editor.youTubeChapterText
                    }
                    .help("Hängt die Kapitelmarken als „0:00 Titel“-Zeilen an die Beschreibung an")
                }
                Spacer()
                if chapters {
                    Button {
                        editor.copyChapters()
                        m.copied = "Kapitel"
                    } label: { Label("Nur Kapitel kopieren", systemImage: m.copied == "Kapitel" ? "checkmark" : "doc.on.doc") }
                    .help("Die Kapitel als „0:00 Titel“-Zeilen in die Zwischenablage")
                }
            }
            .controlSize(.small)
        }
        if chapters {
            Text("Die Kapitel in der Beschreibung folgen den Kapitelmarken des Projekts von selbst.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(m.draft.problems + [editor.youTubeChapterProblem].compactMap { $0 }, id: \.self) { problem in
            Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var thumbnailStep: some View {
        if m.video == nil {
            Text("Nach dem Export: ein Bild aus dem Video an der Stelle des Abspielkopfs.").font(.caption).foregroundStyle(.secondary)
        } else {
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
    }

    private func load() {
        guard !m.loaded else { return }
        m.loaded = true
        m.draft = editor.loadYouTubeDraft()
        if let videoOverride {
            use(videoOverride)
        } else if let path = m.draft.video {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                use(url)
                m.outdated = m.draft.videoEdit.map { $0 != editor.editFingerprint } ?? false
            } else {
                m.missingVideo = url.lastPathComponent
            }
        }
    }

    private func use(_ video: URL) {
        m.video = video
        m.missingVideo = nil
        m.captions = editor.writeUploadCaptions(nextTo: video)
        let picture = video.deletingPathExtension().appendingPathExtension("vorschaubild.jpg")
        if FileManager.default.fileExists(atPath: picture.path) {
            m.thumbnail = picture
            m.thumbnailImage = NSImage(contentsOf: picture)
        } else {
            m.thumbnail = nil
            m.thumbnailImage = nil
        }
    }

    /// Closes the helper for the export; it comes back afterwards.
    private func exportFirst() {
        editor.saveYouTubeDraft(m.draft)
        editor.nextSheet = .export
        close()
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        panel.message = "Video für YouTube wählen"
        panel.directoryURL = m.video?.deletingLastPathComponent() ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use(url)
        m.outdated = false
        m.draft.video = url.path
        m.draft.videoEdit = nil
        editor.saveYouTubeDraft(m.draft)
    }

    private var playheadTime: Double { min(max(0, editor.outputTime), editor.outputDuration) }

    private var captionLanguage: String {
        let code = String(editor.settings.captionLanguage.prefix(2))
        return Locale(identifier: "de").localizedString(forLanguageCode: code) ?? editor.settings.captionLanguage
    }

    private func makeThumbnail() {
        guard let video = m.video else { return }
        m.thumbnailError = nil
        let t = playheadTime, m = self.m
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
