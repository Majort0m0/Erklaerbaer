import SwiftUI

/// Loads a video, picture or sound from an address into the project's media library.
@MainActor
final class URLImportModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case downloading(received: Int64, expected: Int64?)
        case loadingTool(fraction: Double?)
        case saving
        case done(String)
        case failed(String)
    }

    @Published var address = ""
    @Published var phase: Phase = .idle
    @Published var title: String?
    /// After a failure with yt-dlp: what would probably help.
    @Published var advice: YtDlpAdvice?
    @Published var needsTool = false
    /// The file in the library after a download ("media/…").
    @Published var imported: String?

    private var task: Task<Void, Never>?
    private var downloader: MediaDownloader?
    private var runner: YTDLPProcess?
    private var cancelled = false
    /// Picture and sound come one after the other: the bar runs once over both.
    private var toolParts = 2, toolPartsDone = 0

    var busy: Bool {
        switch phase {
        case .checking, .downloading, .loadingTool, .saving: return true
        default: return false
        }
    }

    func start(editor: EditorModel, quality: VideoQuality) {
        guard !busy else { return }
        advice = nil
        needsTool = false
        imported = nil
        title = nil
        cancelled = false
        let link: VideoLink
        switch VideoLink.classify(address) {
        case .failure(let e): phase = .failed(e.localizedDescription); return
        case .success(let l): link = l
        }
        let folder = editor.project.url.appendingPathComponent(".laden-\(UUID().uuidString)", isDirectory: true)
        phase = .checking
        task = Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = try await self.fetch(link, into: folder, quality: quality)
                if self.cancelled { throw DownloadError.cancelled }
                self.phase = .saving
                guard let stored = editor.importMedia(file) else { throw DownloadError.save("nicht in die Bibliothek übernommen") }
                editor.libraryVersion &+= 1
                self.imported = stored
                self.phase = .done("„\(EditorModel.libraryName(URL(fileURLWithPath: stored)))“ liegt jetzt in der Bibliothek.")
            } catch let e as DownloadError {
                if e == .toolMissing { self.needsTool = true }
                self.phase = e == .cancelled ? .idle : .failed(e.localizedDescription)
            } catch {
                self.phase = self.cancelled ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        cancelled = true
        downloader?.cancel()
        runner?.cancel()
        task?.cancel()
    }

    private func fetch(_ link: VideoLink, into folder: URL, quality: VideoQuality) async throws -> URL {
        let url = link.url
        if case .page = link, VideoLink.isPlatform(url) { return try await fetchWithTool(url, into: folder, quality: quality) }
        // Direct links – and download links without an extension – are loaded directly. A web page
        // (or a streaming list) behind it goes to yt-dlp instead.
        do {
            return try await download(url, into: folder)
        } catch let e as DownloadError where e == .notMedia || e == .playlist {
            if case .media = link, HelperTools.shared.ytdlp == nil { throw e }
            phase = .checking
            return try await fetchWithTool(url, into: folder, quality: quality)
        }
    }

    private func download(_ url: URL, into folder: URL) async throws -> URL {
        let d = MediaDownloader(folder: folder) { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                switch self.phase {
                case .checking, .downloading: self.phase = .downloading(received: p.received, expected: p.expected)
                default: break
                }
            }
        }
        downloader = d
        let file = try await d.download(url)
        downloader = nil
        let c = await VideoSaver.contents(of: file)
        guard c.video || c.audio || NSImage(contentsOf: file) != nil else { throw DownloadError.unreadable(file.lastPathComponent) }
        return file
    }

    private func fetchWithTool(_ url: URL, into folder: URL, quality: VideoQuality) async throws -> URL {
        let tools = HelperTools.shared
        if !tools.detected { await tools.refresh() }
        if cancelled { throw DownloadError.cancelled }
        guard let ytdlp = tools.ytdlp else { throw DownloadError.toolMissing }
        phase = .loadingTool(fraction: nil)
        toolParts = 2
        toolPartsDone = 0
        let runner = YTDLPProcess()
        self.runner = runner
        let result: (files: [URL], title: String?)
        do {
            result = try await runner.run(tool: ytdlp.url, arguments: YTDLP.arguments(for: url, into: folder, quality: quality, runtime: tools.runtime),
                                          folder: folder) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
        } catch {
            advice = runner.advice
            throw error
        }
        if cancelled { throw DownloadError.cancelled }
        phase = .saving
        return try await VideoSaver.finish(result.files, title: result.title ?? title ?? "Video", in: folder)
    }

    private func handle(_ event: YTDLP.Event) {
        if case .title(let t) = event { title = t }
        guard case .loadingTool(let fraction) = phase else { return }
        func overall(_ part: Double) -> Double { min(1, (Double(min(toolPartsDone, toolParts - 1)) + min(1, part)) / Double(toolParts)) }
        switch event {
        case .title: break
        case .format(let video, let audio): if toolPartsDone == 0, (video && audio) || !video { toolParts = 1 }   // one file only
        case .file: toolPartsDone += 1
        case .percent(let p): phase = .loadingTool(fraction: overall(p / 100))
        case .progress(let received, let total): phase = .loadingTool(fraction: total.map { overall(received / max(1, $0)) } ?? fraction)
        }
    }
}

