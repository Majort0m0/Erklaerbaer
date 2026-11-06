import Foundation
import AVFoundation

/// Crash safety for recordings.
///
/// - Screen and camera movies are written as fragmented movies: if the app crashes or is
///   force-quit, the files stay readable up to the last fragment (≈ 1 s).
/// - While recording, the recording info and the cursor track are saved every few seconds
///   (`RecordingProgressWriter`).
/// - On the next launch, `recoverAll()` turns such folders into normal projects.
enum RecordingRecovery {
    static let progressFile = "recording-progress.json"
    static let failedFile = "recording-progress.failed.json"
    static let fragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

    /// Video compression properties for crash-safe files: fragments can only end at key frames,
    /// so a key frame every second keeps the possible loss at about one second.
    static func keyFrameProperties(fps: Int) -> [String: Any] {
        [AVVideoMaxKeyFrameIntervalKey: fps, AVVideoMaxKeyFrameIntervalDurationKey: 1.0]
    }

    /// Makes a movie writer crash-safe (call before `startWriting`).
    static func prepare(_ writer: AVAssetWriter) {
        writer.movieFragmentInterval = fragmentInterval
    }

    /// Project folders whose recording was interrupted (progress saved, never finished).
    /// Folders written to within `minimumAge` seconds are skipped: that recording may still be running.
    static func interruptedProjects(in library: URL, minimumAge: TimeInterval = 15) -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        func age(_ url: URL) -> TimeInterval {
            let date = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            return Date().timeIntervalSince(date)
        }
        return items.filter { folder in
            folder.pathExtension == Project.fileExtension
                && fm.fileExists(atPath: folder.appendingPathComponent(progressFile).path)
                && !fm.fileExists(atPath: folder.appendingPathComponent("recording.json").path)
                && ["screen.mov", "camera.mov", "cursor.json", progressFile]
                    .allSatisfy { age(folder.appendingPathComponent($0)) >= minimumAge }
        }
    }

    struct Result {
        var recovered: [URL] = []
        var failed: [URL] = []
    }

    /// Recovers all interrupted recordings in the library.
    static func recoverAll(in library: URL = Project.libraryURL, minimumAge: TimeInterval = 15) async -> Result {
        var result = Result()
        for url in interruptedProjects(in: library, minimumAge: minimumAge) {
            do {
                result.recovered.append(try await recover(url))
            } catch {
                NSLog("Screenkast: Aufnahme %@ ließ sich nicht wiederherstellen: %@", url.lastPathComponent, "\(error)")
                // Don't try again on every launch.
                try? FileManager.default.moveItem(at: url.appendingPathComponent(progressFile),
                                                  to: url.appendingPathComponent(failedFile))
                result.failed.append(url)
            }
        }
        return result
    }

    /// Turns an interrupted recording into a normal project. Returns its (renamed) folder.
    static func recover(_ folder: URL) async throws -> URL {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var info = try dec.decode(RecordingInfo.self, from: Data(contentsOf: folder.appendingPathComponent(progressFile)))

        let screen = AVURLAsset(url: folder.appendingPathComponent(info.videoFile))
        guard let video = try await screen.loadTracks(withMediaType: .video).first else {
            throw RecorderError.writerFailed("keine lesbaren Bilder in \(info.videoFile)")
        }
        let duration = try await video.load(.timeRange).duration.seconds
        guard duration.isFinite, duration >= 0.3 else {
            throw RecorderError.writerFailed("Aufnahme zu kurz (\(duration) s)")
        }
        info.duration = duration

        if let cameraFile = info.cameraFile {
            let camera = AVURLAsset(url: folder.appendingPathComponent(cameraFile))
            let track = try? await camera.loadTracks(withMediaType: .video).first
            let range = try? await track?.load(.timeRange)
            if (range?.duration.seconds ?? 0) <= 0 { info.cameraFile = nil }
        }

        var cursor = (try? dec.decode(CursorTrack.self, from: Data(contentsOf: folder.appendingPathComponent("cursor.json")))) ?? CursorTrack()
        cursor.samples.removeAll { $0.t > duration }
        cursor.clicks.removeAll { $0.t > duration }
        cursor.keys?.removeAll { $0.t > duration }
        // Cursor images that never made it to disk can't be used.
        let fm = FileManager.default
        if cursor.images.contains(where: { !fm.fileExists(atPath: folder.appendingPathComponent($0.file).path) }) {
            cursor.images = []
            for i in cursor.samples.indices { cursor.samples[i].c = -1 }
        }

        // Mark the folder so it's recognizable in the library.
        let base = folder.deletingPathExtension().lastPathComponent
        var target = folder.deletingLastPathComponent()
            .appendingPathComponent("\(base) (wiederhergestellt).\(Project.fileExtension)", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.deletingLastPathComponent()
                .appendingPathComponent("\(base) (wiederhergestellt \(n)).\(Project.fileExtension)", isDirectory: true)
            n += 1
        }
        try fm.moveItem(at: folder, to: target)

        var settings = EditSettings()
        settings.zoomSegments = AutoZoom.segments(for: cursor.clicks, duration: duration, scale: settings.defaultZoom)
        let project = Project(url: target, info: info, cursor: cursor, settings: settings)
        try project.saveAll()
        try? fm.removeItem(at: target.appendingPathComponent(progressFile))
        return target
    }
}

/// Saves the recording info once and the cursor track every few seconds while recording,
/// so an interrupted recording can be recovered. File writing runs on a background queue.
final class RecordingProgressWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "screenkast.recording-progress", qos: .utility)
    private let folder: URL
    private var writtenImages = 0

    init(folder: URL, info: RecordingInfo) throws {
        self.folder = folder
        try Self.encoder.encode(info).write(to: folder.appendingPathComponent(RecordingRecovery.progressFile), options: .atomic)
    }

    /// Saves a snapshot of the cursor track and new cursor images (asynchronously).
    func save(cursor: CursorTrack, images: [Data]) {
        queue.async { [self] in
            let fm = FileManager.default
            if writtenImages < images.count {
                try? fm.createDirectory(at: folder.appendingPathComponent("cursors"), withIntermediateDirectories: true)
                for i in writtenImages..<min(images.count, cursor.images.count) {
                    try? images[i].write(to: folder.appendingPathComponent(cursor.images[i].file), options: .atomic)
                }
                writtenImages = min(images.count, cursor.images.count)
            }
            try? Self.encoder.encode(cursor).write(to: folder.appendingPathComponent("cursor.json"), options: .atomic)
        }
    }

    /// Waits until all pending saves are on disk.
    func flush() {
        queue.sync {}
    }

    /// The recording was finished normally: the progress file is no longer needed.
    func finish() {
        queue.sync {}
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(RecordingRecovery.progressFile))
    }

    private static var encoder: JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }
}
