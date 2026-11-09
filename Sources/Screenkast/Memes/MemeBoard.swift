import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// One filled place of the board.
struct MemeSlot: Codable, Equatable {
    var file: String
    var thumb: String
    var title: String
    /// Author and license, for the credits of a video (nil for own files).
    var credit: String?
    var width: Double
    var height: Double
    var duration: Double
    /// See-through parts (nil: none).
    var transparent: Bool? = nil
    /// How long it stays in the live picture: nil as long as the clip, but at least a few seconds
    /// (short ones repeat); 0 until it is pressed again.
    var showFor: Double? = nil

    static let shortest = 3.0

    /// Seconds in the live picture, nil: until pressed again.
    var liveLength: Double? {
        if showFor == 0 { return nil }
        return showFor ?? max(duration, Self.shortest)
    }
}

/// Every meme becomes a small movie on the way in, so that editor and live picture only deal with one format.
enum MemeConverter {
    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "Diese Datei kann Erklärbär nicht lesen. Möglich sind GIF, Bilder und Videos im Format MP4 oder MOV." }
    }

    static let longestSide: CGFloat = 720
    static let maxLength = 12.0
    static let stillLength = 3.0

    typealias Result = (size: CGSize, duration: Double, transparent: Bool)

    static func convert(_ source: URL, to target: URL) async throws -> Result {
        try? FileManager.default.removeItem(at: target)
        let type = UTType(filenameExtension: source.pathExtension)
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
            return try await convertMovie(source, to: target)
        }
        guard let images = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(images) > 0 else { throw Failure.unreadable }
        return try await convertImages(images, to: target)
    }

    private static func convertMovie(_ source: URL, to target: URL) async throws -> Result {
        let asset = AVURLAsset(url: source)
        guard (try? await asset.load(.isPlayable)) == true, let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { throw Failure.unreadable }
        let length = min(maxLength, try await asset.load(.duration).seconds)
        export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 600))
        // Phone videos are often stored sideways with a note how to turn them: this makes the picture really upright.
        export.videoComposition = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
        try await export.export(to: target, as: .mov)
        let result = AVURLAsset(url: target)
        guard let track = try await result.loadTracks(withMediaType: .video).first else { throw Failure.unreadable }
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        return (CGSize(width: abs(size.width), height: abs(size.height)), try await result.load(.duration).seconds, false)
    }

    private static func delay(_ images: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(images, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let value = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
        return value < 0.02 ? 0.1 : value
    }

    /// A still picture the way it is meant to be seen (photos carry a note how to turn them).
    private static func image(_ images: CGImageSource, _ index: Int) -> CGImage? {
        guard CGImageSourceGetCount(images) == 1 else { return CGImageSourceCreateImageAtIndex(images, index, nil) }
        return CGImageSourceCreateThumbnailAtIndex(images, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
        ] as CFDictionary)
    }

    /// True if some part of the picture can be seen through.
    private static func hasTransparency(_ image: CGImage) -> Bool {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast,
              let c = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = c.data else { return false }
        c.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let pixels = data.bindMemory(to: UInt8.self, capacity: 64 * 64 * 4)
        return stride(from: 3, to: 64 * 64 * 4, by: 4).contains { pixels[$0] < 245 }
    }

    private static func convertImages(_ images: CGImageSource, to target: URL) async throws -> Result {
        guard let first = image(images, 0) else { throw Failure.unreadable }
        let scale = min(1, longestSide / CGFloat(max(first.width, first.height)))
        let width = max(2, Int(CGFloat(first.width) * scale) & ~1), height = max(2, Int(CGFloat(first.height) * scale) & ~1)
        let writer = try AVAssetWriter(outputURL: target, fileType: .mov)
        let transparent = hasTransparency(first)
        var settings: [String: Any] = [AVVideoCodecKey: transparent ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height]
        if transparent { settings[AVVideoCompressionPropertiesKey] = [kVTCompressionPropertyKey_TargetQualityForAlpha as String: 0.9] }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.unreadable }
        writer.startSession(atSourceTime: .zero)

        func append(_ image: CGImage, at seconds: Double) async throws {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? Failure.unreadable }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { throw Failure.unreadable }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let c = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw Failure.unreadable }
            if transparent {
                c.clear(CGRect(x: 0, y: 0, width: width, height: height))
            } else {
                c.setFillColor(CGColor(gray: 1, alpha: 1))
                c.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            c.interpolationQuality = .high
            c.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)) else { throw writer.error ?? Failure.unreadable }
        }

        let count = CGImageSourceGetCount(images)
        var time = 0.0
        var last = first
        if count == 1 {
            try await append(first, at: 0)
            time = stillLength
        } else {
            // A short animation plays a few times, so that it can be seen at all.
            var frames: [(image: CGImage, delay: Double)] = []
            var total = 0.0
            for i in 0..<min(count, 400) where total < maxLength {
                guard let frame = CGImageSourceCreateImageAtIndex(images, i, nil) else { continue }
                frames.append((frame, delay(images, i)))
                total += delay(images, i)
            }
            let rounds = total > 0 ? max(1, Int((MemeSlot.shortest / total).rounded(.up))) : 1
            for _ in 0..<rounds {
                for frame in frames where time < maxLength {
                    try await append(frame.image, at: time)
                    last = frame.image
                    time += frame.delay
                }
            }
            time = min(time, maxLength + 1)
        }
        // A movie ends with its last frame: this one keeps the last picture on screen to the end.
        try await append(last, at: time - 1.0 / 60)
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.unreadable }
        return (CGSize(width: width, height: height), time, transparent)
    }

    static func thumbnail(of movie: URL, to target: URL) async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        guard let image = try? await generator.image(at: CMTime(seconds: 0.05, preferredTimescale: 600)).image else { return }
        let picture = NSBitmapImageRep(cgImage: image)
        try? (target.pathExtension == "png" ? picture.representation(using: .png, properties: [:]) : picture.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))?.write(to: target)
    }
}

