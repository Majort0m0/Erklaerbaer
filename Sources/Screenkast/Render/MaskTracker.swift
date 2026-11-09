import AVFoundation
import Vision

/// Follows the content under a mask through the recording.
enum MaskTracker {
    enum Failure: LocalizedError {
        case noVideo
        var errorDescription: String? { "Die Aufnahme ließ sich nicht lesen." }
    }

    static func track(url: URL, mask: BlurMask, fps: Double = 12) async throws -> [MaskPoint] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: mask.start, preferredTimescale: 600), end: CMTime(seconds: mask.end, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure.noVideo }
        defer { reader.cancelReading() }

        var observation = VNDetectedObjectObservation(boundingBox: CGRect(x: mask.x, y: 1 - mask.y - mask.height, width: mask.width, height: mask.height))
        let handler = VNSequenceRequestHandler()
        var points: [MaskPoint] = [MaskPoint(t: mask.start, x: mask.x, y: mask.y)]
        var last = -Double.infinity
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let t = sample.presentationTimeStamp.seconds
            guard t - last >= 1 / fps, let frame = CMSampleBufferGetImageBuffer(sample) else { continue }
            last = t
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .accurate
            try handler.perform([request], on: frame)
            guard let found = request.results?.first as? VNDetectedObjectObservation, found.confidence > 0.3 else { break }
            observation = found
            points.append(MaskPoint(t: t,
                                    x: min(1 - mask.width, max(0, Double(found.boundingBox.midX) - mask.width / 2)),
                                    y: min(1 - mask.height, max(0, 1 - Double(found.boundingBox.midY) - mask.height / 2))))
        }
        return points
    }
}
