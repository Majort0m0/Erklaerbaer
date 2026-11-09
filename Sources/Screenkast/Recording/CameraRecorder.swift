import Foundation
import AVFoundation
import CoreMedia

/// Webcam capture with live preview. While recording, frames are written to a separate
/// movie whose timeline starts at the first screen frame (host clock), so camera and
/// screen line up 1:1 in the editor.
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "screenkast.camera.session")
    private let sampleQueue = DispatchQueue(label: "screenkast.camera.samples", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private var currentDeviceID: String?

    /// Shared pause state (set by the app before starting).
    var pauseGate: PauseGate?
    /// Every picture, as it arrives (live mode).
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Ask for 1080p instead of 720p.
    var preferFullHD = false

    // Writing state (sampleQueue only)
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var startTime: CMTime = .invalid
    private var started = false
    private var lastPTS: CMTime = .invalid

    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices.filter { !$0.hasMediaType(.muxed) }
    }

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: sampleQueue)
    }

    var isRunning: Bool { session.isRunning }

    /// Starts (or switches) the camera. `nil` stops it.
    func select(deviceID: String?) {
        sessionQueue.async { [self] in
            guard deviceID != currentDeviceID || (deviceID != nil && !session.isRunning) else { return }
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            currentDeviceID = nil
            if let deviceID, let device = AVCaptureDevice(uniqueID: deviceID),
               let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                if session.outputs.isEmpty, session.canAddOutput(output) { session.addOutput(output) }
                session.sessionPreset = preferFullHD && session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080
                    : session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
                currentDeviceID = deviceID
            }
            session.commitConfiguration()
            if currentDeviceID != nil {
                if !session.isRunning { session.startRunning() }
            } else if session.isRunning {
                session.stopRunning()
            }
        }
    }

    // MARK: Writing

    /// Begins writing frames from host time `start` on (the screen recording's first frame).
    func startWriting(to url: URL, start: CMTime) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        RecordingRecovery.prepare(writer)
        sampleQueue.sync {
            self.writer = writer
            self.input = nil
            self.startTime = start
            self.started = false
            self.lastPTS = .invalid
        }
    }

    /// Finishes the camera movie at host time `end`. Returns false if nothing was recorded.
    func stopWriting(end: CMTime) async -> Bool {
        await withCheckedContinuation { cont in
            sampleQueue.async {
                guard let writer = self.writer, self.started, let input = self.input else {
                    self.writer?.cancelWriting()
                    self.writer = nil
                    cont.resume(returning: false)
                    return
                }
                self.writer = nil
                input.markAsFinished()
                writer.endSession(atSourceTime: CMTimeMaximum(end, self.lastPTS))
                writer.finishWriting {
                    cont.resume(returning: writer.status == .completed)
                }
            }
        }
    }

    func cancelWriting() {
        sampleQueue.sync {
            writer?.cancelWriting()
            writer = nil
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let onFrame, sampleBuffer.isValid, let frame = CMSampleBufferGetImageBuffer(sampleBuffer) { onFrame(frame) }
        guard let writer, sampleBuffer.isValid else { return }
        // Convert the capture clock to the host clock used by ScreenCaptureKit.
        var pts = sampleBuffer.presentationTimeStamp
        if let clock = session.synchronizationClock {
            pts = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        }
        if let gate = pauseGate {
            guard let adjusted = gate.adjust(pts.seconds) else { return }   // paused
            pts = CMTime(seconds: adjusted, preferredTimescale: 1_000_000_000)
        }
        guard pts >= startTime else { return }

        if input == nil {
            guard let fmt = sampleBuffer.formatDescription else { return }
            let dims = CMVideoFormatDescriptionGetDimensions(fmt)
            let aIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dims.width),
                AVVideoHeightKey: Int(dims.height),
                AVVideoCompressionPropertiesKey: RecordingRecovery.keyFrameProperties(fps: 30)
                    .merging([AVVideoAverageBitRateKey: 6_000_000]) { a, _ in a },
            ])
            aIn.expectsMediaDataInRealTime = true
            guard writer.canAdd(aIn) else { self.writer = nil; return }
            writer.add(aIn)
            input = aIn
            guard writer.startWriting() else { self.writer = nil; return }
            writer.startSession(atSourceTime: startTime)
        }
        guard let input, input.isReadyForMoreMediaData else { return }

        // The first frame is stretched back to the session start so the camera covers t = 0.
        let time = started ? pts : startTime
        if lastPTS.isValid && time <= lastPTS { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &retimed)
        if let retimed, input.append(retimed) {
            started = true
            lastPTS = time
        }
    }
}
