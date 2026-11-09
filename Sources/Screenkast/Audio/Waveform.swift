import Foundation
import AVFoundation

/// Peak levels of an audio track for the timeline (streaming, no full sample buffer in memory).
enum Waveform {
    /// Buckets per second.
    static let rate = 100.0

    /// Peak level (0…1) per 1/100 s. Samples are placed by their presentation time, so the
    /// result lines up with the recording timeline (tracks may start a little later).
    static func peaks(track: AVAssetTrack, asset: AVAsset) async throws -> [Float] {
        let duration = try await asset.load(.duration).seconds
        let sampleRate = 16_000.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecorderError.writerFailed("Audio lesen") }
        let perBucket = sampleRate / rate
        let count = Int(duration * rate) + 1
        // The reading blocks while it waits for the decoder: on its own queue, so that several
        // waveforms at once cannot take all of Swift's shared threads (that once stalled everything).
        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<[Float], Error>) in
            readQueue.async {
                var peaks = [Float](repeating: 0, count: count)
                var chunk: [Float] = []
                while let sb = output.copyNextSampleBuffer() {
                    guard let block = sb.dataBuffer else { continue }
                    let length = CMBlockBufferGetDataLength(block)
                    if chunk.count < length / 4 { chunk = [Float](repeating: 0, count: length / 4) }
                    _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                    let first = sb.presentationTimeStamp.seconds * sampleRate
                    for i in 0..<(length / 4) {
                        let bucket = Int((first + Double(i)) / perBucket)
                        guard bucket >= 0, bucket < peaks.count else { continue }
                        let v = abs(chunk[i])
                        if v > peaks[bucket] { peaks[bucket] = v }
                    }
                }
                if reader.status == .failed {
                    done.resume(throwing: reader.error ?? RecorderError.writerFailed("Audio lesen"))
                } else {
                    done.resume(returning: peaks)
                }
            }
        }
    }

    private static let readQueue = DispatchQueue(label: "screenkast.waveform", qos: .utility)

    /// Peaks of the first audio track of a file.
    static func peaks(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        return try await peaks(track: track, asset: asset)
    }
}