struct URLImportSheet: View {
    @ObservedObject var editor: EditorModel
    @Binding var isPresented: Bool
    @StateObject private var m = URLImportModel()
    @ObservedObject private var tools = HelperTools.shared
    @AppStorage("urlImportQuality") private var qualityRaw = VideoQuality.p1080.rawValue

    private var quality: VideoQuality { VideoQuality(rawValue: qualityRaw) ?? .p1080 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Von einer Adresse laden").font(.title3.bold())
            Text("Ein Video, ein Bild oder Ton aus dem Internet kommt in die Bibliothek dieses Projekts: direkte Links zu Dateien, YouTube, Vimeo, Mediatheken und viele andere Seiten.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://…", text: $m.address)
                .textFieldStyle(.roundedBorder)
                .onSubmit { m.start(editor: editor, quality: quality) }
                .disabled(m.busy)
            Picker("Qualität", selection: $qualityRaw) {
                ForEach(VideoQuality.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .disabled(m.busy)
            .help("Höchste Bildhöhe bei Videos von Seiten wie YouTube; direkte Links kommen, wie sie sind")
            toolsBox
            status
            Text("Bitte nur laden, was du verwenden darfst – eigene Videos oder solche mit passender Lizenz.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if let file = m.imported {
                    Button("Am Abspielkopf einsetzen") {
                        editor.useLibraryItem(editor.project.url.appendingPathComponent(file))
                        isPresented = false
                    }
                }
                Spacer()
                if m.busy {
                    Button("Abbrechen") { m.cancel() }
                } else {
                    Button("Schließen") { isPresented = false }.keyboardShortcut(.cancelAction)
                }
                Button("Laden") { m.start(editor: editor, quality: quality) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(m.busy || m.address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task { await tools.refresh() }
    }

    @ViewBuilder
    private var status: some View {
        switch m.phase {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Adresse wird geprüft …") }.font(.callout)
        case .downloading(let received, let expected):
            if let expected, expected > 0 {
                ProgressView(value: Double(received), total: Double(expected)) {
                    Text("Wird geladen … \(bytes(received)) von \(bytes(expected))").font(.callout)
                }
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Wird geladen … \(bytes(received))") }.font(.callout)
            }
        case .loadingTool(let fraction):
            let label = m.title.map { "„\($0)“ wird geladen …" } ?? "Wird mit yt-dlp geladen …"
            if let fraction {
                ProgressView(value: fraction) { Text(label).font(.callout).lineLimit(1) }
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(label).lineLimit(1) }.font(.callout)
            }
        case .saving:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Bild und Ton werden zusammengefügt …") }.font(.callout)
        case .done(let text):
            Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case .failed(let text):
            VStack(alignment: .leading, spacing: 6) {
                Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if m.advice == .update {
                    Button("yt-dlp aktualisieren (\(ManagedTool.ytdlp.size))") { tools.setUp(.ytdlp) }
                        .help("Video-Seiten ändern sich oft; eine neue Version von yt-dlp hilft meistens")
                }
            }
        }
    }

    /// yt-dlp and the JavaScript runtime for YouTube: found, or set up with a click.
    private var toolsBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !tools.detected {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Hilfsprogramme werden gesucht …") }
            } else {
                toolRow(.ytdlp, found: tools.ytdlp.map { "yt-dlp \($0.version ?? "") – \($0.origin.label)" },
                        missing: "yt-dlp fehlt – nötig für YouTube, Vimeo, Mediatheken & Co.")
                toolRow(.deno, found: tools.runtime.map { "\($0.label) – \($0.tool.origin.label)" },
                        missing: "Für YouTube braucht yt-dlp zusätzlich Deno.")
            }
            if let setup = tools.setup {
                HStack(spacing: 8) {
                    ProgressView(value: setupFraction(setup.step)).frame(maxWidth: 160)
                    Text("\(setup.tool.label): \(stepText(setup.step))")
                    Spacer()
                    Button("Abbrechen") { tools.cancelSetup() }.buttonStyle(.link)
                }
            }
            if let note = tools.note {
                Text(note.text).foregroundStyle(note.failed ? .red : .secondary)
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(m.needsTool ? 0.16 : 0.08)))
    }

    private func toolRow(_ tool: ManagedTool, found: String?, missing: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: found == nil ? "circle.dashed" : "checkmark.circle.fill")
                .foregroundStyle(found == nil ? Color.secondary : Color.green)
            Text(found ?? missing).lineLimit(2)
            Spacer()
            if found == nil {
                Button("Einrichten (\(tool.size))") { tools.setUp(tool) }
                    .disabled(tools.setup != nil)
                    .help("Lädt die offizielle Version von \(tool.source) und prüft ihre Prüfsumme")
            }
        }
    }

    private func setupFraction(_ step: ToolSetupStep) -> Double? {
        if case .downloading(let received, let expected) = step, let expected, expected > 0 { return Double(received) / Double(expected) }
        return step.rank > 0 ? 1 : nil
    }

    private func stepText(_ step: ToolSetupStep) -> String {
        switch step {
        case .downloading(let received, _): return "wird geladen … \(bytes(received))"
        case .verifying: return "Prüfsumme wird geprüft …"
        case .unpacking: return "wird entpackt …"
        case .testing: return "Probelauf …"
        }
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}
