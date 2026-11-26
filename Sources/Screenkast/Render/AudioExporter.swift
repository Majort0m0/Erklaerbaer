import Accelerate
import AVFoundation

/// "Nur Ton": the finished sound of a project (all tracks with their volumes, cuts and speeds) as an
/// M4A (AAC) or WAV file, brought to the export loudness if that is switched on.
enum AudioExporter {
    enum Format: String, CaseIterable, Identifiable {
        case m4a, wav
        var id: String { rawValue }
        var label: String { self == .m4a ? "M4A (AAC, klein)" : "WAV (unkomprimiert)" }
        var fileType: AVFileType { self == .m4a ? .m4a : .wav }
    }

    /// Writes the sound; `progress` goes from 0 to 1. Returns the loudness before and after, if it was changed.
    static func export(media: MediaComposition, audioMix: AVAudioMix?, to url: URL, format: Format, normalizeTo target: Double?,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> AudioMastering.MasterResult? {
        let tracks = try await media.asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw RecorderError.writerFailed("Das Projekt hat keinen Ton.") }
        let duration = media.asset.duration.seconds
        guard duration > 0 else { throw RecorderError.writerFailed("Das Projekt ist leer.") }
        let rate = AudioMastering.sampleRate

        // 1. The mix as two channels of floats.
        let reader = try AVAssetReader(asset: media.asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
        ])
        output.audioMix = audioMix
        output.audioTimePitchAlgorithm = .spectral
        guard reader.canAdd(output) else { throw RecorderError.writerFailed("Ton lesen") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecorderError.writerFailed("Ton lesen") }
        let frames = Int(duration * rate) + 1
        var left = [Float](repeating: 0, count: frames), right = [Float](repeating: 0, count: frames)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = sample.dataBuffer else { continue }
            let start = Int((sample.presentationTimeStamp.seconds * rate).rounded())
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            for i in 0..<(chunk.count / 2) {
                let f = start + i
                guard f >= 0, f < frames else { continue }
                left[f] = chunk[2 * i]
                right[f] = chunk[2 * i + 1]
            }
            progress(min(0.7, 0.7 * Double(start) / Double(frames)))
        }
        if reader.status == .failed { throw reader.error ?? RecorderError.writerFailed("Ton lesen") }

        // 2. Loudness, as for videos.
        var result: AudioMastering.MasterResult?
        if let target {
            let before = AudioMastering.loudness(channels: [left, right])
            if before.isFinite, abs(target - before) > 0.3 {
                let gain = Float(pow(10, (target - before) / 20))
                vDSP.multiply(gain, left, result: &left)
                vDSP.multiply(gain, right, result: &right)
                VoiceProcessor.limit(&left, ceiling: 0.89)
                VoiceProcessor.limit(&right, ceiling: 0.89)
                result = AudioMastering.MasterResult(before: before, after: AudioMastering.loudness(channels: [left, right]))
            }
        }

        // 3. The file.
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: format.fileType)
        let settings: [String: Any] = format == .m4a
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24,
               AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw RecorderError.writerFailed("Tondatei") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecorderError.writerFailed("Tondatei") }
        writer.startSession(atSourceTime: .zero)
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
                                               mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &description)
        guard let description else { throw RecorderError.writerFailed("Tonformat") }
        let piece = 48_000
        var position = 0
        while position < frames {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let count = min(piece, frames - position)
            var interleaved = [Float](repeating: 0, count: count * 2)
            for i in 0..<count {
                interleaved[2 * i] = left[position + i]
                interleaved[2 * i + 1] = right[position + i]
            }
            let bytes = count * 8
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                               offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            guard let block else { throw RecorderError.writerFailed("Speicher") }
            interleaved.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: description, sampleCount: count,
                                                                 presentationTimeStamp: CMTime(value: CMTimeValue(position), timescale: CMTimeScale(rate)),
                                                                 packetDescriptions: nil, sampleBufferOut: &sample)
            guard let sample, input.append(sample) else { throw writer.error ?? RecorderError.writerFailed("Tondatei schreiben") }
            position += count
            progress(0.7 + 0.3 * Double(position) / Double(frames))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RecorderError.writerFailed("Tondatei") }
        return result
    }
}
