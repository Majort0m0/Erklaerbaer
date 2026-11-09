import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

enum CaptureTarget {
    case display(SCDisplay)
    case window(SCWindow)
    /// Part of a display; rect in display points (origin top-left).
    case region(SCDisplay, CGRect)
    /// An iPad or iPhone on a cable.
    case device(id: String, name: String)

    var name: String {
        switch self {
        case .display(let d): return "Bildschirm \(d.width)×\(d.height)"
        case .region(_, let r): return "Bereich \(Int(r.width))×\(Int(r.height))"
        case .window(let w): return [w.owningApplication?.applicationName, w.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " – ")
        case .device(_, let name): return name
        }
    }

    /// Captured area in global CoreGraphics coordinates (points, origin top-left).
    var frame: CGRect {
        switch self {
        case .display(let d): return d.frame
        case .window(let w): return w.frame
        case .region(let d, let r): return CGRect(x: d.frame.minX + r.minX, y: d.frame.minY + r.minY, width: r.width, height: r.height)
        case .device: return .zero
        }
    }
}

struct CaptureGeometry {
    var pixelSize: CGSize
    var pointPixelScale: Double
    var frame: CGRect
}

enum RecorderError: LocalizedError {
    case noFrames, writerFailed(String), alreadyRunning, deviceMissing, deviceSilent, deviceLost

    var errorDescription: String? {
        switch self {
        case .noFrames: return "Es wurden keine Bilder aufgenommen. Bitte die Bildschirmaufnahme-Berechtigung in den Systemeinstellungen prüfen."
        case .writerFailed(let m): return "Video konnte nicht geschrieben werden: \(m)"
        case .alreadyRunning: return "Es läuft bereits eine Aufnahme."
        case .deviceMissing: return "Das iPad ist nicht verbunden oder wird gerade von einer anderen App benutzt (z. B. QuickTime Player)."
        case .deviceSilent: return "Das iPad liefert kein Bild. Bitte entsperren, auf dem iPad „Vertrauen“ bestätigen und QuickTime Player schließen, falls dort eine Aufnahme offen ist."
        case .deviceLost: return "Die Verbindung zum iPad wurde getrennt."
        }
    }
}

