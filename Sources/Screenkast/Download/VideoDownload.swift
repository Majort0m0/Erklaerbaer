import Foundation
import AVFoundation
import UniformTypeIdentifiers

// "Von einer Adresse laden" in the media library: direct links to media files are downloaded with
// URLSession, pages of video platforms go through yt-dlp – the user's own or the copy Erklärbär
// sets up after a click (HelperTools.swift). yt-dlp fetches picture (H.264 in MP4) and sound
// (M4A) as two files, no ffmpeg needed; AVFoundation joins them without re-encoding.

enum DownloadError: LocalizedError, Equatable {
    case empty
    case invalid
    case unsupportedScheme(String)
    case notMedia
    case playlist
    case unreadable(String)
    case http(Int)
    case toolMissing
    case tool(String)
    case network(String)
    case nothing
    case unsupportedFormat
    case save(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .empty: return "Füge die Adresse eines Videos ein."
        case .invalid: return "Das sieht nicht nach einer Internetadresse aus – sie beginnt meist mit https://."
        case .unsupportedScheme(let s): return "Adressen mit „\(s):“ kann Erklärbär nicht laden. Nimm eine Adresse mit https://."
        case .notMedia: return "Unter dieser Adresse liegt eine Webseite, keine Video- oder Audiodatei."
        case .playlist: return "Das ist eine Streaming-Liste (HLS), keine einzelne Datei. Mit yt-dlp klappt es meist."
        case .unreadable(let name): return "„\(name)“ kann macOS nicht abspielen."
        case .http(let code):
            switch code {
            case 404: return "Der Server findet die Datei nicht (Fehler 404)."
            case 401, 403: return "Der Server lässt nicht laden (Fehler \(code)) – vielleicht braucht es eine Anmeldung."
            default: return "Der Server antwortet mit Fehler \(code)."
            }
        case .toolMissing: return "Für Videos auf Seiten wie YouTube, Vimeo oder der Mediathek braucht Erklärbär das kostenlose Programm yt-dlp."
        case .tool(let s): return "yt-dlp meldet: \(s)"
        case .network(let s): return "Laden fehlgeschlagen: \(s)"
        case .nothing: return "yt-dlp hat keine Datei geliefert."
        case .unsupportedFormat: return "Dieses Video gibt es nur in einem Format, das macOS nicht abspielt."
        case .save(let s): return "Das Video ließ sich nicht sichern: \(s)"
        case .cancelled: return "Abgebrochen."
        }
    }
}

/// Picture quality of the downloaded video.
enum VideoQuality: String, CaseIterable, Identifiable, Sendable {
    case p720, p1080, best

    var id: String { rawValue }

    var label: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .best: return "Beste"
        }
    }

    var maxHeight: Int? {
        switch self {
        case .p720: return 720
        case .p1080: return 1080
        case .best: return nil
        }
    }
}

// MARK: - Address

/// What the user entered: a direct link to a media file or a web page (video platform).
enum VideoLink: Equatable {
    case media(URL)
    case page(URL)

    var url: URL {
        switch self {
        case .media(let u), .page(let u): return u
        }
    }

    /// Files AVFoundation reads without help (downloaded directly).
    static let mediaExtensions: Set<String> = ["mp4", "m4v", "mov", "m4a", "mp3", "aac", "wav", "aif", "aiff", "caf", "flac",
                                               "png", "jpg", "jpeg", "gif", "heic", "webp"]

    /// Sites whose addresses are always pages with a player (straight to yt-dlp).
    static let platforms = ["youtube.com", "youtu.be", "youtube-nocookie.com", "vimeo.com", "ardmediathek.de", "ard.de", "zdf.de", "3sat.de",
                            "arte.tv", "phoenix.de", "kika.de", "br.de", "wdr.de", "ndr.de", "swr.de", "mdr.de", "hr.de", "rbb-online.de",
                            "tagesschau.de", "planet-schule.de", "orf.at", "srf.ch", "dailymotion.com", "ted.com", "twitch.tv", "tiktok.com",
                            "instagram.com", "facebook.com", "x.com", "twitter.com", "soundcloud.com"]

    static func isPlatform(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return platforms.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Classifies the text of the address field. "youtu.be/…" without scheme gets https://.
    static func classify(_ input: String) -> Result<VideoLink, DownloadError> {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        var candidate = text
        if !candidate.contains("://") {
            if candidate.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:[0-9]+)?([/?#].*)?$"#, options: .regularExpression) != nil {
                candidate = "https://" + candidate
            } else if let scheme = candidate.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) {
                return .failure(.unsupportedScheme(String(candidate[scheme].dropLast()).lowercased()))
            } else {
                return .failure(.invalid)
            }
        }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else { return .failure(.invalid) }
        guard scheme == "http" || scheme == "https" else { return .failure(.unsupportedScheme(scheme)) }
        guard let host = url.host, host.contains(".") || host == "localhost", !candidate.contains(" ") else { return .failure(.invalid) }
        if mediaExtensions.contains(url.pathExtension.lowercased()) { return .success(.media(url)) }
        return .success(.page(url))
    }
}

