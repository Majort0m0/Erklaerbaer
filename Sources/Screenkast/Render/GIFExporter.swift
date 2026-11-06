import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Animated GIF of a composition (for short clips: tutorials, bug reports, chat).
enum GIFExporter {
    static let fps = 12.0
    static let maxWidth: CGFloat = 720

    static func export(media: MediaComposition, renderSize: CGSize, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let gen = AVAssetImageGenerator(asset: media.asset)
        // The compositor renders at the project's size; the generator scales the frames down.
        gen.videoComposition = media.videoComposition(renderSize: renderSize, fps: Int(fps))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let scale = min(1, maxWidth / max(1, renderSize.width))
        gen.maximumSize = CGSize(width: renderSize.width * scale, height: renderSize.height * scale)
        let count = max(1, Int(media.totalDuration * fps))
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw RecorderError.writerFailed("GIF konnte nicht angelegt werden")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            try Task.checkCancellation()
            let image = try await gen.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600)).image
            CGImageDestinationAddImage(destination, image, frameProperties)
            progress(Double(i + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(destination) else { throw RecorderError.writerFailed("GIF konnte nicht geschrieben werden") }
    }
}
