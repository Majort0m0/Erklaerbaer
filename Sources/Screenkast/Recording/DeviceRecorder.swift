import Foundation
import AVFoundation
import CoreMediaIO
import CoreImage
import AppKit
import ScreenCaptureKit

/// Writes a live picture (an iPad or iPhone, or the live mode). The picture keeps the size of the first frame: when
/// the device is turned, later frames are fitted into it with black bars.
final class DeviceMovieWriter {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let deviceAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private var lastPTS: CMTime = .invalid
    private var lastBuffer: CVPixelBuffer?
    private var audioEnd: [String: CMTime] = [:]
    private var skippedAudio = 0
    private(set) var firstPTS: CMTime = .invalid
    let canvas: CGSize
    let audioRoles: [String]

    /// Audio delivered to the writer is expected in the format of `audioFormat`.
    static func audioFormat(channels: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
         AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    }

    init(url: URL, width: Int, height: Int, deviceAudio wantsDeviceAudio: Bool, microphone wantsMicrophone: Bool, fps: Int = 60) throws {
        let w = max(2, width & ~1), h = max(2, height & ~1)
        canvas = CGSize(width: w, height: h)
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        RecordingRecovery.prepare(writer)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: RecordingRecovery.keyFrameProperties(fps: fps).merging([
                AVVideoAverageBitRateKey: min(80_000_000, max(8_000_000, w * h * 6)),
                AVVideoExpectedSourceFrameRateKey: fps,
            ]) { a, _ in a },
        ])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(video) else { throw RecorderError.writerFailed("Video-Spur") }
        writer.add(video)
        let target = writer
        func audio(_ role: String, channels: Int) -> AVAssetWriterInput? {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000,
            ])
            input.expectsMediaDataInRealTime = true
            input.metadata = AudioRole.metadata(role)
            guard target.canAdd(input) else { return nil }
            target.add(input)
            return input
        }
        deviceAudio = wantsDeviceAudio ? audio("system", channels: 2) : nil
        microphone = wantsMicrophone ? audio("mic", channels: 1) : nil
        audioRoles = (deviceAudio != nil ? ["system"] : []) + (microphone != nil ? ["mic"] : [])
    }

    func start(at pts: CMTime) throws {
        guard writer.startWriting() else { throw RecorderError.writerFailed(Self.describe(writer.error)) }
        writer.startSession(atSourceTime: pts)
        firstPTS = pts
    }

    @discardableResult
    func append(_ frame: CVPixelBuffer, at pts: CMTime) -> Bool {
        guard firstPTS.isValid, pts >= firstPTS, !(lastPTS.isValid && pts <= lastPTS), video.isReadyForMoreMediaData else { return false }
        let fits = CVPixelBufferGetWidth(frame) == Int(canvas.width) && CVPixelBufferGetHeight(frame) == Int(canvas.height)
        guard let buffer = fits ? frame : fitted(frame) else { return false }
        guard adaptor.append(buffer, withPresentationTime: pts) else {
            NSLog("Erklärbär: iPad-Bild nach %.2f s nicht geschrieben: %@", pts.seconds - firstPTS.seconds, describe())
            return false
        }
        lastPTS = pts
        lastBuffer = buffer
        return true
    }

    private func fitted(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return nil }
        let image = CIImage(cvPixelBuffer: frame)
        let scale = min(canvas.width / image.extent.width, canvas.height / image.extent.height)
        let placed = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (canvas.width - image.extent.width * scale) / 2, y: (canvas.height - image.extent.height * scale) / 2))
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: canvas))
        context.render(placed.composited(over: black), to: out)
        return out
    }

    func appendAudio(_ sample: CMSampleBuffer, role: String) {
        let start = sample.presentationTimeStamp
        guard firstPTS.isValid, start >= firstPTS, writer.status == .writing,
              let input = role == "mic" ? microphone : deviceAudio, input.isReadyForMoreMediaData else { return }
        // A device may restart its sound with an earlier time stamp; the writer only takes rising ones.
        if let end = audioEnd[role], CMTimeSubtract(end, start).seconds > 0.002 {
            skippedAudio += 1
            if skippedAudio == 1 { NSLog("Erklärbär: iPad-Ton mit früherem Zeitstempel übersprungen (%@, %.3f s)", role, CMTimeSubtract(end, start).seconds) }
            return
        }
        if input.append(sample) {
            audioEnd[role] = CMTimeAdd(start, sample.duration)
        } else {
            NSLog("Erklärbär: iPad-Ton nicht geschrieben (%@): %@", role, describe())
        }
    }

    private func describe() -> String { failure ?? "status \(writer.status.rawValue)" }

    var hasFrames: Bool { lastPTS.isValid }

    /// Finishes the movie; the last picture stands until `end`. Returns the length in seconds.
    func finish(end: CMTime) async throws -> Double {
        guard firstPTS.isValid, lastPTS.isValid else {
            writer.cancelWriting()
            throw RecorderError.noFrames
        }
        guard writer.status == .writing else { throw RecorderError.writerFailed(Self.describe(writer.error)) }
        // An unchanging screen sends no more frames: the last picture has to reach the end.
        let closing = CMTimeSubtract(end, CMTime(value: 1, timescale: 60))
        if closing > lastPTS, let lastBuffer {
            for _ in 0..<200 where !video.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(5)) }
            if video.isReadyForMoreMediaData, adaptor.append(lastBuffer, withPresentationTime: closing) { lastPTS = closing }
        }
        video.markAsFinished()
        deviceAudio?.markAsFinished()
        microphone?.markAsFinished()
        let last = CMTimeMaximum(end, lastPTS)
        writer.endSession(atSourceTime: last)
        await writer.finishWriting()
        guard writer.status == .completed else { throw RecorderError.writerFailed(Self.describe(writer.error)) }
        return CMTimeSubtract(last, firstPTS).seconds
    }

    func cancel() { writer.cancelWriting() }

    /// The text of an error with its code and the code behind it.
    static func describe(_ error: Error?) -> String {
        guard let error else { return "unbekannter Fehler" }
        let ns = error as NSError
        let inner = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { " / \($0.domain) \($0.code)" } ?? ""
        return "\(ns.localizedDescription) (\(ns.code)\(inner))"
    }

    /// Why the writer stopped working, if it did.
    var failure: String? { writer.status == .failed ? Self.describe(writer.error) : nil }
}

