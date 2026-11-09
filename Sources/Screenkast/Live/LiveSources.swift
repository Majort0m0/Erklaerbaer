import AVFoundation
import ScreenCaptureKit
import Vision
import QuartzCore
import CoreImage

/// A display or window as a live source (the real mouse pointer is part of the picture).
final class LiveScreenSource: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "screenkast.live.screen", qos: .userInteractive)
    private let filter: SCContentFilter
    private let onFrame: (CVPixelBuffer) -> Void
    private var stream: SCStream?
    var onError: ((Error) -> Void)?

    init(filter: SCContentFilter, onFrame: @escaping (CVPixelBuffer) -> Void) {
        self.filter = filter
        self.onFrame = onFrame
    }

    private func configuration(for points: CGSize) -> SCStreamConfiguration {
        let scale = Double(filter.pointPixelScale)
        let fit = min(1, 1920 / max(1, max(points.width, points.height) * scale))
        let config = SCStreamConfiguration()
        config.width = max(2, Int((points.width * scale * fit / 2).rounded()) * 2)
        config.height = max(2, Int((points.height * scale * fit / 2).rounded()) * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 5
        config.ignoreShadowsSingleWindow = true
        return config
    }

    func start() async throws {
        let stream = SCStream(filter: filter, configuration: configuration(for: filter.contentRect.size), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    /// The window changed its size.
    func resize(to points: CGSize) {
        let config = configuration(for: points)
        Task { [stream] in try? await stream?.updateConfiguration(config) }
    }

    func stop() async {
        let running = stream
        stream = nil
        try? await running?.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let frame = CMSampleBufferGetImageBuffer(sample) else { return }
        onFrame(frame)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error) }
}

/// An iPad or iPhone on a cable as a live source.
final class LiveDeviceSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "screenkast.live.device", qos: .userInteractive)
    private let startQueue = DispatchQueue(label: "screenkast.live.device.start")
    private let session = AVCaptureSession()
    private let video = AVCaptureVideoDataOutput()
    private let audio = AVCaptureAudioDataOutput()
    private let onFrame: (CVPixelBuffer) -> Void
    private let onAudio: (CMSampleBuffer, CMClock?) -> Void

    init(onFrame: @escaping (CVPixelBuffer) -> Void, onAudio: @escaping (CMSampleBuffer, CMClock?) -> Void) {
        self.onFrame = onFrame
        self.onAudio = onAudio
    }

    func start(deviceID: String, hear: Bool) async throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else { throw RecorderError.deviceMissing }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(video) else { throw RecorderError.deviceMissing }
        session.addInput(input)
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(video)
        audio.audioSettings = DeviceMovieWriter.audioFormat(channels: 2)
        audio.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(audio) { session.addOutput(audio) }
        if hear {
            let preview = AVCaptureAudioPreviewOutput()
            preview.volume = 1
            if session.canAddOutput(preview) { session.addOutput(preview) }
        }
        session.commitConfiguration()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            startQueue.async { [session] in
                session.startRunning()
                done.resume()
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            startQueue.async { [session] in
                session.stopRunning()
                done.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === video {
            if let frame = CMSampleBufferGetImageBuffer(sample) { onFrame(frame) }
        } else {
            onAudio(sample, session.synchronizationClock)
        }
    }
}

/// Microphone of the Mac while a live picture is recorded.
final class LiveMicrophone: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "screenkast.live.mic", qos: .userInteractive)
    private let session = AVCaptureSession()
    private let onAudio: (CMSampleBuffer, CMClock?) -> Void

    init?(deviceID: String, onAudio: @escaping (CMSampleBuffer, CMClock?) -> Void) {
        self.onAudio = onAudio
        super.init()
        guard let device = AVCaptureDevice(uniqueID: deviceID), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = DeviceMovieWriter.audioFormat(channels: 1)
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
    }

    func start() { queue.async { [session] in session.startRunning() } }
    func stop() { queue.async { [session] in session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        onAudio(sample, session.synchronizationClock)
    }
}

/// Mixes every person mask with the ones before it, so that the outline does not flicker from picture to picture.
final class MaskSmoother: @unchecked Sendable {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
    private let lock = NSLock()
    private var previous: CVPixelBuffer?
    private var lastTime = -Double.infinity

    /// `calm` 0: only the new mask; towards 1: mostly the masks before. Only directly following pictures are mixed.
    func blend(_ mask: CVPixelBuffer, calm: Double, time: Double) -> CVPixelBuffer {
        lock.withLock {
            defer { lastTime = time }
            guard calm > 0.01, let before = previous, time > lastTime, time - lastTime < 0.25,
                  CVPixelBufferGetWidth(before) == CVPixelBufferGetWidth(mask), CVPixelBufferGetHeight(before) == CVPixelBufferGetHeight(mask) else {
                previous = mask
                return mask
            }
            var made: CVPixelBuffer?
            CVPixelBufferCreate(nil, CVPixelBufferGetWidth(mask), CVPixelBufferGetHeight(mask), kCVPixelFormatType_OneComponent8,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &made)
            guard let out = made, let mixed = CIFilter(name: "CIDissolveTransition", parameters: [
                kCIInputImageKey: LiveCompositor.maskImage(mask), kCIInputTargetImageKey: LiveCompositor.maskImage(before), kCIInputTimeKey: min(0.9, calm),
            ])?.outputImage else {
                previous = mask
                return mask
            }
            context.render(mixed, to: out)
            previous = out
            return out
        }
    }
}

/// Finds the person in the webcam picture, on its own queue. A busy moment skips a picture; picture and
/// mask are kept together so that the outline stays exactly on the person.
final class LiveSegmenter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "screenkast.live.segment", qos: .userInitiated)
    private let handler = VNSequenceRequestHandler()
    private let request: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private let smoother = MaskSmoother()
    private let lock = NSLock()
    private var busy = false
    private var result: (frame: CVPixelBuffer, mask: CVPixelBuffer)?
    /// How much the outline is calmed (0…1).
    var calm = 0.5
    var onFailure: (() -> Void)?
    private var failed = false

    var latest: (frame: CVPixelBuffer, mask: CVPixelBuffer)? { lock.withLock { result } }

    func reset() { lock.withLock { result = nil } }

    func submit(_ frame: CVPixelBuffer) {
        let skip: Bool = lock.withLock {
            defer { busy = true }
            return busy
        }
        guard !skip else { return }
        queue.async { [self] in
            var mask: CVPixelBuffer?
            do {
                try handler.perform([request], on: frame)
                mask = request.results?.first.map { smoother.blend($0.pixelBuffer, calm: calm, time: CACurrentMediaTime()) }
            } catch {
                mask = nil
            }
            var report = false
            lock.withLock {
                busy = false
                if let mask {
                    result = (frame, mask)
                } else {
                    result = nil
                    report = !failed
                    failed = true
                }
            }
            if report { onFailure?() }
        }
    }
}