/// The ten places. They belong to the app, not to a project: the same board everywhere.
@MainActor
final class MemeBoard: ObservableObject {
    static let count = 10
    static let shared = MemeBoard(folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Screenkast/Memes", isDirectory: true))

    let folder: URL
    @Published private(set) var slots: [MemeSlot?]
    @Published private(set) var busy: Set<Int> = []
    @Published var problem: String?

    private var listFile: URL { folder.appendingPathComponent("board.json") }

    init(folder: URL) {
        self.folder = folder
        let saved = (try? Data(contentsOf: folder.appendingPathComponent("board.json"))).flatMap { try? JSONDecoder().decode([MemeSlot?].self, from: $0) } ?? []
        slots = (0..<Self.count).map { $0 < saved.count ? saved[$0] : nil }
    }

    func url(of slot: MemeSlot) -> URL { folder.appendingPathComponent(slot.file) }
    func thumbnail(of slot: MemeSlot) -> NSImage? { NSImage(contentsOf: folder.appendingPathComponent(slot.thumb)) }

    private func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(slots).write(to: listFile, options: .atomic)
    }

    /// Puts a file on a place (it is converted and copied).
    func assign(_ index: Int, file source: URL, title: String? = nil, credit: String? = nil) async {
        guard slots.indices.contains(index) else { return }
        busy.insert(index)
        defer { busy.remove(index) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let id = UUID().uuidString
            let movie = folder.appendingPathComponent(id + ".mov")
            let result = try await MemeConverter.convert(source, to: movie)
            let thumb = id + (result.transparent ? ".png" : ".jpg")
            await MemeConverter.thumbnail(of: movie, to: folder.appendingPathComponent(thumb))
            remove(index)
            slots[index] = MemeSlot(file: id + ".mov", thumb: thumb, title: title ?? source.deletingPathExtension().lastPathComponent, credit: credit,
                                    width: result.size.width, height: result.size.height, duration: result.duration, transparent: result.transparent ? true : nil)
            problem = nil
            save()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Downloads a search result onto a place.
    func assign(_ index: Int, result: MemeResult) async {
        busy.insert(index)
        defer { busy.remove(index) }
        do {
            let (data, _) = try await MemeSearch.session.data(from: result.file)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + result.file.pathExtension)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary)
            await assign(index, file: temporary, title: result.title, credit: result.credit)
        } catch {
            problem = "Das Meme ließ sich nicht laden: \(error.localizedDescription)"
        }
    }

