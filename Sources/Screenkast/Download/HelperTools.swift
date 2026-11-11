import Foundation

// Helper programs for "Video von einer Adresse laden": yt-dlp and a JavaScript runtime that yt-dlp
// needs for YouTube. They are found where the user installed them (Homebrew, PATH, the copies
// Podcast Profi set up …) – or Erklärbär sets them up itself in
// ~/Library/Application Support/Screenkast/Tools, but only after a click: the official release
// from GitHub, checked against its published SHA-256 checksum.

/// Where a helper program comes from.
enum ToolOrigin: String, Equatable, Sendable {
    case managed, homebrew, custom

    var label: String {
        switch self {
        case .managed: return "eingerichtet von Erklärbär"
        case .homebrew: return "Homebrew"
        case .custom: return "eigene Installation"
        }
    }
}

/// A helper program that was found: path, version (when it told one), origin.
struct FoundTool: Equatable, Sendable {
    var url: URL
    var version: String?
    var origin: ToolOrigin
}

/// The programs Erklärbär can set up itself.
enum ManagedTool: String, CaseIterable, Sendable {
    case ytdlp = "yt-dlp"
    case deno

    var label: String { self == .ytdlp ? "yt-dlp" : "Deno" }
    var fileName: String { rawValue }
    var size: String { self == .ytdlp ? "etwa 40 MB" : "etwa 45 MB" }
    var source: String { self == .ytdlp ? "github.com/yt-dlp/yt-dlp" : "github.com/denoland/deno" }
}

/// JavaScript runtimes yt-dlp can use for YouTube (passed with --js-runtimes).
enum JSRuntimeKind: String, CaseIterable, Sendable {
    case deno, node, quickjs

    var executable: String { self == .quickjs ? "qjs" : rawValue }

    var label: String {
        switch self {
        case .deno: return "Deno"
        case .node: return "Node.js"
        case .quickjs: return "QuickJS"
        }
    }

    /// Oldest version yt-dlp works with (QuickJS: any).
    var minimum: [Int]? {
        switch self {
        case .deno: return [2, 3]
        case .node: return [22]
        case .quickjs: return nil
        }
    }
}

struct JSRuntime: Equatable, Sendable {
    var kind: JSRuntimeKind
    var tool: FoundTool

    /// Value of yt-dlp's --js-runtimes: "deno:/opt/homebrew/bin/deno".
    var argument: String { "\(kind.rawValue):\(tool.url.path)" }
    var label: String { tool.version.map { "\(kind.label) \($0)" } ?? kind.label }
}

// MARK: - Places

/// Where helper programs live: Erklärbär's own folder and the user's installations.
struct ToolPlaces: Equatable, Sendable {
    var managed: URL
    var search: [URL]

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    static var standardManaged: URL {
        applicationSupport.appendingPathComponent("Screenkast/Tools", isDirectory: true)
    }

    /// The user's installations: Homebrew (Apple silicon, Intel), pipx/pip, Deno's installer, the
    /// copies of Podcast Profi and the PATH (an app started from the Finder has a short PATH).
    static func searchFolders(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.deno/bin",
                     applicationSupport.appendingPathComponent("Podcast Profi/Tools").path]
        paths += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func standard() -> ToolPlaces { ToolPlaces(managed: standardManaged, search: searchFolders()) }

    /// Erklärbär's own copy first, then the user's.
    var folders: [URL] { [managed] + search.filter { $0.standardizedFileURL.path != managed.standardizedFileURL.path } }

    func origin(of url: URL) -> ToolOrigin {
        let path = url.standardizedFileURL.path
        if path.hasPrefix(managed.standardizedFileURL.path + "/") { return .managed }
        let resolved = url.resolvingSymlinksInPath().path
        if path.hasPrefix("/opt/homebrew/") || resolved.hasPrefix("/opt/homebrew/") || resolved.contains("/Cellar/") { return .homebrew }
        return .custom
    }
}

// MARK: - Versions

enum ToolVersion {
    /// The version in a program's answer to --version: "2025.10.22" (yt-dlp), "deno 2.5.4 (…)" → "2.5.4".
    static func parse(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            if let r = line.range(of: #"[0-9]+(?:[.\-][0-9]+)+"#, options: .regularExpression) { return String(line[r]) }
        }
        return nil
    }

    static func numbers(_ version: String) -> [Int] {
        version.split(whereSeparator: { !("0"..."9").contains($0) }).compactMap { Int($0) }
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = numbers(a), y = numbers(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func isAtLeast(_ version: String, _ minimum: [Int]) -> Bool {
        compare(version, minimum.map(String.init).joined(separator: ".")) != .orderedAscending
    }
}

/// Runs a helper program briefly (stdin closed, with a time limit) – for --version.
enum ToolProbe {
    private final class Box: @unchecked Sendable { var data = Data() }

    static func run(_ tool: URL, _ arguments: [String], timeout: Double = 30) -> (status: Int32, output: String)? {
        let p = Process()
        p.executableURL = tool
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        // Not waitUntilExit: on a thread without a running run loop it can miss a quick exit.
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return nil }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        guard exited.wait(timeout: .now() + 10) == .success else { return nil }
        return (p.terminationStatus, String(decoding: box.data, as: UTF8.self))
    }

    static func version(_ tool: URL, timeout: Double = 30) -> String? {
        guard let r = run(tool, ["--version"], timeout: timeout), r.status == 0 else { return nil }
        return ToolVersion.parse(r.output)
    }
}

/// Versions of the programs Erklärbär set up (tools.json in the tools folder).
struct ToolManifest: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var version: String
        var sha256: String
        var installed: Date
        var source: String
    }

    var entries: [String: Entry] = [:]

    static func url(in folder: URL) -> URL { folder.appendingPathComponent("tools.json") }

    static func load(from folder: URL) -> ToolManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(in: folder)), let m = try? decoder.decode(ToolManifest.self, from: data) else { return ToolManifest() }
        return m
    }

    func save(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(in: folder), options: .atomic)
    }
}

