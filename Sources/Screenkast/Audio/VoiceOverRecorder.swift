import Foundation
import AVFoundation
import CoreMedia

/// Records narration from a microphone into an .m4a file. Sample times are converted to the
/// host clock, so the editor can line the recording up with the video playback.
final class VoiceOverRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "screenkast.voiceover", qos: .userInteractive)
    private let output = AVCaptureAudioDataOutput()

    // queue only
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var writeFromHost: Double = .infinity
    private var firstHost: Double?
    private var lastHostEnd: Double = 0
    private var level: Float = 0

    /// Current input level 0…1 (for a meter).
    var currentLevel: Float { queue.sync { level } }

    static var defaultDevice: AVCaptureDevice? {
        let saved = UserDefaults.standard.string(forKey: "microphoneID") ?? ""
        return AVCaptureDevice(uniqueID: saved) ?? AVCaptureDevice.default(for: .audio)
    }

    /// Opens the microphone (the session needs a moment to start; call before `beginWriting`).
    func prepare(device: AVCaptureDevice, url: URL) throws {
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        guard session.canAddInput(input) else { throw RecorderError.writerFailed("Mikrofon nicht verfügbar") }
        session.addInput(input)
        if session.outputs.isEmpty {
            output.setSampleBufferDelegate(self, queue: queue)
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
            guard session.canAddOutput(output) else { throw RecorderError.writerFailed("Mikrofon-Ausgabe") }
            session.addOutput(output)
        }
        session.commitConfiguration()

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 160_000,
        ])
        aIn.expectsMediaDataInRealTime = true
        guard writer.canAdd(aIn) else { throw RecorderError.writerFailed("Voice-over-Datei") }
        writer.add(aIn)
        queue.sync {
            self.writer = writer
            self.input = aIn
            self.writeFromHost = .infinity
            self.firstHost = nil
            self.level = 0
        }
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    /// Samples captured from host time `host` on are written.
    func beginWriting(fromHost host: Double) {
        queue.sync { writeFromHost = host }
    }

    /// Stops and finishes the file. Returns the host time of the first written sample and the length.
    func finish() async -> (firstHost: Double, duration: Double)? {
        session.stopRunning()
        return await withCheckedContinuation { cont in
            queue.async {
                guard let writer = self.writer, let input = self.input, let first = self.firstHost else {
                    self.writer?.cancelWriting()
                    self.writer = nil
                    cont.resume(returning: nil)
                    return
                }
                self.writer = nil
                input.markAsFinished()
                let duration = self.lastHostEnd - first
                writer.finishWriting {
                    cont.resume(returning: writer.status == .completed ? (first, duration) : nil)
                }
            }
        }
    }

    func cancel() {
        session.stopRunning()
        queue.sync {
            writer?.cancelWriting()
            writer = nil
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        // The microphone may ignore the requested format: read rate and sample type from the buffer.
        let asbd = sampleBuffer.formatDescription.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let rate = asbd.map { $0.mSampleRate > 0 ? $0.mSampleRate : 48_000 } ?? 48_000
        if let asbd, let block = sampleBuffer.dataBuffer {
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            _ = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            var peak: Float = 0
            bytes.withUnsafeBytes { raw in
                if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32 {
                    for v in raw.bindMemory(to: Float.self) { peak = max(peak, abs(v)) }
                } else if asbd.mBitsPerChannel == 16 {
                    for v in raw.bindMemory(to: Int16.self) { peak = max(peak, abs(Float(v)) / 32768) }
                } else if asbd.mBitsPerChannel == 32 {
                    for v in raw.bindMemory(to: Int32.self) { peak = max(peak, abs(Float(v)) / 2_147_483_648) }
                }
            }
            level = max(min(1, peak), level * 0.85)
        }
        guard let writer, let input else { return }
        var pts = sampleBuffer.presentationTimeStamp
        if let clock = session.synchronizationClock {
            pts = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        }
        let host = pts.seconds
        guard host >= writeFromHost else { return }
        if firstHost == nil {
            guard writer.startWriting() else { self.writer = nil; return }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            firstHost = host
        }
        if input.isReadyForMoreMediaData, input.append(sampleBuffer) {
            lastHostEnd = host + Double(CMSampleBufferGetNumSamples(sampleBuffer)) / rate
        }
    }
}
