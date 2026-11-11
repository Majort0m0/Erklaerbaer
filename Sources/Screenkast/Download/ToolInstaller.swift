import Foundation
import CryptoKit

/// A step of setting up a helper program (shown with progress in the sheet and the settings).
enum ToolSetupStep: Equatable, Sendable {
    case downloading(received: Int64, expected: Int64?)
    case verifying
    case unpacking
    case testing

    var rank: Int {
        switch self {
        case .downloading: return 0
        case .verifying: return 1
        case .unpacking: return 2
        case .testing: return 3
        }
    }
}

enum ToolSetupError: LocalizedError, Equatable {
    case http(Int)
    case network(String)
    case noChecksum
    case checksumMismatch
    case unpack
    case doesNotRun
    case tooOld(String)
    case files(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .http(let code): return "GitHub antwortet mit Fehler \(code). Versuch es später noch einmal."
        case .network(let s): return "Laden fehlgeschlagen: \(s)"
        case .noChecksum: return "Zur Datei fehlt die Prüfsumme – deshalb richtet Erklärbär sie nicht ein."
        case .checksumMismatch: return "Die Prüfsumme stimmt nicht – die Datei ist gelöscht. Versuch es später noch einmal."
        case .unpack: return "Das Archiv ließ sich nicht entpacken."
        case .doesNotRun: return "Das Programm startet auf diesem Mac nicht."
        case .tooOld(let v): return "Die geladene Version \(v) ist zu alt."
        case .files(let s): return "Ablegen fehlgeschlagen: \(s)"
        case .cancelled: return "Abgebrochen."
        }
    }
}

/// The official download of a program and its checksum list on GitHub.
struct ToolAsset: Equatable, Sendable {
    var download: URL
    var checksums: URL
    /// The file's name in the checksum list.
    var name: String

    static let ytdlp = ToolAsset(download: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!,
                                 checksums: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS")!,
                                 name: "yt-dlp_macos")

    static func deno(appleSilicon: Bool) -> ToolAsset {
        let name = "deno-\(appleSilicon ? "aarch64" : "x86_64")-apple-darwin.zip"
        let base = "https://github.com/denoland/deno/releases/latest/download/"
        return ToolAsset(download: URL(string: base + name)!, checksums: URL(string: base + name + ".sha256sum")!, name: name)
    }

    static func asset(for tool: ManagedTool, appleSilicon: Bool) -> ToolAsset {
        tool == .ytdlp ? ytdlp : deno(appleSilicon: appleSilicon)
    }
}

enum Checksums {
    /// The SHA-256 of `name` in a checksum list ("<hash>  <name>" per line, as in yt-dlp's
    /// SHA2-256SUMS). A file with a single hash (Deno's .sha256sum) counts for that file.
    static func expected(for name: String, in text: String) -> String? {
        func isHash<S: StringProtocol>(_ s: S) -> Bool { s.count == 64 && s.allSatisfy(\.isHexDigit) }
        var unnamed: [String] = []
        var named = false
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = parts.first, isHash(first) else {
                // Other layouts ("Hash : …"): any hash on the line.
                unnamed += parts.filter { isHash($0) }.map { $0.lowercased() }
                continue
            }
            guard let file = parts.dropFirst().first else { unnamed.append(first.lowercased()); continue }
            named = true
            let clean = file.hasPrefix("*") ? String(file.dropFirst()) : String(file)
            if clean == name || (clean as NSString).lastPathComponent == name { return first.lowercased() }
        }
        // A list with names but not this one: no checksum for it.
        return !named && unnamed.count == 1 ? unnamed[0] : nil
    }

    /// SHA-256 of a file, read in pieces (the binaries are tens of megabytes).
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Downloads a program into the tools folder: checksum list, file (with progress), checksum,
/// unzip (Deno, with /usr/bin/ditto), executable bit, a test run with --version – then it takes
/// the place of the old copy. Cancelling or any failure leaves nothing behind.
final class ToolInstaller: @unchecked Sendable {
    let folder: URL
    let configuration: URLSessionConfiguration
    let appleSilicon: Bool
    private let lock = NSLock()
    private var cancelled = false
    private var current: ToolDownload?

    init(folder: URL, configuration: URLSessionConfiguration = .ephemeral, appleSilicon: Bool = Hardware.isAppleSilicon) {
        self.folder = folder
        self.configuration = configuration
        self.appleSilicon = appleSilicon
    }

    func cancel() {
        let d: ToolDownload? = lock.withLock {
            cancelled = true
            return current
        }
        d?.cancel()
    }

    private func checkCancelled() throws {
        if lock.withLock({ cancelled }) || Task.isCancelled { throw ToolSetupError.cancelled }
    }

