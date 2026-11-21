import AppKit
import AVFoundation
import CoreImage

/// `--meetingcamtest <seconds> <folder>`: checks the camera "Erklärbär" from both ends without a meeting
/// program. Opens the camera like Zoom would, saves what it shows without a picture (the note), then sends
/// a test picture into it and checks that exactly this picture comes out, then the note again.
/// Needs the installed camera extension and the camera permission (start with `open -n -W -a … --args`).
enum VirtualCameraTest {
    @MainActor
    static func commandLine(seconds: Int, folder: String) -> Int32 {
        var code: Int32 = 1
        var done = false
        Task { @MainActor in
            defer { done = true }
            do {
                _ = NSApplication.shared
                NSApp.setActivationPolicy(.accessory)
                print("Kamera-Berechtigung:", await AVCaptureDevice.requestAccess(for: .video))
                let out = URL(fileURLWithPath: folder)
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

                // Bring the installed camera up to the version inside this app (as live mode does).
                let installer = VirtualCamera.shared
                installer.refresh()
                for _ in 0..<150 {
                    try await Task.sleep(for: .milliseconds(200))
                    if installer.status != .checking, installer.status != .installing { break }
                }
                print("Kamera-Erweiterung:", installer.status, "Version in der App:", VirtualCamera.bundledVersion ?? "–")

                var found: AVCaptureDevice?
                for _ in 0..<100 {
                    found = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
                        .first { VirtualCameraIDs.isOwnCamera(uniqueID: $0.uniqueID, modelID: $0.modelID) }
                    if found != nil { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard let device = found else {
                    print("Kamera „\(VirtualCameraIDs.cameraName)“ nicht gefunden. Kameras:",
                          AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices.map(\.localizedName))
                    return
                }
                print("Gefunden:", device.localizedName, "|", device.uniqueID, "|", device.modelID, "|", device.manufacturer)
                print("Nicht in der Webcam-Liste von Erklärbär:", !CameraRecorder.availableDevices().contains { $0.uniqueID == device.uniqueID })

                let grabber = try FrameGrabber(device: device)
                grabber.start()
                try await Task.sleep(for: .seconds(2))
                let note = grabber.save(to: out.appendingPathComponent("1-hinweis.png"))
                print("Ohne Live-Bild:", grabber.takeCount(), "Bilder in 2 s, Mitte", note.map(describe) ?? "–")

                let feed = VirtualCameraFeed()
                feed.setActive(true)
                for _ in 0..<60 where !feed.isConnected { try await Task.sleep(for: .milliseconds(100)) }
                print("Eingang verbunden:", feed.isConnected)
                let pattern = TestPattern()
                let sender = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "test.sender"))
                sender.schedule(deadline: .now(), repeating: 1.0 / 30)
                sender.setEventHandler { if let buffer = pattern.next() { feed.send(buffer) } }
                sender.resume()
                try await Task.sleep(for: .seconds(1))
                _ = grabber.takeCount()
                let start = Date()
                try await Task.sleep(for: .seconds(Double(max(2, seconds))))
                let rate = Double(grabber.takeCount()) / Date().timeIntervalSince(start)
                let live = grabber.save(to: out.appendingPathComponent("2-testbild.png"))
                let left = grabber.pixel(atX: 0.2, y: 0.5), right = grabber.pixel(atX: 0.8, y: 0.5)
                print(String(format: "Mit Testbild: %.1f Bilder/s", rate), "links", left.map(describe) ?? "–", "rechts", right.map(describe) ?? "–")
                let ok = left.map { close($0, TestPattern.left) } == true && right.map { close($0, TestPattern.right) } == true
                print(ok ? "✓ Das Testbild kommt unverändert an" : "✗ Das Testbild kommt nicht an (Mitte \(live.map(describe) ?? "–"))")

                sender.cancel()
                feed.stopNow()
                try await Task.sleep(for: .seconds(1.5))
                let after = grabber.save(to: out.appendingPathComponent("3-wieder-hinweis.png"))
                let back = after.map { !close($0, TestPattern.left) && !close($0, TestPattern.right) } == true
                print(back ? "✓ Danach wieder der Hinweis" : "✗ Danach kein Hinweis", after.map(describe) ?? "–")
                grabber.stop()
                code = ok && back ? 0 : 1
            } catch {
                print("Fehler:", error.localizedDescription)
            }
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return code
    }

    /// `--meetingcamgrab <png>`: only reads the camera "Erklärbär" (as a meeting program would, without sending
    /// anything), saves what arrives and tells which macOS video effects act on it for this app.
    @MainActor
    static func grab(path: String) -> Int32 {
        var code: Int32 = 1
        var done = false
        Task { @MainActor in
            defer { done = true }
            do {
                _ = NSApplication.shared
                NSApp.setActivationPolicy(.accessory)
                _ = await AVCaptureDevice.requestAccess(for: .video)
                guard let device = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
                    .first(where: { VirtualCameraIDs.isOwnCamera(uniqueID: $0.uniqueID, modelID: $0.modelID) }) else {
                    print("Kamera „\(VirtualCameraIDs.cameraName)“ nicht gefunden")
                    return
                }
                let grabber = try FrameGrabber(device: device)
                grabber.start()
                try await Task.sleep(for: .seconds(2.5))
                _ = grabber.save(to: URL(fileURLWithPath: path))
                print("Bilder:", grabber.takeCount(), "in 2,5 s, Format:", device.activeFormat.formatDescription.dimensions)
                print("Effekte für Erklärbär eingeschaltet – Porträt:", AVCaptureDevice.isPortraitEffectEnabled, "Studiolicht:", AVCaptureDevice.isStudioLightEnabled,
                      "Ausrichtung:", AVCaptureDevice.isCenterStageEnabled, "Hintergrund:", AVCaptureDevice.isBackgroundReplacementEnabled)
                print("Auf der Kamera möglich/aktiv – Porträt:", device.activeFormat.isPortraitEffectSupported, device.isPortraitEffectActive,
                      "Studiolicht:", device.activeFormat.isStudioLightSupported, device.isStudioLightActive,
                      "Ausrichtung:", device.activeFormat.isCenterStageSupported, device.isCenterStageActive,
                      "Hintergrund:", device.activeFormat.isBackgroundReplacementSupported, device.isBackgroundReplacementActive)
                grabber.stop()
                code = 0
            } catch {
                print("Fehler:", error.localizedDescription)
            }
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return code
    }

    private static func describe(_ c: (Int, Int, Int)) -> String { "rgb(\(c.0),\(c.1),\(c.2))" }

    private static func close(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
        abs(a.0 - b.0) < 24 && abs(a.1 - b.1) < 24 && abs(a.2 - b.2) < 24
    }
}

/// Left orange, right teal, a white bar moving across (so a frozen picture would show).
private final class TestPattern: @unchecked Sendable {
    static let left = (255, 140, 0)
    static let right = (0, 160, 170)
    private var pool: CVPixelBufferPool?
    private var frame = 0

    init() {
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(VirtualCameraIDs.width), kCVPixelBufferHeightKey as String: Int(VirtualCameraIDs.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ] as CFDictionary, &pool)
    }

    func next() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        guard let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bar = (frame * 24) % width
        frame += 1
        for y in 0..<height {
            let line = base + y * row
            for x in 0..<width {
                let c = abs(x - bar) < 20 ? (255, 255, 255) : (x < width / 2 ? Self.left : Self.right)
                line[x * 4] = UInt8(c.2)
                line[x * 4 + 1] = UInt8(c.1)
                line[x * 4 + 2] = UInt8(c.0)
                line[x * 4 + 3] = 255
            }
        }
        return buffer
    }
}

