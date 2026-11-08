import Foundation
import AVFoundation
import CoreImage

/// Projects that don't come from a recording: an own video as the main track, or an empty canvas
/// for clips, pictures and texts.
enum ProjectFactory {
    enum Failure: LocalizedError {
        case noVideo
        var errorDescription: String? { "Die Datei enthält kein Video." }
    }

    /// A project folder in the library named after `name` (numbered if it exists).
    private static func newFolder(named name: String, in library: URL) throws -> URL {
        let fm = FileManager.default
        let base = name.replacingOccurrences(of: "/", with: "-")
        var url = library.appendingPathComponent("\(base).\(Project.fileExtension)", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = library.appendingPathComponent("\(base) \(n).\(Project.fileExtension)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The look for own material: the full picture, no frame (it is not a screen recording).
    private static func plainSettings(aspect: OutputAspect) -> EditSettings {
        var s = EditSettings()
        s.autoZoom = false
        s.zoomSegments = []
        s.padding = 0
        s.cornerRadius = 0
        s.shadow = 0
        s.showCursor = false
        s.clickEffect = false
        s.aspect = aspect
        s.removeEcho = false
        return s
    }

    /// An own video becomes the main track (copied into the project; on APFS a clone, no extra
    /// space). Its sound counts as the microphone: voice enhancement, captions and pause removal work.
    static func importVideo(_ source: URL, into library: URL = ProjectLocations.current) async throws -> Project {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rotation = VideoRotation.degrees(transform)
        let shown = rotation == 90 || rotation == 270 ? CGSize(width: size.height, height: size.width) : size
        let duration = try await asset.load(.duration).seconds
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        let name = source.deletingPathExtension().lastPathComponent
        let folder = try newFolder(named: name, in: library)
        let file = "screen." + (source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased())
        do {
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(file))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        var info = RecordingInfo(pixelWidth: Int(abs(shown.width)), pixelHeight: Int(abs(shown.height)), pointPixelScale: 1,
                                 duration: duration, createdAt: Date(), sourceName: name, hasMicrophone: hasAudio,
                                 cameraFile: nil, audioTracks: hasAudio ? ["mic"] : [])
        info.videoFile = file
        info.rotation = rotation == 0 ? nil : rotation
        let ratio = abs(shown.width) / max(1, abs(shown.height))
        let aspect: OutputAspect = abs(ratio - 16.0 / 9.0) < 0.03 ? .wide : abs(ratio - 9.0 / 16.0) < 0.03 ? .vertical
            : abs(ratio - 1) < 0.03 ? .square : abs(ratio - 4.0 / 3.0) < 0.03 ? .classic : .source
        let project = Project(url: folder, info: info, cursor: CursorTrack(), settings: plainSettings(aspect: aspect))
        try project.saveAll()
        return project
    }

    /// An empty canvas (black) of `length` seconds; clips are inserted into it, pictures, videos
    /// and texts placed on top. The timeline grows with every inserted clip.
    static func empty(length: Double, aspect: OutputAspect, name: String = "Neues Projekt",
                      into library: URL = ProjectLocations.current) async throws -> Project {
        let folder = try newFolder(named: name, in: library)
        let size = aspect == .vertical ? CGSize(width: 1080, height: 1920) : aspect == .square ? CGSize(width: 1080, height: 1080)
            : aspect == .classic ? CGSize(width: 1440, height: 1080) : CGSize(width: 1920, height: 1080)
        let url = folder.appendingPathComponent("screen.mov")
        try await writeBlank(to: url, size: size, length: length)
        var info = RecordingInfo(pixelWidth: Int(size.width), pixelHeight: Int(size.height), pointPixelScale: 1, duration: length,
                                 createdAt: Date(), sourceName: "Leeres Projekt", hasMicrophone: false, cameraFile: nil, audioTracks: [])
        info.blank = true
        var settings = plainSettings(aspect: aspect == .source ? .wide : aspect)
        settings.background = .color(red: 0, green: 0, blue: 0)
        let project = Project(url: folder, info: info, cursor: CursorTrack(), settings: settings)
        try project.saveAll()
        return project
    }

    /// A black video: one frame at the start and one at the end (nothing changes in between).
    private static func writeBlank(to url: URL, size: CGSize, length: Double) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecorderError.writerFailed("Leeres Projekt") }
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        let last = max(0.1, length - 1.0 / 30)
        for t in [0, last] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            context.render(black, to: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: length, preferredTimescale: 600))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? RecorderError.writerFailed("Leeres Projekt") }
    }

    /// `--newproject <folder> [video …]`: one video → a project from it; none or several → an
    /// empty 16:9 project with the videos lined up as clips. Prints the project path.
    @MainActor
    static func commandLine(folder: String, files: [String]) -> Int32 {
        var code: Int32 = 0
        var done = false
        Task { @MainActor in
            do {
                let library = URL(fileURLWithPath: folder)
                try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
                let project: Project
                if files.count == 1 {
                    project = try await importVideo(URL(fileURLWithPath: files[0]), into: library)
                } else {
                    project = try await empty(length: 10, aspect: .wide, into: library)
                    let editor = EditorModel(project: project)
                    for f in files {
                        let url = URL(fileURLWithPath: f)
                        let length = try await AVURLAsset(url: url).load(.duration).seconds
                        guard let file = editor.importMedia(url) else { continue }
                        editor.placeInsert(InsertClip(file: file, name: url.deletingPathExtension().lastPathComponent,
                                                      at: editor.duration, duration: length, fileDuration: length))
                    }
                    editor.saveNow()
                }
                print(project.url.path)
            } catch {
                print("Fehler: \(error.localizedDescription)")
                code = 1
            }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return code
    }
}