enum ToolDetector {
    static func locateYtdlp(in folders: [URL]) -> URL? {
        folders.map { $0.appendingPathComponent("yt-dlp") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// yt-dlp: the first one in the folders, with its version.
    static func ytdlp(places: ToolPlaces, probe: Bool = true) -> FoundTool? {
        guard let url = locateYtdlp(in: places.folders) else { return nil }
        let origin = places.origin(of: url)
        var version = origin == .managed ? ToolManifest.load(from: places.managed).entries[ManagedTool.ytdlp.fileName]?.version : nil
        if version == nil && probe { version = ToolProbe.version(url, timeout: 60) }
        return FoundTool(url: url, version: version, origin: origin)
    }

    /// The first JavaScript runtime that is new enough: Deno, then Node.js (from 22), then QuickJS.
    static func runtime(places: ToolPlaces) -> JSRuntime? {
        let fm = FileManager.default
        for kind in JSRuntimeKind.allCases {
            for folder in places.folders {
                let url = folder.appendingPathComponent(kind.executable)
                guard fm.isExecutableFile(atPath: url.path) else { continue }
                let known = places.origin(of: url) == .managed ? ToolManifest.load(from: places.managed).entries[url.lastPathComponent]?.version : nil
                let version = known ?? ToolProbe.version(url, timeout: 20)
                if let minimum = kind.minimum {
                    guard let version, ToolVersion.isAtLeast(version, minimum) else { continue }
                }
                return JSRuntime(kind: kind, tool: FoundTool(url: url, version: version, origin: places.origin(of: url)))
            }
        }
        return nil
    }
}

/// What helps after a failed download: a newer yt-dlp (YouTube changes often) or a JavaScript runtime.
enum YtDlpAdvice: Equatable {
    case update, runtime

    static func advice(for stderr: String) -> YtDlpAdvice? {
        let m = stderr.lowercased()
        if ["javascript runtime", "js runtime", "challenge solving failed"].contains(where: { m.contains($0) }) { return .runtime }
        if ["http error 403", "403: forbidden", "sign in to confirm", "nsig extraction failed", "signature extraction failed",
            "unsupported url", "unable to extract", "confirm you are on the latest version"].contains(where: { m.contains($0) }) { return .update }
        return nil
    }
}

enum Hardware {
    /// Apple silicon (also when the app runs under Rosetta).
    static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()
}

// MARK: - Model

/// What is installed and the setup in progress.
@MainActor
final class HelperTools: ObservableObject {
    static let shared = HelperTools()

    struct Setup: Equatable {
        var tool: ManagedTool
        var step: ToolSetupStep
    }

    struct Note: Equatable {
        var tool: ManagedTool
        var text: String
        var failed: Bool
    }

    let places: ToolPlaces
    let configuration: URLSessionConfiguration

    @Published private(set) var ytdlp: FoundTool?
    @Published private(set) var runtime: JSRuntime?
    /// The search ran at least once (before, "missing" is not known yet).
    @Published private(set) var detected = false
    @Published private(set) var setup: Setup?
    @Published private(set) var note: Note?

    private var setupTask: Task<Void, Never>?
    private var installer: ToolInstaller?

    init(places: ToolPlaces = .standard(), configuration: URLSessionConfiguration = .ephemeral) {
        self.places = places
        self.configuration = configuration
    }

    /// Looks for the programs (asks each for its version, off the main thread).
    func refresh() async {
        let places = places
        let found = await Task.detached(priority: .userInitiated) { () -> (FoundTool?, JSRuntime?) in
            (ToolDetector.ytdlp(places: places), ToolDetector.runtime(places: places))
        }.value
        ytdlp = found.0
        runtime = found.1
        detected = true
    }

    /// Downloads, checks and installs a program – only ever called from a button. `update`: a
    /// fresh copy of yt-dlp although one is there (sites change, old versions stop working).
    func setUp(_ tool: ManagedTool) {
        guard setup == nil else { return }
        note = nil
        let installer = ToolInstaller(folder: places.managed, configuration: configuration)
        self.installer = installer
        setup = Setup(tool: tool, step: .downloading(received: 0, expected: nil))
        let report: @Sendable (ToolSetupStep) -> Void = { step in
            Task { @MainActor in self.advance(tool, to: step) }
        }
        setupTask = Task { [weak self] in
            do {
                let found = try await installer.install(tool, step: report)
                guard let self else { return }
                self.setup = nil
                self.installer = nil
                self.note = Note(tool: tool, text: "\(tool.label) \(found.version ?? "") ist eingerichtet.", failed: false)
                await self.refresh()
            } catch {
                guard let self else { return }
                self.setup = nil
                self.installer = nil
                let e = error as? ToolSetupError ?? .network(error.localizedDescription)
                self.note = e == .cancelled ? Note(tool: tool, text: "Abgebrochen – es ist nichts liegen geblieben.", failed: false)
                                            : Note(tool: tool, text: e.localizedDescription, failed: true)
            }
        }
    }

    /// Reports from the download queue can arrive late: never go back a step.
    private func advance(_ tool: ManagedTool, to step: ToolSetupStep) {
        guard let current = setup, current.tool == tool, step.rank >= current.step.rank else { return }
        setup?.step = step
    }

    func cancelSetup() {
        installer?.cancel()
        setupTask?.cancel()
    }
}