/// Screen capture with ScreenCaptureKit (cursor hidden, it is rendered later) written
/// to a HEVC .mov with AVAssetWriter. Optional microphone via SCStream.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "screenkast.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    /// Roles of the written audio tracks in track order ("system", "mic").
    private(set) var audioTrackRoles: [String] = []
    private var videoSettings: [String: Any] = [:]
    private var wantsMic = false
    private var sessionStarted = false
    private var firstPTS: CMTime = .invalid
    private var lastVideoPTS: CMTime = .invalid
    private var pendingVideo: CMSampleBuffer?
    private var firstPendingPTS: CMTime = .invalid
    private var firstFrame: CheckedContinuation<Double, Error>?
    private(set) var microphoneFailed = false

    var onStreamError: ((Error) -> Void)?
    /// Shared pause state (set by the app before starting).
    var pauseGate: PauseGate?

    // MARK: Start

    /// Starts capturing. Returns the geometry and the host time (seconds) of the first written frame.
    func start(target: CaptureTarget, microphoneID: String?, systemAudio: Bool, excludedApps: [SCRunningApplication],
               outputURL: URL, fps: Int = 60) async throws -> (CaptureGeometry, Double) {
        guard stream == nil else { throw RecorderError.alreadyRunning }

        let filter: SCContentFilter
        var region: CGRect?
        switch target {
        case .display(let d):
            filter = SCContentFilter(display: d, excludingApplications: excludedApps, exceptingWindows: [])
        case .window(let w):
            filter = SCContentFilter(desktopIndependentWindow: w)
        case .region(let d, let r):
            filter = SCContentFilter(display: d, excludingApplications: excludedApps, exceptingWindows: [])
            region = r
        case .device:
            throw RecorderError.deviceMissing   // recorded by DeviceRecorder
        }
        let scale = Double(filter.pointPixelScale)
        let rect = region ?? filter.contentRect
        let width = Int((rect.width * scale / 2).rounded()) * 2
        let height = Int((rect.height * scale / 2).rounded()) * 2

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        if let region { config.sourceRect = region }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 8
        config.ignoreShadowsSingleWindow = true
        config.capturesAudio = systemAudio
        if systemAudio {
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }
        wantsMic = microphoneID != nil
        if let mic = microphoneID {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = mic
        }

        // Writer
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        RecordingRecovery.prepare(writer)   // stays readable if the app crashes
        let bitrate = min(80_000_000, max(8_000_000, width * height * 6))
        videoSettings = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            // Key frame every second: crash-safe fragments can end there (see RecordingRecovery).
            AVVideoCompressionPropertiesKey: RecordingRecovery.keyFrameProperties(fps: fps).merging([
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
            ]) { a, _ in a },
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = true
        guard writer.canAdd(vIn) else { throw RecorderError.writerFailed("Video-Spur") }
        writer.add(vIn)
        audioTrackRoles = []
        systemAudioInput = nil
        if systemAudio {
            // Format is fixed by the configuration above, so this track can be created right away.
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            aIn.expectsMediaDataInRealTime = true
            aIn.metadata = AudioRole.metadata("system")
            if writer.canAdd(aIn) {
                writer.add(aIn)
                systemAudioInput = aIn
                audioTrackRoles.append("system")
            }
        }
        self.writer = writer
        self.videoInput = vIn
        self.audioInput = nil
        sessionStarted = false
        firstPTS = .invalid
        lastVideoPTS = .invalid
        pendingVideo = nil
        firstPendingPTS = .invalid
        microphoneFailed = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if wantsMic {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        if systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        self.stream = stream

        let geometry = CaptureGeometry(pixelSize: CGSize(width: width, height: height),
                                       pointPixelScale: scale,
                                       frame: target.frame)

        let firstHost: Double = try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.firstFrame = cont
                Task {
                    do {
                        try await stream.startCapture()
                    } catch {
                        self.queue.async {
                            self.firstFrame?.resume(throwing: error)
                            self.firstFrame = nil
                        }
                    }
                }
                // Fail if nothing arrives (missing permission, etc.)
                self.queue.asyncAfter(deadline: .now() + 6) {
                    if let c = self.firstFrame {
                        self.firstFrame = nil
                        c.resume(throwing: RecorderError.noFrames)
                    }
                }
            }
        }
        return (geometry, firstHost)
    }

    // MARK: Stop

    /// Stops capturing and finalizes the file. Returns the recording duration in seconds.
    func stop() async throws -> Double {
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let endHost = pauseGate.map { CMTime(seconds: $0.recordingTime(at: hostNow.seconds), preferredTimescale: 1_000_000_000) } ?? hostNow
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard let writer = self.writer, self.sessionStarted else {
                    self.writer?.cancelWriting()
                    self.writer = nil
                    cont.resume(throwing: RecorderError.noFrames)
                    return
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.systemAudioInput?.markAsFinished()
                let end = CMTimeMaximum(endHost, self.lastVideoPTS)
                writer.endSession(atSourceTime: end)
                let duration = CMTimeSubtract(end, self.firstPTS).seconds
                writer.finishWriting {
                    self.writer = nil
                    if writer.status == .completed {
                        cont.resume(returning: duration)
                    } else {
                        cont.resume(throwing: RecorderError.writerFailed(writer.error?.localizedDescription ?? "unbekannter Fehler"))
                    }
                }
            }
        }
    }

    func cancel() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        queue.sync {
            writer?.cancelWriting()
            writer = nil
            if let c = firstFrame { firstFrame = nil; c.resume(throwing: CancellationError()) }
        }
    }

    // MARK: SCStreamOutput (runs on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer raw: CMSampleBuffer, of type: SCStreamOutputType) {
        guard raw.isValid, let writer else { return }
        // Drop samples captured during a pause and shift later ones back by the paused time.
        let sampleBuffer: CMSampleBuffer
        if let gate = pauseGate {
            guard let shifted = gate.retime(raw) else { return }
            sampleBuffer = shifted
        } else {
            sampleBuffer = raw
        }
        switch type {
        case .screen:
            handleVideo(sampleBuffer, writer: writer)
        case .microphone:
            handleAudio(sampleBuffer, writer: writer)
        case .audio:
            guard sessionStarted, let aIn = systemAudioInput,
                  sampleBuffer.presentationTimeStamp >= firstPTS, aIn.isReadyForMoreMediaData else { return }
            _ = aIn.append(sampleBuffer)
        default:
            break
        }
    }

    private func handleVideo(_ sb: CMSampleBuffer, writer: AVAssetWriter) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw), status == .complete else { return }
        let pts = sb.presentationTimeStamp

        if !sessionStarted {
            // Wait (max. 1 s) for the first microphone buffer so the audio track can match its format.
            if wantsMic && audioInput == nil && !microphoneFailed {
                if !firstPendingPTS.isValid { firstPendingPTS = pts }
                pendingVideo = sb
                if CMTimeSubtract(pts, firstPendingPTS).seconds < 1.0 { return }
                microphoneFailed = true
            }
            startSession(at: pts, writer: writer)
        }
        guard sessionStarted, let vIn = videoInput else { return }
        if lastVideoPTS.isValid && pts <= lastVideoPTS { return }
        if vIn.isReadyForMoreMediaData {
            if vIn.append(sb) {
                lastVideoPTS = pts
            }
        }
    }

    private func startSession(at pts: CMTime, writer: AVAssetWriter) {
        guard writer.startWriting() else {
            if let c = firstFrame { firstFrame = nil; c.resume(throwing: RecorderError.writerFailed(writer.error?.localizedDescription ?? "")) }
            return
        }
        writer.startSession(atSourceTime: pts)
        sessionStarted = true
        firstPTS = pts
        if let c = firstFrame {
            firstFrame = nil
            c.resume(returning: pts.seconds)
        }
    }

    private func handleAudio(_ sb: CMSampleBuffer, writer: AVAssetWriter) {
        if audioInput == nil && !sessionStarted && !microphoneFailed {
            guard let fmt = sb.formatDescription,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
            let channels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: min(48_000, max(8_000, asbd.mSampleRate)),
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000,
            ]
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: fmt)
            aIn.expectsMediaDataInRealTime = true
            aIn.metadata = AudioRole.metadata("mic")
            if writer.canAdd(aIn) {
                writer.add(aIn)
                audioInput = aIn
                audioTrackRoles.append("mic")
            } else {
                microphoneFailed = true
            }
            // A video frame was already waiting: start now.
            if let pending = pendingVideo {
                pendingVideo = nil
                startSession(at: pending.presentationTimeStamp, writer: writer)
                if sessionStarted, let vIn = videoInput, vIn.isReadyForMoreMediaData, vIn.append(pending) {
                    lastVideoPTS = pending.presentationTimeStamp
                }
            }
            return
        }
        guard sessionStarted, let aIn = audioInput else { return }
        if sb.presentationTimeStamp < firstPTS { return }
        if aIn.isReadyForMoreMediaData {
            _ = aIn.append(sb)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            if let c = self.firstFrame { self.firstFrame = nil; c.resume(throwing: error) }
        }
        onStreamError?(error)
    }
}
