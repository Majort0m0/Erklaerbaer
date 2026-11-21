import SwiftUI

/// Where a download goes: into the media library of the open project, or into a new project
/// (start page) that opens right away.
enum URLImportTarget {
    case library(EditorModel)
    /// Without an app (command line) the project is only created, not opened.
    case newProject(AppModel?)

    var isNewProject: Bool {
        if case .newProject = self { return true }
        return false
    }
}

/// Loads a video, picture or sound from an address – into the project's media library or as a
/// new project.
@MainActor
final class URLImportModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case downloading(received: Int64, expected: Int64?)
        case loadingTool(fraction: Double?)
        case saving
        case creating
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
    /// The new project, once it is open.
    @Published var createdProject: URL?
    /// The browser whose login the last attempt used (only when the user chose one).
    @Published private(set) var browser: CookieBrowser?
    /// Where a new project goes (nil: the chosen project folder).
    var projectFolder: URL?

    private var task: Task<Void, Never>?
    private var downloader: MediaDownloader?
    private var runner: YTDLPProcess?
    private var cancelled = false
    /// Picture and sound come one after the other: the bar runs once over both.
    private var toolParts = 1, toolPartsDone = 0, partsStarted = 0

    var busy: Bool {
        switch phase {
        case .checking, .downloading, .loadingTool, .saving, .creating: return true
        default: return false
        }
    }

    /// `browser`: try again with the login of this browser (Instagram and others).
    func start(_ target: URLImportTarget, quality: VideoQuality, browser: CookieBrowser? = nil) {
        guard !busy else { return }
        advice = nil
        needsTool = false
        imported = nil
        createdProject = nil
        title = nil
        cancelled = false
        self.browser = browser
        let link: VideoLink
        switch VideoLink.classify(address) {
        case .failure(let e): phase = .failed(e.localizedDescription); return
        case .success(let l): link = l
        }
        // Into a library: next to it (same volume, moved without copying). For a new project: a
        // local folder – the project folder may be a share, the import copies the video there.
        let folder: URL
        switch target {
        case .library(let editor): folder = editor.project.url.appendingPathComponent(".laden-\(UUID().uuidString)", isDirectory: true)
        case .newProject: folder = FileManager.default.temporaryDirectory.appendingPathComponent("Erklaerbaer-laden-\(UUID().uuidString)", isDirectory: true)
        }
        phase = .checking
        task = Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = try await self.fetch(link, into: folder, quality: quality, browser: browser)
                if self.cancelled { throw DownloadError.cancelled }
                switch target {
                case .library(let editor):
                    self.phase = .saving
                    guard let stored = editor.importMedia(file) else { throw DownloadError.save("nicht in die Bibliothek übernommen") }
                    editor.libraryVersion &+= 1
                    self.imported = stored
                    self.phase = .done("„\(EditorModel.libraryName(URL(fileURLWithPath: stored)))“ liegt jetzt in der Bibliothek.")
                case .newProject(let app):
                    guard await VideoSaver.contents(of: file).video else { throw DownloadError.noPicture }
                    self.phase = .creating
                    let project = try await ProjectFactory.importVideo(file, into: self.projectFolder ?? ProjectLocations.current,
                                                                       sourceName: VideoLink.siteName(link.url))
                    if self.cancelled {
                        try? FileManager.default.removeItem(at: project.url)
                        throw DownloadError.cancelled
                    }
                    if let app {
                        ProjectLocations.remember(project.url)
                        app.reloadLibrary()
                        app.open(project: project)
                    }
                    self.createdProject = project.url
                    self.phase = .done("„\(project.url.deletingPathExtension().lastPathComponent)“ ist als neues Projekt geöffnet.")
                }
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

    private func fetch(_ link: VideoLink, into folder: URL, quality: VideoQuality, browser: CookieBrowser?) async throws -> URL {
        let url = link.url
        if case .page = link, VideoLink.isPlatform(url) { return try await fetchWithTool(url, into: folder, quality: quality, browser: browser) }
        // Direct links – and download links without an extension – are loaded directly. A web page
        // (or a streaming list) behind it goes to yt-dlp instead.
        do {
            return try await download(url, into: folder)
        } catch let e as DownloadError where e == .notMedia || e == .playlist {
            if case .media = link, HelperTools.shared.ytdlp == nil { throw e }
            phase = .checking
            return try await fetchWithTool(url, into: folder, quality: quality, browser: browser)
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

    private func fetchWithTool(_ url: URL, into folder: URL, quality: VideoQuality, browser: CookieBrowser?) async throws -> URL {
        let tools = HelperTools.shared
        if !tools.detected { await tools.refresh() }
        if cancelled { throw DownloadError.cancelled }
        guard let ytdlp = tools.ytdlp else { throw DownloadError.toolMissing }
        phase = .loadingTool(fraction: nil)
        toolParts = 1
        toolPartsDone = 0
        partsStarted = 0
        let runner = YTDLPProcess()
        self.runner = runner
        let result: (files: [URL], title: String?)
        do {
            result = try await runner.run(tool: ytdlp.url,
                                          arguments: YTDLP.arguments(for: url, into: folder, quality: quality, runtime: tools.runtime, browser: browser),
                                          folder: folder) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
        } catch {
            advice = runner.advice
            // macOS keeps the browser's cookies from yt-dlp (Safari without Full Disk Access).
            if let browser, case .tool(let message)? = error as? DownloadError, message.lowercased().contains("operation not permitted") {
                advice = .login
                throw DownloadError.browserAccess(browser)
            }
            throw error
        }
        if cancelled { throw DownloadError.cancelled }
        phase = .saving
        return try await VideoSaver.finish(result.files, title: result.title ?? title ?? "Video", in: folder)
    }

    private func handle(_ event: YTDLP.Event) {
        switch event {
        case .title(let t): title = t
        case .parts(let n): toolParts = max(1, n); toolPartsDone = 0; partsStarted = 0
        case .partStarted: partsStarted += 1; toolPartsDone = max(0, partsStarted - 1)
        default: break
        }
        guard case .loadingTool(let fraction) = phase else { return }
        func overall(_ part: Double) -> Double { min(1, (Double(min(toolPartsDone, toolParts - 1)) + min(1, part)) / Double(toolParts)) }
        switch event {
        case .percent(let p): phase = .loadingTool(fraction: overall(p / 100))
        case .progress(let received, let total): phase = .loadingTool(fraction: total.map { overall(received / max(1, $0)) } ?? fraction)
        default: break
        }
    }
}

extension URLImportModel {
    /// `--urlproject <address> <folder> [720|1080|best] [browser]`: loads like "Neues Projekt aus
    /// dem Internet" on the start page, with the same tools, into `folder`. Prints the project path.
    static func commandLine(address: String, folder: String, quality: String?, browser: String?) -> Int32 {
        MainActor.assumeIsolated {
            let m = URLImportModel()
            m.address = address
            m.projectFolder = URL(fileURLWithPath: folder)
            try? FileManager.default.createDirectory(at: m.projectFolder!, withIntermediateDirectories: true)
            let q: VideoQuality = quality == "720" ? .p720 : quality == "best" ? .best : .p1080
            m.start(.newProject(nil), quality: q, browser: browser.flatMap(CookieBrowser.init(rawValue:)))
            var last = ""
            while m.busy {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let now = "\(m.phase)"
                if now.prefix(12) != last.prefix(12) { print("… \(now)"); last = now }
            }
            switch m.phase {
            case .done(let text):
                print(text)
                print(m.createdProject?.path ?? "")
                return 0
            case .failed(let text):
                print("Fehler: \(text)\(m.advice.map { " (Hinweis: \($0))" } ?? "")")
                return 1
            default:
                return 1
            }
        }
    }
}

struct URLImportSheet: View {
    let target: URLImportTarget
    @Binding var isPresented: Bool
    /// An address dropped onto the start page: filled in and loaded right away.
    var initialAddress: String? = nil
    @StateObject private var m: URLImportModel
    @ObservedObject private var tools = HelperTools.shared
    @AppStorage("urlImportQuality") private var qualityRaw = VideoQuality.p1080.rawValue
    @FocusState private var fieldFocused: Bool

    init(target: URLImportTarget, isPresented: Binding<Bool>, initialAddress: String? = nil, model: URLImportModel? = nil) {
        self.target = target
        _isPresented = isPresented
        self.initialAddress = initialAddress
        _m = StateObject(wrappedValue: model ?? URLImportModel())
    }

    private var quality: VideoQuality { VideoQuality(rawValue: qualityRaw) ?? .p1080 }
    private var newProject: Bool { target.isNewProject }

    private func start(browser: CookieBrowser? = nil) { m.start(target, quality: quality, browser: browser) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if newProject {
                HStack(spacing: 10) {
                    IconTile(icon: "globe", color: Theme.brand, size: 30)
                    Text("Neues Projekt aus dem Internet").font(.title3.bold())
                }
                Text("Füge die Adresse eines Videos ein – von YouTube, Instagram (auch Reels), Vimeo, TikTok, einer Mediathek oder einen direkten Link zu einer Videodatei. Erklärbär lädt es und öffnet es als neues Projekt.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Von einer Adresse laden").font(.title3.bold())
                Text("Ein Video, ein Bild oder Ton aus dem Internet kommt in die Bibliothek dieses Projekts: direkte Links zu Dateien, YouTube, Instagram, Vimeo, Mediatheken und viele andere Seiten.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(newProject ? "https://www.instagram.com/reel/… oder https://youtu.be/…" : "https://…", text: $m.address)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { start() }
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
                if !newProject, let file = m.imported, case .library(let editor) = target {
                    Button("Am Abspielkopf einsetzen") {
                        editor.useLibraryItem(editor.project.url.appendingPathComponent(file))
                        isPresented = false
                    }
                }
                Spacer()
                if m.busy {
                    Button("Abbrechen") { m.cancel() }
                        .disabled(m.phase == .creating)
                } else {
                    Button("Schließen") { isPresented = false }.keyboardShortcut(.cancelAction)
                }
                Button(newProject ? "Laden und öffnen" : "Laden") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(m.busy || m.address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task { await tools.refresh() }
        .onAppear {
            fieldFocused = true
            if let initialAddress, m.address.isEmpty, m.phase == .idle {
                m.address = initialAddress
                start()
            }
        }
        // The new project is open behind the sheet: nothing left to do here.
        .onChange(of: m.createdProject) { _, url in if url != nil { isPresented = false } }
        .onDisappear { if m.busy { m.cancel() } }
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
        case .creating:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Neues Projekt wird angelegt …") }.font(.callout)
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
                if m.advice == .login { loginBox }
            }
        }
    }

    /// Instagram & Co. show some videos only to logged-in visitors (or slow down visitors without
    /// a login): yt-dlp may use the login of a browser – only after the user picks one.
    private var loginBox: some View {
        let browsers = CookieBrowser.installed
        return VStack(alignment: .leading, spacing: 6) {
            Text(m.browser.map { "Auch mit der Anmeldung aus \($0.label) ging es nicht. Bist du dort bei der Seite angemeldet? Sonst einen anderen Browser versuchen." }
                 ?? "Die Seite zeigt das Video nur angemeldeten Besuchern – oder sie bremst gerade Besucher ohne Anmeldung. Bist du in einem Browser bei ihr angemeldet, kann yt-dlp diese Anmeldung benutzen.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Menu("Mit Anmeldung aus dem Browser laden") {
                    ForEach(browsers) { b in
                        Button(b.label) { start(browser: b) }
                    }
                }
                .fixedSize()
                .disabled(browsers.isEmpty)
                if m.browser == .safari {
                    Button("Festplattenvollzugriff …") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            Text("yt-dlp liest die Anmeldung nur hier auf dem Mac und schickt sie nur an diese Seite. Safari braucht dafür den Festplattenvollzugriff, Chrome und andere fragen einmal nach dem Schlüsselbund.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    /// yt-dlp and the JavaScript runtime for YouTube: found, or set up with a click.
    private var toolsBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !tools.detected {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Hilfsprogramme werden gesucht …") }
            } else {
                toolRow(.ytdlp, found: tools.ytdlp.map { "yt-dlp \($0.version ?? "") – \($0.origin.label)" },
                        missing: "yt-dlp fehlt – nötig für YouTube, Instagram, Vimeo, Mediatheken & Co.")
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