/// Records the screen and sound of an iPad or iPhone connected by cable (the way QuickTime does),
/// optionally with a microphone of the Mac. All times are on the host clock, like the other streams.
final class DeviceRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(label: "screenkast.device.samples", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "screenkast.device.session")
    private var session: AVCaptureSession?
    private var micSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var deviceAudioOutput: AVCaptureAudioDataOutput?
    private var micOutput: AVCaptureAudioDataOutput?
    private var observers: [NSObjectProtocol] = []

    // sampleQueue only
    private var writer: DeviceMovieWriter?
    private var outputURL: URL?
    private var wantsDeviceAudio = false
    private var wantsMicrophone = false
    private var firstFrame: CheckedContinuation<(CaptureGeometry, Double), Error>?
    private var failureReported = false
    private var deviceClock: CMClock?
    private var micClock: CMClock?

    private(set) var audioTrackRoles: [String] = []
    /// Shared pause state (set by the app before starting).
    var pauseGate: PauseGate?
    var onStreamError: ((Error) -> Void)?
    /// The running capture (for the live picture on the Mac).
    var captureSession: AVCaptureSession? { session }

    /// Without this, macOS does not offer connected iPads and iPhones as capture devices.
    @discardableResult
    static func allowDevices() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        return CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow) == 0
    }

    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
    }

    /// - Parameter monitor: plays the sound of the device on the Mac while recording (the device itself may go silent).
    func start(deviceID: String, microphoneID: String?, deviceAudio: Bool, monitor: Bool, outputURL: URL) async throws -> (CaptureGeometry, Double) {
        guard session == nil else { throw RecorderError.alreadyRunning }
        guard let device = AVCaptureDevice(uniqueID: deviceID) else { throw RecorderError.deviceMissing }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input) else { throw RecorderError.deviceMissing }
        session.addInput(input)
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(video) else { throw RecorderError.deviceMissing }
        session.addOutput(video)
        var audio: AVCaptureAudioDataOutput?
        if deviceAudio {
            let output = AVCaptureAudioDataOutput()
            output.audioSettings = DeviceMovieWriter.audioFormat(channels: 2)
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            if session.canAddOutput(output) {
                session.addOutput(output)
                audio = output
            }
        }
        if monitor {
            let preview = AVCaptureAudioPreviewOutput()
            preview.volume = 1
            if session.canAddOutput(preview) { session.addOutput(preview) }
        }
        session.commitConfiguration()

        var mic: AVCaptureSession?
        var micData: AVCaptureAudioDataOutput?
        if let microphoneID, let micDevice = AVCaptureDevice(uniqueID: microphoneID), let micInput = try? AVCaptureDeviceInput(device: micDevice) {
            let s = AVCaptureSession()
            let output = AVCaptureAudioDataOutput()
            output.audioSettings = DeviceMovieWriter.audioFormat(channels: 1)
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            if s.canAddInput(micInput), s.canAddOutput(output) {
                s.addInput(micInput)
                s.addOutput(output)
                mic = s
                micData = output
            }
        }

        self.session = session
        micSession = mic
        videoOutput = video
        deviceAudioOutput = audio
        micOutput = micData
        let lost = { [weak self] (error: Error) in self?.onStreamError?(error) }
        observers = [
            NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { _ in lost(RecorderError.deviceLost) },
            NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
                lost((note.userInfo?[AVCaptureSessionErrorKey] as? Error) ?? RecorderError.deviceLost)
            },
        ]
        sampleQueue.sync {
            self.writer = nil
            self.outputURL = outputURL
            self.wantsDeviceAudio = audio != nil
            self.wantsMicrophone = micData != nil
            self.failureReported = false
            self.deviceClock = session.synchronizationClock
            self.micClock = mic?.synchronizationClock
        }
        let sessions = [session] + (mic.map { [$0] } ?? [])
        return try await withCheckedThrowingContinuation { cont in
            sampleQueue.async {
                self.firstFrame = cont
                self.sampleQueue.asyncAfter(deadline: .now() + 15) {
                    if let c = self.firstFrame {
                        self.firstFrame = nil
                        c.resume(throwing: RecorderError.deviceSilent)
                    }
                }
                self.sessionQueue.async { sessions.forEach { $0.startRunning() } }
            }
        }
    }

    private func stopSessions() async {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        let sessions = [session, micSession].compactMap { $0 }
        session = nil
        micSession = nil
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                sessions.forEach { $0.stopRunning() }
                cont.resume()
            }
        }
    }

    /// Stops and finishes the file. Returns the recording length in seconds.
    func stop() async throws -> Double {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let end = CMTime(seconds: pauseGate?.recordingTime(at: now) ?? now, preferredTimescale: 1_000_000_000)
        await stopSessions()
        let finishing: DeviceMovieWriter? = sampleQueue.sync {
            let w = writer
            writer = nil
            return w
        }
        guard let finishing else { throw RecorderError.noFrames }
        return try await finishing.finish(end: end)
    }

    func cancel() async {
        await stopSessions()
        sampleQueue.sync {
            writer?.cancel()
            writer = nil
            if let c = firstFrame { firstFrame = nil; c.resume(throwing: CancellationError()) }
        }
    }

    // MARK: Samples (on sampleQueue)

    /// Recording time of a sample (host clock, pauses removed); `nil` inside a pause.
    private func recordingTime(_ pts: CMTime, clock: CMClock?) -> CMTime? {
        var host = pts
        if let clock { host = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()) }
        guard let gate = pauseGate else { return host }
        return gate.adjust(host.seconds).map { CMTime(seconds: $0, preferredTimescale: 1_000_000_000) }
    }

    /// Copy of an audio sample buffer starting at `time`.
    static func moved(_ sample: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        let offset = CMTimeSubtract(time, sample.presentationTimeStamp)
        for i in timings.indices {
            timings[i].presentationTimeStamp = CMTimeAdd(timings[i].presentationTimeStamp, offset)
            timings[i].decodeTimeStamp = .invalid
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &out)
        return out
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sample.isValid else { return }
        if output === videoOutput {
            guard let frame = CMSampleBufferGetImageBuffer(sample), let time = recordingTime(sample.presentationTimeStamp, clock: session?.synchronizationClock ?? deviceClock) else { return }
            if writer == nil, let url = outputURL { open(url, frame: frame, at: time) }
            writer?.append(frame, at: time)
            // The writer gave up: say so now, not when the recording is stopped much later.
            if !failureReported, let failure = writer?.failure {
                failureReported = true
                onStreamError?(RecorderError.writerFailed(failure))
            }
        } else if output === deviceAudioOutput || output === micOutput {
            let mic = output === micOutput
            guard let writer, let time = recordingTime(sample.presentationTimeStamp, clock: mic ? micClock : deviceClock),
                  let audio = Self.moved(sample, to: time) else { return }
            writer.appendAudio(audio, role: mic ? "mic" : "system")
        }
    }

    private func open(_ url: URL, frame: CVPixelBuffer, at time: CMTime) {
        outputURL = nil
        do {
            let new = try DeviceMovieWriter(url: url, width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame),
                                            deviceAudio: wantsDeviceAudio, microphone: wantsMicrophone)
            try new.start(at: time)
            writer = new
            audioTrackRoles = new.audioRoles
            let geometry = CaptureGeometry(pixelSize: new.canvas, pointPixelScale: 1, frame: CGRect(origin: .zero, size: new.canvas))
            firstFrame?.resume(returning: (geometry, time.seconds))
            firstFrame = nil
        } catch {
            firstFrame?.resume(throwing: error)
            firstFrame = nil
        }
    }

    // MARK: Trying it out

    func connectionReport() -> String {
        (session?.connections ?? []).map { c in
            let ports = c.inputPorts.map { $0.mediaType.rawValue }.joined(separator: ",")
            return "Verbindung \(ports) -> \(c.output.map { String(describing: type(of: $0)) } ?? "Vorschau") aktiv=\(c.isActive) an=\(c.isEnabled)"
        }.joined(separator: "\n")
    }

    func levelReport() -> String {
        let levels = deviceAudioOutput?.connections.flatMap(\.audioChannels).map { String(format: "%.0f dB", $0.averagePowerLevel) } ?? []
        let failed: String? = sampleQueue.sync { writer?.failure }
        return "Pegel \(levels) \(failed ?? "")"
    }

    /// `--devicetest <seconds> <movie>`: records the first connected device and reports what arrived.
    @MainActor
    static func commandLine(seconds: Double, path: String) -> Int32 {
        var code: Int32 = 1
        var done = false
        Task { @MainActor in
            allowDevices()
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            print("Kamera-Berechtigung:", granted)
            var devices = availableDevices()
            for _ in 0..<40 where devices.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                devices = availableDevices()
            }
            guard let device = devices.first else { print("Kein Gerät gefunden"); done = true; return }
            print("Gerät:", device.localizedName)
            let recorder = DeviceRecorder()
            let arguments = CommandLine.arguments
            let gate: PauseGate? = arguments.contains("--gate") ? PauseGate() : nil
            recorder.pauseGate = gate
            let webcam: CameraRecorder? = arguments.contains("--webcam") ? CameraRecorder() : nil
            webcam?.pauseGate = gate
            webcam?.select(deviceID: CameraRecorder.availableDevices().first?.uniqueID)
            do {
                let (geometry, host) = try await recorder.start(deviceID: device.uniqueID, microphoneID: nil, deviceAudio: true, monitor: !arguments.contains("--nomonitor"), outputURL: URL(fileURLWithPath: path))
                print("Erstes Bild:", geometry.pixelSize, "Spuren:", recorder.audioTrackRoles)
                print(recorder.connectionReport())
                var preview: DevicePreviewPanel?
                if let i = arguments.firstIndex(of: "--preview"), i + 1 < arguments.count, let session = recorder.captureSession {
                    _ = NSApplication.shared
                    NSApp.setActivationPolicy(.accessory)
                    let panel = DevicePreviewPanel()
                    panel.show(session: session, pixelSize: geometry.pixelSize, name: device.localizedName)
                    preview = panel
                    try await Task.sleep(for: .seconds(2))
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    if let number = panel.windowNumber, let window = content.windows.first(where: { Int($0.windowID) == number }) {
                        let config = SCStreamConfiguration()
                        config.width = Int(window.frame.width) * 2
                        config.height = Int(window.frame.height) * 2
                        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                        let rep = NSBitmapImageRep(cgImage: image)
                        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[i + 1]))
                        print("Live-Fenster:", window.frame.size, window.title ?? "")
                    } else {
                        print("Live-Fenster nicht gefunden")
                    }
                }
                try? webcam?.startWriting(to: URL(fileURLWithPath: path + ".cam.mov"), start: CMTime(seconds: host, preferredTimescale: 1_000_000_000))
                for second in 0..<Int(seconds) {
                    try await Task.sleep(for: .seconds(1))
                    print(second + 1, recorder.levelReport())
                }
                if let webcam {
                    let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                    print("Kamera:", await webcam.stopWriting(end: CMTime(seconds: gate?.recordingTime(at: now) ?? now, preferredTimescale: 1_000_000_000)))
                }
                preview?.hide()
                let length = try await recorder.stop()
                let asset = AVURLAsset(url: URL(fileURLWithPath: path))
                let video = try await asset.loadTracks(withMediaType: .video)
                let audio = try await asset.loadTracks(withMediaType: .audio)
                let size = try await video.first?.load(.naturalSize)
                let rate = try await video.first?.load(.nominalFrameRate)
                var peak: Float = 0
                var audible = 0, total = 0
                if let track = audio.first {
                    let reader = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
                    reader.add(output)
                    reader.startReading()
                    while let sample = output.copyNextSampleBuffer() {
                        guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                        var count = 0
                        var pointer: UnsafeMutablePointer<CChar>?
                        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &count, dataPointerOut: &pointer)
                        pointer?.withMemoryRebound(to: Int16.self, capacity: count / 2) { p in
                            for i in 0..<(count / 2) {
                                let level = abs(Float(p[i])) / 32768
                                peak = max(peak, level)
                                total += 1
                                if level > 0.002 { audible += 1 }
                            }
                        }
                    }
                }
                print("Länge:", length, "Größe:", size as Any, "Bilder/s:", rate as Any, "Tonspuren:", audio.count, "Tonspitze:", peak, "hörbar:", total > 0 ? Int(100 * audible / total) : 0, "%", "Mithören:", !CommandLine.arguments.contains("--nomonitor"))
                code = 0
            } catch {
                print("Fehler:", error.localizedDescription)
                await recorder.cancel()
            }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return code
    }
}