/// Reads a camera the way a meeting program does.
private final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "test.grabber")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var count = 0
    private let context = CIContext()

    init(device: AVCaptureDevice) throws {
        super.init()
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    func start() { session.startRunning() }
    func stop() { session.stopRunning() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.withLock {
            latest = buffer
            count += 1
        }
    }

    func takeCount() -> Int {
        lock.withLock {
            defer { count = 0 }
            return count
        }
    }

    func pixel(atX fx: Double, y fy: Double) -> (Int, Int, Int)? {
        guard let buffer = lock.withLock({ latest }) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let x = Int(Double(CVPixelBufferGetWidth(buffer)) * fx), y = Int(Double(CVPixelBufferGetHeight(buffer)) * fy)
        let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]))
    }

    /// Saves the newest picture and returns the color in its middle.
    func save(to url: URL) -> (Int, Int, Int)? {
        guard let buffer = lock.withLock({ latest }) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        if let cg = context.createCGImage(image, from: image.extent) {
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
        }
        return pixel(atX: 0.5, y: 0.5)
    }
}

/// `--meetingmictest`: sends a 1 kHz tone through the microphone "Erklärbär" and records it the way a
/// meeting program would; afterwards there must be silence (no old sound going round).
/// Needs the installed driver and the microphone permission (start with `open -n -W -a … --args`).
enum VirtualMicrophoneTest {
    @MainActor
    static func commandLine() -> Int32 {
        var code: Int32 = 1
        var done = false
        Task { @MainActor in
            defer { done = true }
            do {
                _ = NSApplication.shared
                NSApp.setActivationPolicy(.accessory)
                print("Mikrofon-Berechtigung:", await AVCaptureDevice.requestAccess(for: .audio))
                print("Treiber eingerichtet:", FileManager.default.fileExists(atPath: VirtualMicrophoneIDs.installed.path),
                      "Zuspielung:", AudioDevices.device(uid: VirtualMicrophoneIDs.feedUID).map(String.init) ?? "fehlt",
                      "Mikrofon:", AudioDevices.device(uid: VirtualMicrophoneIDs.micUID).map(String.init) ?? "fehlt")
                guard let device = AVCaptureDevice(uniqueID: VirtualMicrophoneIDs.micUID) else {
                    print("Das Mikrofon „Erklärbär“ ist für AVFoundation nicht da.")
                    return
                }
                print("Gefunden:", device.localizedName, "| nicht in Erklärbärs Mikrofonliste:",
                      !AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
                        .filter { !VirtualMicrophoneIDs.isOwnMicrophone($0.uniqueID) }.contains { $0.uniqueID == device.uniqueID })
                let recorder = try ToneRecorder(device: device)
                recorder.start()

                let feed = VirtualMicFeed()
                var states: [VirtualMicFeed.State] = []
                feed.onState = { states.append($0) }
                // With the sound of the Mac, as in a meeting: what the feed plays must not come back.
                feed.apply(mic: nil, system: true, exclude: "", on: true)
                // 1 kHz, amplitude 0.5, in 10 ms pieces.
                var phase = 0.0
                let tone = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "test.tone"))
                tone.schedule(deadline: .now(), repeating: .milliseconds(10))
                tone.setEventHandler {
                    var samples = [Float](repeating: 0, count: 480)
                    for i in 0..<480 {
                        samples[i] = Float(0.5 * sin(phase))
                        phase += 2 * .pi * 1000 / VirtualMicrophoneIDs.sampleRate
                    }
                    samples.withUnsafeBufferPointer { feed.voice.write([$0.baseAddress!], frames: 480, channels: 1, interleaved: false) }
                }
                tone.resume()
                try await Task.sleep(for: .seconds(2.5))
                let heard = recorder.analyze(lastSeconds: 1)
                print("Zustand:", states, String(format: "| gehört: Pegel %.3f, %.0f Hz, 1-kHz-Anteil %.3f", heard.rms, heard.frequency, heard.tone))
                tone.cancel()
                try await Task.sleep(for: .seconds(1.5))
                let quiet = recorder.analyze(lastSeconds: 1)
                print(String(format: "Ton aus, Strecke läuft weiter: Pegel %.4f, 1-kHz-Anteil %.4f (kreist der Ton, bleibt er)", quiet.rms, quiet.tone))
                // A meme's sound goes in directly from its file (Erklärbär's own sound is never taken up from the
                // Mac): a short 1 kHz file stands in for a meme with sound.
                let clipFile = FileManager.default.temporaryDirectory.appendingPathComponent("erklaerbaer-meme-test.caf")
                try? FileManager.default.removeItem(at: clipFile)
                let clipFormat = AVAudioFormat(standardFormatWithSampleRate: VirtualMicrophoneIDs.sampleRate, channels: 2)!
                let clipBuffer = AVAudioPCMBuffer(pcmFormat: clipFormat, frameCapacity: 24_000)!
                clipBuffer.frameLength = 24_000
                for i in 0..<24_000 {
                    let v = Float(0.3 * sin(2 * Double.pi * 1000 * Double(i) / VirtualMicrophoneIDs.sampleRate))
                    clipBuffer.floatChannelData![0][i] = v
                    clipBuffer.floatChannelData![1][i] = v
                }
                try AVAudioFile(forWriting: clipFile, settings: clipFormat.settings).write(from: clipBuffer)
                feed.playClip(clipFile)
                try await Task.sleep(for: .seconds(2))
                let meme = recorder.analyze(lastSeconds: 1.5)
                feed.playClip(nil)
                try await Task.sleep(for: .seconds(1))
                let memeGone = recorder.analyze(lastSeconds: 0.8)
                print(String(format: "Meme-Ton aus Datei: 1-kHz-Anteil %.3f, danach %.4f", meme.tone, memeGone.tone))
                let memeHeard: Double? = meme.tone > 0.1 && memeGone.tone < 0.005 ? meme.tone : 0
                await feed.stopNow()
                try await Task.sleep(for: .seconds(1.5))
                let after = recorder.analyze(lastSeconds: 1)
                print(String(format: "Danach: Pegel %.4f, 1-kHz-Anteil %.4f", after.rms, after.tone))
                recorder.stop()
                let ok = heard.tone > 0.2 && abs(heard.frequency - 1000) < 30 && quiet.tone < 0.005 && after.tone < 0.005 && (memeHeard ?? 1) > 0.005
                print(ok ? "✓ Der Prüfton kommt am Mikrofon „Erklärbär“ an, kreist nicht und hört danach auf" : "✗ Prüfton nicht wie erwartet")
                code = ok ? 0 : 1
            } catch {
                print("Fehler:", error.localizedDescription)
            }
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return code
    }
}

