import AVFoundation
import CoreAudio

/// Times on the host clock as frame numbers at 48 kHz (the time base of the live recording).
enum HostFrames {
    static func frame(_ time: CMTime) -> Int64 { Int64((time.seconds * LiveAudioFormat.sampleRate).rounded()) }
    static func frame(hostTime: UInt64) -> Int64 { frame(CMClockMakeHostTimeFromSystemUnits(hostTime)) }
    static var now: Int64 { frame(CMClockGetTime(CMClockGetHostTimeClock())) }
    static func time(_ frame: Int64) -> CMTime { CMTime(value: frame, timescale: CMTimeScale(LiveAudioFormat.sampleRate)) }
}

/// The "system" sound track of a live recording: what was heard in the meeting apart from the own voice
/// (the others from the meeting program, programs, iPad, memes). Every source writes its sound at the
/// place its time stamp says; finished pieces go to the movie a third of a second later, so sound that
/// arrives late still lands in the right place and picture and sound stay together.
final class RecordingMix: @unchecked Sendable {
    typealias Deliver = @Sendable (CMSampleBuffer) -> Void

    /// How long sound may arrive late before it is written.
    static let delay: Int64 = 16_800   // 350 ms
    private static let capacity = 48_000 * 10

    private let lock = NSLock()
    private let ring: UnsafeMutablePointer<Float>
    /// Frames before this are written.
    private var written: Int64
    private var end: Int64?
    private let deliver: Deliver
    private let queue = DispatchQueue(label: "screenkast.live.recordingmix", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var format: CMAudioFormatDescription?
    /// Memes: their sound from the moment they were started, repeated until they stop.
    private var clips: [(samples: [Float], start: Int64, stop: Int64?, gain: Float)] = []
    private(set) var lateFrames = 0

    init(start: CMTime, deliver: @escaping Deliver) {
        ring = .allocate(capacity: Self.capacity * 2)
        ring.initialize(repeating: 0, count: Self.capacity * 2)
        written = HostFrames.frame(start)
        self.deliver = deliver
        var asbd = AudioStreamBasicDescription(mSampleRate: LiveAudioFormat.sampleRate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
                                               mBitsPerChannel: 16, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &format)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.emit(upTo: HostFrames.now - Self.delay) }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
        ring.deallocate()
    }

    /// Interleaved stereo at 48 kHz whose first frame sounded at `frame`.
    func write(_ data: UnsafePointer<Float>, frames: Int, at frame: Int64, gain: Float) {
        guard gain > 0, frames > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if let end, frame >= end { return }
        for i in 0..<frames {
            let f = frame + Int64(i)
            guard f >= written else { lateFrames += 1; continue }
            guard f < written + Int64(Self.capacity) else { break }
            let slot = Int(f % Int64(Self.capacity)) * 2
            ring[slot] += data[i * 2] * gain
            ring[slot + 1] += data[i * 2 + 1] * gain
        }
    }

    /// The sound of a sample buffer whose time stamp is on the host clock (the iPad).
    func write(_ sample: CMSampleBuffer, gain: Float) {
        guard let sound = AudioSamples.interleavedStereo(sample), abs(sound.rate - LiveAudioFormat.sampleRate) < 1 else { return }
        sound.data.withUnsafeBufferPointer { write($0.baseAddress!, frames: sound.data.count / 2, at: HostFrames.frame(sample.presentationTimeStamp), gain: gain) }
    }

    /// A meme starts sounding now (nil: none sounds any more).
    func clip(_ samples: [Float]?, startedAt frame: Int64, gain: Float) {
        lock.withLock {
            for i in clips.indices where clips[i].stop == nil { clips[i].stop = frame }
            if let samples, samples.count >= 2 { clips.append((samples, frame, nil, gain)) }
        }
    }

    /// Writes everything up to `end` (when the recording stops) and stops.
    func finish(at endTime: CMTime) {
        let last = HostFrames.frame(endTime)
        lock.withLock { end = last }
        timer?.cancel()
        timer = nil
        queue.sync { emit(upTo: last) }
    }

    private func emit(upTo target: Int64) {
        lock.lock()
        let from = written
        let upTo = min(target, from + Int64(Self.capacity))
        guard upTo > from else { return lock.unlock() }
        let count = Int(upTo - from)
        var shorts = [Int16](repeating: 0, count: count * 2)
        for i in 0..<count {
            let f = from + Int64(i)
            let slot = Int(f % Int64(Self.capacity)) * 2
            var left = ring[slot], right = ring[slot + 1]
            for clip in clips where f >= clip.start && (clip.stop.map { f < $0 } ?? true) {
                let position = Int((f - clip.start) % Int64(clip.samples.count / 2)) * 2
                left += clip.samples[position] * clip.gain
                right += clip.samples[position + 1] * clip.gain
            }
            ring[slot] = 0
            ring[slot + 1] = 0
            shorts[i * 2] = Int16(max(-1, min(1, tanhf(left))) * 32_767)
            shorts[i * 2 + 1] = Int16(max(-1, min(1, tanhf(right))) * 32_767)
        }
        written = upTo
        clips.removeAll { clip in clip.stop.map { $0 <= upTo } ?? false }
        lock.unlock()
        if let sample = makeSample(shorts, frames: count, at: from) { deliver(sample) }
    }

    private func makeSample(_ shorts: [Int16], frames: Int, at frame: Int64) -> CMSampleBuffer? {
        guard let format else { return nil }
        let bytes = frames * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { return nil }
        shorts.withUnsafeBytes { raw in _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
                                                             presentationTimeStamp: HostFrames.time(frame), packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }
}

import Vision
import AppKit

/// `--blurtest <movie> <png>`: a picture of the movie's camera with the room blurred behind the person
/// (original left, low and strong blur right), to look at the blurred background.
enum BlurBackgroundTest {
    static func commandLine(movie: URL, output: URL) -> Int32 {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.appliesPreferredTrackTransform = true
        guard let cg = try? generator.copyCGImage(at: CMTime(seconds: 5, preferredTimescale: 600), actualTime: nil) else {
            print("✗ Kein Bild")
            return 1
        }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        guard let mask = request.results?.first?.pixelBuffer else {
            print("✗ Keine Person gefunden")
            return 1
        }
        let camera = CIImage(cgImage: cg)
        let maskImage = LiveCompositor.maskImage(mask)
        let pictures = [camera] + [0.3, 0.8].map { LiveCompositor.person(camera, mask: maskImage, background: LiveCompositor.blurred(camera, amount: $0)) }
        let w = camera.extent.width, h = camera.extent.height
        var sheet = CIImage.empty()
        for (i, picture) in pictures.enumerated() {
            sheet = picture.transformed(by: CGAffineTransform(translationX: CGFloat(i) * w, y: 0)).composited(over: sheet)
        }
        let context = CIContext()
        let scaled = sheet.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        guard let png = context.pngRepresentation(of: scaled, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return 1 }
        try? png.write(to: output)
        print("✓ Bild →", output.path)
        return 0
    }
}