/// A file name without characters the Finder or the project dislike.
func sanitizedFileName(_ name: String) -> String {
    let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    return cleaned.isEmpty ? "Download" : String(cleaned.prefix(120))
}

/// Pictures, videos and sound Erklärbär can use.
func isUsableMedia(_ url: URL) -> Bool {
    guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
    return [UTType.image, .movie, .audio].contains { type.conforms(to: $0) }
}

// MARK: - Direct download

/// Downloads a media file with URLSession: progress with size, cancel, and it refuses web pages,
/// streaming lists and HTTP errors (checked as soon as the response arrives).
final class MediaDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Progress: Equatable, Sendable {
        var received: Int64
        var expected: Int64?
    }

    private let lock = NSLock()
    private let folder: URL
    private let progress: @Sendable (Progress) -> Void
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var file: URL?
    private var failure: DownloadError?
    private var lastReport = Date.distantPast

    init(folder: URL, configuration: URLSessionConfiguration = .ephemeral, progress: @escaping @Sendable (Progress) -> Void) {
        self.folder = folder
        self.progress = progress
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func download(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                let start: URLSessionDownloadTask? = lock.withLock {
                    if let failure { c.resume(throwing: failure); return nil }
                    continuation = c
                    let t = session?.downloadTask(with: url)
                    task = t
                    return t
                }
                start?.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let t: URLSessionDownloadTask? = lock.withLock {
            if failure == nil { failure = .cancelled }
            return task
        }
        t?.cancel()
    }

    /// A web page, a streaming list or an HTTP error instead of a media file.
    static func problem(with response: URLResponse?) -> DownloadError? {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return .http(http.statusCode) }
        guard let mime = response?.mimeType?.lowercased() else { return nil }
        if mime.contains("mpegurl") { return .playlist }
        if mime.hasPrefix("text/") || mime.contains("html") || mime.contains("json") || mime.contains("xml") { return .notMedia }
        return nil
    }

    /// File name for the download: from the response, with an extension macOS understands.
    static func fileName(for response: URLResponse?, url: URL?) -> String {
        let suggested = response?.suggestedFilename ?? url?.lastPathComponent ?? ""
        var name = sanitizedFileName(suggested.isEmpty ? "Download" : suggested)
        if !isUsableMedia(URL(fileURLWithPath: name)) {
            let mime = response?.mimeType?.lowercased() ?? ""
            let byType = ["audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/aac": "aac",
                          "audio/wav": "wav", "audio/x-wav": "wav", "audio/aiff": "aiff", "audio/flac": "flac", "video/mp4": "mp4",
                          "video/quicktime": "mov", "video/x-m4v": "m4v", "application/mp4": "mp4", "image/png": "png",
                          "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/heic": "heic"]
            let ext = byType[mime] ?? (mime.hasPrefix("audio/") ? "mp3" : mime.hasPrefix("image/") ? "png" : "mp4")
            name = (name as NSString).deletingPathExtension + "." + ext
        }
        return name
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let problem = Self.problem(with: downloadTask.response) {
            lock.withLock { if failure == nil { failure = problem } }
            downloadTask.cancel()
            return
        }
        let now = Date()
        let report: Bool = lock.withLock {
            guard now.timeIntervalSince(lastReport) >= 0.1 || totalBytesWritten == totalBytesExpectedToWrite else { return false }
            lastReport = now
            return true
        }
        if report { progress(Progress(received: totalBytesWritten, expected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns: move it now.
        if let problem = Self.problem(with: downloadTask.response) {
            lock.withLock { if failure == nil { failure = problem } }
            return
        }
        let dest = folder.appendingPathComponent(Self.fileName(for: downloadTask.response, url: downloadTask.originalRequest?.url))
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            progress(Progress(received: size, expected: size))
            lock.withLock { file = dest }
        } catch {
            lock.withLock { if failure == nil { failure = .network(error.localizedDescription) } }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (c, file, failure) = lock.withLock { () -> (CheckedContinuation<URL, Error>?, URL?, DownloadError?) in
            let c = continuation
            continuation = nil
            return (c, self.file, self.failure)
        }
        session.finishTasksAndInvalidate()
        if let failure {
            c?.resume(throwing: failure)
        } else if let error {
            let ns = error as NSError
            c?.resume(throwing: ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled ? DownloadError.cancelled
                                                                                              : DownloadError.network(error.localizedDescription))
        } else if let file {
            c?.resume(returning: file)
        } else {
            c?.resume(throwing: DownloadError.network("Es kamen keine Daten an."))
        }
    }
}

// MARK: - yt-dlp

/// yt-dlp (https://github.com/yt-dlp/yt-dlp) for pages of video platforms.
enum YTDLP {
    /// Picture (H.264 in MP4) and sound (M4A) as two separate files – joined afterwards, no
    /// ffmpeg needed; a single MP4 with both when the site has no separate streams. Never HLS
    /// (without ffmpeg that can arrive as MPEG-TS, which macOS does not read).
    static func formatSelector(_ quality: VideoQuality) -> String {
        let height = quality.maxHeight.map { "[height<=\($0)]" } ?? ""
        let heightIfKnown = quality.maxHeight.map { "[height<=?\($0)]" } ?? ""
        let noHLS = "[protocol!*=m3u8]"
        return "(bv[vcodec^=avc1][ext=mp4]\(height)\(noHLS),ba[ext=m4a]\(noHLS))"
            + "/b[ext=mp4][vcodec^=?avc1]\(heightIfKnown)\(noHLS)/b[ext=mp4]\(heightIfKnown)\(noHLS)"
            + "/ba[ext=m4a]\(noHLS)/ba[ext=mp3]"
    }

    static func arguments(for url: URL, into folder: URL, quality: VideoQuality, runtime: JSRuntime?) -> [String] {
        var args = ["--ignore-config", "--no-playlist", "--newline", "--no-mtime", "--no-simulate", "--progress",
                    "--progress-template", "download:[pp-progress] %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s",
                    "--print", "before_dl:[pp-title] %(title)s",
                    "--print", "before_dl:[pp-format] %(vcodec)s|%(acodec)s",
                    "--print", "after_move:[pp-file] %(filepath)s"]
        if let runtime { args += ["--js-runtimes", runtime.argument] }
        args += ["-f", formatSelector(quality), "-o", folder.appendingPathComponent("video.f%(format_id)s.%(ext)s").path]
        return args + ["--", url.absoluteString]
    }

    enum Event: Equatable {
        case progress(received: Double, total: Double?)
        case percent(Double)
        case title(String)
        case file(String)
        /// What the next file contains (codecs; "none" = no picture or no sound).
        case format(video: Bool, audio: Bool)
    }

    /// One line of yt-dlp's output (the templates above, plus its normal progress line).
    static func parse(_ line: String) -> Event? {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("[pp-title] ") { return .title(String(l.dropFirst(11)).trimmingCharacters(in: .whitespaces)) }
        if l.hasPrefix("[pp-file] ") { return .file(String(l.dropFirst(10)).trimmingCharacters(in: .whitespaces)) }
        if l.hasPrefix("[pp-progress] ") {
            let parts = l.dropFirst(14).split(separator: " ").map { Double($0) }
            guard let received = parts.first ?? nil else { return nil }
            let total = parts.dropFirst().compactMap { $0 }.first { $0 > 0 }
            return .progress(received: received, total: total)
        }
        if l.hasPrefix("[download]"), let r = l.range(of: #"[0-9]+(\.[0-9]+)?%"#, options: .regularExpression), let p = Double(l[r].dropLast()) {
            return .percent(p)
        }
        if l.hasPrefix("[pp-format] ") {
            let codecs = l.dropFirst(12).split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard codecs.count == 2 else { return nil }
            return .format(video: codecs[0] != "none", audio: codecs[1] != "none")
        }
        return nil
    }

    /// The last "ERROR:" line, without the extractor prefix ("[youtube] abc: ").
    static func errorMessage(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        var message = lines.last { $0.hasPrefix("ERROR:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) } ?? lines.last ?? "unbekannter Fehler"
        if message.hasPrefix("["), let close = message.firstIndex(of: "]") {
            message = String(message[message.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if let colon = message.range(of: ": "), message[..<colon.lowerBound].count < 40, !message[..<colon.lowerBound].contains(" ") {
                message = String(message[colon.upperBound...])
            }
        }
        return String(message.prefix(300))
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// One yt-dlp run: progress from its output, cancel terminates the process.
final class YTDLPProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var found: YtDlpAdvice?

    /// After a failure: what would probably help (a newer yt-dlp, a JavaScript runtime).
    var advice: YtDlpAdvice? { lock.withLock { found } }

    func cancel() {
        let p: Process? = lock.withLock {
            cancelled = true
            return process
        }
        if let p, p.isRunning { p.terminate() }
    }

    /// Returns every file yt-dlp wrote (picture and sound, or one with both).
    func run(tool: URL, arguments: [String], folder: URL, onEvent: @escaping @Sendable (YTDLP.Event) -> Void) async throws -> (files: [URL], title: String?) {
        let p = Process()
        p.executableURL = tool
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        // yt-dlp looks for helpers (a JavaScript runtime, ffmpeg) in the PATH.
        let path = [tool.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"] + (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        env["PATH"] = path.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        p.currentDirectoryURL = folder
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }

        let result: (status: Int32, title: String?, files: [String], stderr: String) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                do {
                    try lock.withLock {
                        if cancelled { throw DownloadError.cancelled }
                        try p.run()
                        process = p
                    }
                } catch {
                    c.resume(throwing: error)
                    return
                }
                // Blocking reads on their own threads (a full stderr pipe would stop yt-dlp).
                let group = DispatchGroup()
                let errData = DataBox()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errData.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    var title: String?, files: [String] = []
                    var buffer = Data()
                    func handle(_ line: String) {
                        guard let event = YTDLP.parse(line) else { return }
                        if case .title(let t) = event { title = t }
                        if case .file(let f) = event, !files.contains(f) { files.append(f) }
                        onEvent(event)
                    }
                    let h = out.fileHandleForReading
                    while true {
                        let data = h.availableData
                        if data.isEmpty { break }
                        buffer.append(data)
                        while let nl = buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                            handle(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
                            buffer.removeSubrange(buffer.startIndex...nl)
                        }
                    }
                    if !buffer.isEmpty { handle(String(decoding: buffer, as: UTF8.self)) }
                    exited.wait()
                    group.wait()
                    c.resume(returning: (p.terminationStatus, title, files, String(decoding: errData.data, as: UTF8.self)))
                }
            }
        } onCancel: {
            cancel()
        }
        if lock.withLock({ cancelled }) { throw DownloadError.cancelled }
        guard result.status == 0 else {
            let advice = YtDlpAdvice.advice(for: result.stderr)
            lock.withLock { found = advice }
            if result.stderr.contains("Requested format is not available") && advice != .runtime { throw DownloadError.unsupportedFormat }
            throw DownloadError.tool(YTDLP.errorMessage(result.stderr))
        }
        let fm = FileManager.default
        let printed = result.files.filter { fm.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        if !printed.isEmpty { return (printed, result.title) }
        // Older versions without --print after_move: the files in the folder.
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let written = files.filter { $0.lastPathComponent.hasPrefix("video.") && isUsableMedia($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !written.isEmpty else { throw DownloadError.nothing }
        return (written, result.title)
    }
}

// MARK: - Saving

enum VideoSaver {
    /// Whether a file has a picture and sound.
    static func contents(of url: URL) async -> (video: Bool, audio: Bool) {
        let asset = AVURLAsset(url: url)
        let v = (try? await asset.loadTracks(withMediaType: .video))?.isEmpty == false
        let a = (try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false
        return (v, a)
    }

    /// A picture-only and a sound-only file into one MP4 (passthrough – nothing is re-encoded).
    static func mux(video: URL, audio: URL, to target: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        guard let v = try await videoAsset.loadTracks(withMediaType: .video).first,
              let a = try await audioAsset.loadTracks(withMediaType: .audio).first,
              let cv = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw DownloadError.save("Bild oder Ton fehlt")
        }
        try cv.insertTimeRange(try await v.load(.timeRange), of: v, at: .zero)
        try ca.insertTimeRange(try await a.load(.timeRange), of: a, at: .zero)
        cv.preferredTransform = try await v.load(.preferredTransform)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw DownloadError.save("AVFoundation kann die Spuren nicht zusammenführen")
        }
        let part = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-\(target.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: part) }
        try await session.export(to: part, as: .mp4)
        try FileManager.default.moveItem(at: part, to: target)
    }

    /// The files of a yt-dlp run as one file named after the video: picture and sound joined, or
    /// the single file with both (or with sound only) kept.
    static func finish(_ files: [URL], title: String, in folder: URL) async throws -> URL {
        var parts: [(url: URL, video: Bool, audio: Bool)] = []
        for file in files {
            let c = await contents(of: file)
            parts.append((file, c.video, c.audio))
        }
        let name = sanitizedFileName(title)
        do {
            if let v = parts.first(where: { $0.video && !$0.audio }), let a = parts.first(where: { !$0.video && $0.audio }) {
                let target = folder.appendingPathComponent(name + ".mp4")
                try await mux(video: v.url, audio: a.url, to: target)
                return target
            }
            guard let single = parts.first(where: { $0.video && $0.audio }) ?? parts.first(where: { $0.audio }) ?? parts.first(where: { $0.video }) else {
                throw DownloadError.nothing
            }
            let ext = single.url.pathExtension.isEmpty ? "mp4" : single.url.pathExtension.lowercased()
            let target = folder.appendingPathComponent(name + "." + ext)
            try FileManager.default.moveItem(at: single.url, to: target)
            return target
        } catch let e as DownloadError {
            throw e
        } catch {
            throw DownloadError.save(error.localizedDescription)
        }
    }
}