    private func remove(_ index: Int) {
        guard let slot = slots[index] else { return }
        try? FileManager.default.removeItem(at: url(of: slot))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(slot.thumb))
        slots[index] = nil
    }

    func setShowFor(_ index: Int, _ seconds: Double?) {
        guard slots.indices.contains(index), slots[index] != nil else { return }
        slots[index]?.showFor = seconds
        save()
    }

    func clear(_ index: Int) {
        remove(index)
        save()
    }

    /// Everything that needs to be credited in a video.
    var credits: String { slots.compactMap { $0?.credit }.joined(separator: "\n") }

    func chooseFile(for index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif, .image, .movie]
        panel.message = "GIF, Bild oder kurzes Video für Platz \(index == 9 ? 0 : index + 1)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await assign(index, file: url) }
    }
}

// MARK: - Searching

struct MemeResult: Identifiable, Equatable {
    var id: String { file.absoluteString }
    var title: String
    var preview: URL
    var file: URL
    var license: String
    var creator: String?
    var page: URL?

    var credit: String {
        [title, creator, license, page?.absoluteString].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " – ")
    }
}

/// Search without an account: animated pictures under free licenses from Openverse and Wikimedia Commons.
enum MemeSearch {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": "Erklaerbaer/1.6 (macOS)"]
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private static func plain(_ html: String?) -> String? {
        guard let html else { return nil }
        let text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func parseOpenverse(_ data: Data) -> [MemeResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = root["results"] as? [[String: Any]] else { return [] }
        return items.compactMap { r in
            guard let file = (r["url"] as? String).flatMap(URL.init(string:)), let preview = (r["thumbnail"] as? String).flatMap(URL.init(string:)) else { return nil }
            let code = (r["license"] as? String ?? "").lowercased(), version = r["license_version"] as? String ?? ""
            let license = code == "cc0" ? "CC0" : code == "pdm" ? "Gemeinfrei" : "CC \(code.uppercased()) \(version)".trimmingCharacters(in: .whitespaces)
            return MemeResult(title: r["title"] as? String ?? "Meme", preview: preview, file: file, license: license,
                              creator: r["creator"] as? String, page: (r["foreign_landing_url"] as? String).flatMap(URL.init(string:)))
        }
    }

    static func parseCommons(_ data: Data) -> [MemeResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let query = root["query"] as? [String: Any],
              let pages = query["pages"] as? [String: [String: Any]] else { return [] }
        return pages.values.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }.compactMap { page in
            guard let info = (page["imageinfo"] as? [[String: Any]])?.first, let file = (info["url"] as? String).flatMap(URL.init(string:)),
                  let preview = (info["thumburl"] as? String).flatMap(URL.init(string:)) else { return nil }
            let meta = info["extmetadata"] as? [String: [String: Any]]
            func value(_ key: String) -> String? { plain(meta?[key]?["value"] as? String) }
            let name = (page["title"] as? String ?? "Meme").replacingOccurrences(of: "File:", with: "")
            return MemeResult(title: (name as NSString).deletingPathExtension, preview: preview, file: file, license: value("LicenseShortName") ?? "frei",
                              creator: value("Artist"), page: (info["descriptionurl"] as? String).flatMap(URL.init(string:)))
        }
    }

    static func search(_ text: String) async throws -> [MemeResult] {
        var openverse = URLComponents(string: "https://api.openverse.org/v1/images/")!
        openverse.queryItems = [.init(name: "q", value: text), .init(name: "extension", value: "gif"), .init(name: "page_size", value: "20")]
        var commons = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        commons.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"), .init(name: "generator", value: "search"),
            .init(name: "gsrnamespace", value: "6"), .init(name: "gsrlimit", value: "20"), .init(name: "gsrsearch", value: "\(text) filemime:image/gif"),
            .init(name: "prop", value: "imageinfo"), .init(name: "iiprop", value: "url|extmetadata"), .init(name: "iiurlwidth", value: "320"),
        ]
        async let first = session.data(from: openverse.url!)
        async let second = session.data(from: commons.url!)
        let a = try? await first.0, b = try? await second.0
        guard a != nil || b != nil else { throw URLError(.notConnectedToInternet) }
        var seen = Set<String>()
        return (a.map(parseOpenverse) ?? []) .filter { seen.insert($0.id).inserted } + (b.map(parseCommons) ?? []).filter { seen.insert($0.id).inserted }
    }
}