    func install(_ tool: ManagedTool, step: @escaping @Sendable (ToolSetupStep) -> Void) async throws -> FoundTool {
        let fm = FileManager.default
        let asset = ToolAsset.asset(for: tool, appleSilicon: appleSilicon)
        let work = folder.appendingPathComponent(".einrichten-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: work, withIntermediateDirectories: true) } catch { throw ToolSetupError.files(error.localizedDescription) }
        defer { try? fm.removeItem(at: work) }

        try checkCancelled()
        step(.downloading(received: 0, expected: nil))
        let list = try await fetch(asset.checksums)
        guard let expected = Checksums.expected(for: asset.name, in: String(decoding: list, as: UTF8.self)) else { throw ToolSetupError.noChecksum }
        let file = work.appendingPathComponent(asset.name)
        let download = ToolDownload(configuration: configuration) { received, total in step(.downloading(received: received, expected: total)) }
        try lock.withLock {
            if cancelled { throw ToolSetupError.cancelled }
            current = download
        }
        try await download.download(asset.download, to: file)
        lock.withLock { current = nil }

        try checkCancelled()
        step(.verifying)
        let actual: String
        do { actual = try Checksums.sha256(of: file) } catch { throw ToolSetupError.files(error.localizedDescription) }
        guard actual == expected else { throw ToolSetupError.checksumMismatch }

        var binary = file
        if tool == .deno {
            step(.unpacking)
            let out = work.appendingPathComponent("entpackt", isDirectory: true)
            try Self.unzip(file, into: out)
            binary = out.appendingPathComponent("deno")
            guard fm.fileExists(atPath: binary.path) else { throw ToolSetupError.unpack }
        }
        do { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path) } catch { throw ToolSetupError.files(error.localizedDescription) }

        try checkCancelled()
        step(.testing)
        // The first start of the yt-dlp binary unpacks itself: give it time.
        guard let version = ToolProbe.version(binary, timeout: 120) else { throw ToolSetupError.doesNotRun }
        if tool == .deno, let minimum = JSRuntimeKind.deno.minimum, !ToolVersion.isAtLeast(version, minimum) { throw ToolSetupError.tooOld(version) }
        try checkCancelled()

        let target = folder.appendingPathComponent(tool.fileName)
        do {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: binary, to: target)
        } catch {
            throw ToolSetupError.files(error.localizedDescription)
        }
        var manifest = ToolManifest.load(from: folder)
        manifest.entries[tool.fileName] = ToolManifest.Entry(version: version, sha256: actual, installed: Date(), source: asset.download.absoluteString)
        try? manifest.save(to: folder)
        return FoundTool(url: target, version: version, origin: .managed)
    }

    /// A small file (the checksum list).
    private func fetch(_ url: URL) async throws -> Data {
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw ToolSetupError.http(http.statusCode) }
            return data
        } catch let e as ToolSetupError {
            throw e
        } catch {
            let ns = error as NSError
            if error is CancellationError || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) { throw ToolSetupError.cancelled }
            throw ToolSetupError.network(error.localizedDescription)
        }
    }

    /// Unpacks a zip archive with /usr/bin/ditto (keeps the executable bit).
    static func unzip(_ zip: URL, into folder: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, folder.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { throw ToolSetupError.unpack }
        guard exited.wait(timeout: .now() + 120) == .success, p.terminationStatus == 0 else { throw ToolSetupError.unpack }
    }
}

/// One download with progress into a given file; HTTP errors are errors, cancel stops it.
final class ToolDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (Int64, Int64?) -> Void
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private var failure: ToolSetupError?
    private var finished = false
    private var lastReport = Date.distantPast

    init(configuration: URLSessionConfiguration, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.progress = progress
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func download(_ url: URL, to destination: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let start: URLSessionDownloadTask? = lock.withLock {
                    if let failure { c.resume(throwing: failure); return nil }
                    continuation = c
                    self.destination = destination
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

    private static func problem(_ response: URLResponse?) -> ToolSetupError? {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return .http(http.statusCode) }
        return nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let problem = Self.problem(downloadTask.response) {
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
        if report { progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns: move it now.
        if let problem = Self.problem(downloadTask.response) {
            lock.withLock { if failure == nil { failure = problem } }
            return
        }
        guard let dest = lock.withLock({ destination }) else { return }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            progress(size, size)
            lock.withLock { finished = true }
        } catch {
            lock.withLock { if failure == nil { failure = .files(error.localizedDescription) } }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (c, done, failure, dest) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Bool, ToolSetupError?, URL?) in
            let c = continuation
            continuation = nil
            return (c, finished, self.failure, destination)
        }
        session.finishTasksAndInvalidate()
        if let failure {
            if let dest { try? FileManager.default.removeItem(at: dest) }
            c?.resume(throwing: failure)
        } else if let error {
            let ns = error as NSError
            c?.resume(throwing: ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled ? ToolSetupError.cancelled : ToolSetupError.network(error.localizedDescription))
        } else if done {
            c?.resume()
        } else {
            c?.resume(throwing: ToolSetupError.network("Es kamen keine Daten an."))
        }
    }
}