/// Records a microphone (mono, 48 kHz) and keeps the samples.
private final class ToneRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "test.tonerecorder")
    private let lock = NSLock()
    private var samples: [Float] = []

    init(device: AVCaptureDevice) throws {
        super.init()
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: VirtualMicrophoneIDs.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
    }

    func start() { session.startRunning() }
    func stop() { session.stopRunning() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = sample.dataBuffer, let data = try? block.dataBytes() else { return }
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        lock.withLock { samples += floats }
    }

    /// Level (RMS), frequency (from zero crossings) and the amplitude of the 1 kHz part alone (Goertzel;
    /// other sound such as a running microphone does not count) of the last seconds.
    func analyze(lastSeconds: Double) -> (rms: Double, frequency: Double, tone: Double) {
        let all = lock.withLock { samples }
        let n = min(all.count, Int(VirtualMicrophoneIDs.sampleRate * lastSeconds))
        guard n > 100 else { return (0, 0, 0) }
        let part = Array(all.suffix(n))
        let rms = sqrt(part.reduce(0) { $0 + Double($1 * $1) } / Double(n))
        var crossings = 0
        for i in 1..<n where (part[i - 1] < 0) != (part[i] < 0) { crossings += 1 }
        let coefficient = 2 * cos(2 * Double.pi * 1000 / VirtualMicrophoneIDs.sampleRate)
        var s1 = 0.0, s2 = 0.0
        for x in part {
            let s0 = Double(x) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = max(0, s1 * s1 + s2 * s2 - coefficient * s1 * s2)
        return (rms, Double(crossings) / 2 / (Double(n) / VirtualMicrophoneIDs.sampleRate), 2 * sqrt(power) / Double(n))
    }
}
