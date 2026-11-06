import Foundation
import AVFoundation
import Accelerate

/// Loudness of the lanes ("Pegel angleichen") and of the finished video (loudness target on export).
enum AudioMastering {
    static let sampleRate = 48_000.0

    // MARK: Loudness

    /// Integrated loudness (BS.1770) of several channels: the K-weighted energies are summed.
    static func loudness(channels: [[Float]]) -> Double {
        guard let count = channels.map(\.count).min(), count > 0 else { return -.infinity }
        let block = Int(0.4 * sampleRate), step = Int(0.1 * sampleRate)
        guard count >= block else { return -.infinity }
        let weighted = channels.map { kWeighted($0) }
        var powers: [Double] = []
        var start = 0
        while start + block <= count {
            powers.append(weighted.reduce(0) { $0 + Double(vDSP.meanSquare($1[start..<(start + block)])) })
            start += step
        }
        func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(max(z, 1e-12)) }
        let absolute = powers.filter { lufs($0) > -70 }
        guard !absolute.isEmpty else { return -.infinity }
        let gate = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lufs($0) > gate }
        guard !gated.isEmpty else { return -.infinity }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    private static func kWeighted(_ input: [Float]) -> [Float] {
        var x = input
        func biquad(_ b0: Double, _ b1: Double, _ b2: Double, _ a1: Double, _ a2: Double) {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in x.indices {
                let v = Double(x[i])
                let y = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = v; y2 = y1; y1 = y
                x[i] = Float(y)
            }
        }
        biquad(1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585)
        biquad(1, -2, 1, -1.99004745483398, 0.99007225036621)
        return x
    }

    // MARK: Lanes

    struct LaneLevels: Equatable {
        var mic: Double?
        var micHasSpeech = false
        var system: Double?
        var voiceOver: Double?
        var music: Double?
    }

    /// Loudness of what each lane plays (the enhanced/echo-free microphone when that is used).
    static func measure(project: Project, settings: EditSettings) async -> LaneLevels {
        var levels = LaneLevels()
        let asset = AVURLAsset(url: project.videoURL)
        let duration = (try? await asset.load(.duration).seconds) ?? project.info.duration
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let roles = await AudioRole.roles(of: tracks, fallback: project.info.audioRoles)
        func read(_ role: String) async -> [Float]? {
            guard let i = roles.firstIndex(of: role) else { return nil }
            return try? await EchoCanceller.readMono(track: tracks[i], asset: asset, duration: duration)
        }
        if project.info.hasMicAudio {
            var mic: [Float]?
            let enhanced = VoiceProcessor.micURL(for: project, settings: settings)
            let clean = EchoCanceller.cleanURL(for: project)
            if settings.voice.enhancesMic, FileManager.default.fileExists(atPath: enhanced.path) {
                mic = try? await VoiceProcessor.readFile(enhanced)
            } else if settings.removeEcho, FileManager.default.fileExists(atPath: clean.path) {
                mic = try? await VoiceProcessor.readFile(clean)
            } else {
                mic = await read("mic")
            }
            if let mic {
                levels.mic = loudness(channels: [mic])
                levels.micHasSpeech = VoiceProcessor.hasSpeech(mic)
            }
        }
        if project.info.hasSystemAudio, let system = await read("system") {
            levels.system = loudness(channels: [system])
        }
        var narration: [Float] = []
        for clip in settings.voiceOvers {
            let enhanced = VoiceProcessor.voiceOverURL(for: project, file: clip.file, settings: settings)
            let url = settings.voice.enhancesVoiceOver && FileManager.default.fileExists(atPath: enhanced.path)
                ? enhanced : project.url.appendingPathComponent(clip.file)
            guard let samples = try? await VoiceProcessor.readFile(url) else { continue }
            let a = max(0, Int(clip.fileOffset * sampleRate)), b = min(samples.count, Int((clip.fileOffset + clip.duration) * sampleRate))
            if b > a { narration += samples[a..<b].map { $0 * Float(clip.gain) } }
        }
        if !narration.isEmpty { levels.voiceOver = loudness(channels: [narration]) }
        if let music = settings.music, let samples = try? await VoiceProcessor.readFile(project.url.appendingPathComponent(music.file)) {
            levels.music = loudness(channels: [samples])
        }
        return levels
    }

    /// Volumes that put speech in front (−16 LUFS), system sound 7 LU and music 14 LU below it.
    /// Nothing is amplified beyond 100 %: the loudest lane gets 100 %, the others follow.
    static func suggestedVolumes(_ l: LaneLevels) -> (mic: Double?, system: Double?, voiceOver: Double?, music: Double?, quietBy: Double) {
        let speech = (l.micHasSpeech && l.mic != nil) || l.voiceOver != nil
        func gain(_ lufs: Double?, target: Double) -> Double? {
            guard let lufs, lufs.isFinite else { return nil }
            return pow(10, (target - lufs) / 20)
        }
        let mic = l.micHasSpeech ? gain(l.mic, target: -16) : nil
        let voice = gain(l.voiceOver, target: -16)
        let system = gain(l.system, target: speech ? -23 : -16)
        let music = gain(l.music, target: speech ? -30 : -20)
        let all = [mic, voice, system, music].compactMap { $0 }
        guard let top = all.max(), top > 0 else { return (nil, nil, nil, nil, 0) }
        let k = top > 1 ? 1 / top : 1
        func v(_ g: Double?) -> Double? { g.map { min(1, max(0.02, $0 * k)) } }
        return (v(mic), v(system), v(voice), v(music), top > 1 ? 20 * log10(top) : 0)
    }

    // MARK: Finished video

    struct MasterResult: Equatable {
        var before: Double
        var after: Double
    }

    /// Brings the audio of an exported video to `target` LUFS (soft limiting at −1 dBFS) and
    /// writes the video again with the video samples copied unchanged.
    static func normalize(file url: URL, target: Double) async throws -> MasterResult? {
        let asset = AVURLAsset(url: url)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
              let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let duration = try await asset.load(.duration).seconds
        var channels = try await readStereo(track: audioTrack, asset: asset, duration: duration)
        let before = loudness(channels: channels)
        guard before.isFinite else { return nil }
        let gainDB = target - before
        guard abs(gainDB) > 0.3 else { return MasterResult(before: before, after: before) }
        let g = Float(pow(10, gainDB / 20))
        for c in channels.indices {
            vDSP.multiply(g, channels[c], result: &channels[c])
            VoiceProcessor.limit(&channels[c], ceiling: 0.89)
        }
        let after = loudness(channels: channels)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        try await remux(video: videoTrack, of: asset, audio: channels, to: temp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        return MasterResult(before: before, after: after)
    }

    /// Both channels as 48 kHz floats (mono files give two equal channels).
    static func readStereo(track: AVAssetTrack, asset: AVAsset, duration: Double) async throws -> [[Float]] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecorderError.writerFailed("Audio lesen") }
        let frames = Int(duration * sampleRate) + 1
        var left = [Float](repeating: 0, count: frames), right = [Float](repeating: 0, count: frames)
        while let sb = output.copyNextSampleBuffer() {
            guard let block = sb.dataBuffer else { continue }
            let start = Int((sb.presentationTimeStamp.seconds * sampleRate).rounded())
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            for i in 0..<(chunk.count / 2) {
                let f = start + i
                guard f >= 0, f < frames else { continue }
                left[f] = chunk[2 * i]; right[f] = chunk[2 * i + 1]
            }
        }
        if reader.status == .failed { throw reader.error ?? RecorderError.writerFailed("Audio lesen") }
        return [left, right]
    }

    /// New MP4: the video track's samples unchanged, the audio encoded from `audio` (AAC).
    private static func remux(video: AVAssetTrack, of asset: AVAsset, audio: [[Float]], to dest: URL) async throws {
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        let writer = try AVAssetWriter(outputURL: dest, fileType: .mp4)
        let hint = try await video.load(.formatDescriptions).first
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        videoIn.transform = try await video.load(.preferredTransform)
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
        ])
        audioIn.expectsMediaDataInRealTime = false
        writer.add(audioIn)
        guard reader.startReading(), writer.startWriting() else {
            throw writer.error ?? reader.error ?? RecorderError.writerFailed("Lautheit angleichen")
        }
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard let format else { throw RecorderError.writerFailed("Audioformat") }
        let total = audio[0].count
        let left = audio[0], right = audio.count > 1 ? audio[1] : audio[0]

        final class Box: @unchecked Sendable { var position = 0 }
        let box = Box()
        let videoQueue = DispatchQueue(label: "remux.video"), audioQueue = DispatchQueue(label: "remux.audio")
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    videoIn.requestMediaDataWhenReady(on: videoQueue) {
                        while videoIn.isReadyForMoreMediaData {
                            guard let sb = videoOut.copyNextSampleBuffer() else {
                                videoIn.markAsFinished()
                                done.resume()
                                return
                            }
                            videoIn.append(sb)
                        }
                    }
                }
            }
            group.addTask {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    audioIn.requestMediaDataWhenReady(on: audioQueue) {
                        while audioIn.isReadyForMoreMediaData {
                            let start = box.position
                            guard start < total else {
                                audioIn.markAsFinished()
                                done.resume()
                                return
                            }
                            let n = min(4096, total - start)
                            var interleaved = [Float](repeating: 0, count: 2 * n)
                            for i in 0..<n { interleaved[2 * i] = left[start + i]; interleaved[2 * i + 1] = right[start + i] }
                            var block: CMBlockBuffer?
                            let bytes = 2 * n * 4
                            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                               customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                               flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
                            guard let block else { box.position = total; continue }
                            interleaved.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                                            offsetIntoDestination: 0, dataLength: bytes) }
                            var sb: CMSampleBuffer?
                            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                                 sampleCount: n,
                                                                                 presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
                                                                                 packetDescriptions: nil, sampleBufferOut: &sb)
                            box.position = start + n
                            if let sb { audioIn.append(sb) }
                        }
                    }
                }
            }
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? RecorderError.writerFailed("Lautheit angleichen") }
    }
}
