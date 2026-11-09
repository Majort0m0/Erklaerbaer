import AppKit
import AVFoundation
import CoreImage
import Metal
import ScreenCaptureKit
import ImageIO

/// Runs the live picture: takes the newest frame of every source, composes 30 pictures per second
/// and hands them out (windows, recording).
final class LiveEngine: @unchecked Sendable {
    /// A source that shows the mouse: where it is on the screen (points, origin top left).
    enum Area { case none, fixed(CGRect) }

    var onPresent: ((CVPixelBuffer) -> Void)?
    var onProblem: ((String) -> Void)?
    private(set) var framesPerSecond = 0

    private let lock = NSLock()
    private var config = LiveConfig()
    private var stamp = 0
    private var sourceFrame: CVPixelBuffer?
    private var sourceGeneration = 0
    private var wantedGeneration = 0
    private var area: CGRect?
    private var cameraFrame: CVPixelBuffer?
    private var newClicks: [(CGPoint, Double)] = []
    private var presentPending = false
    private var meme: ActiveMeme?
    private var backgroundImage: CIImage?
    private let segmenter = LiveSegmenter()

    /// A meme being shown: its sound comes out of the Mac.
    private final class ActiveMeme {
        let url: URL
        let player: AVPlayer
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let duration: Double
        let transparent: Bool
        var frame: CVPixelBuffer?

        init(url: URL, duration: Double, transparent: Bool) {
            self.url = url
            self.duration = duration
            self.transparent = transparent
            let item = AVPlayerItem(url: url)
            item.add(output)
            player = AVPlayer(playerItem: item)
        }
    }

    private let renderQueue = DispatchQueue(label: "screenkast.live.render", qos: .userInteractive)
    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private var timer: DispatchSourceTimer?
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // renderQueue only
    private var lastStamp = 0
    private var lastOutput: CVPixelBuffer?
    private var fadeFrom: CIImage?
    private var fadeStart: Double?
    private var trail: [(CGPoint, Double)] = []
    private var clicks: [(CGPoint, Double)] = []
    private var counted = 0
    private var countStart = 0.0

    let camera = CameraRecorder()
    private var screen: LiveScreenSource?
    private var device: LiveDeviceSource?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var lastKey: (label: String, time: Double)?

    // Recording (all of it on writerQueue)
    private let writerQueue = DispatchQueue(label: "screenkast.live.writer", qos: .userInitiated)
    private var writer: DeviceMovieWriter?
    private var microphone: LiveMicrophone?

    init() {
        context = MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) } ?? CIContext(options: [.cacheIntermediates: false])
        camera.preferFullHD = true
        camera.onFrame = { [weak self] frame in
            guard let self else { return }
            let separate: Bool = self.lock.withLock {
                self.cameraFrame = frame
                return self.config.background == true && self.backgroundImage != nil
            }
            if separate { self.segmenter.submit(frame) }
        }
        segmenter.onFailure = { [weak self] in
            self?.onProblem?("Der virtuelle Hintergrund lässt sich gerade nicht berechnen. Oft hilft ein Neustart des Macs.")
        }
        let size = LiveCompositor.canvas.size
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary, [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ] as CFDictionary, &pool)
    }

    // MARK: Running

    func start() {
        let now = CACurrentMediaTime()
        renderQueue.async { self.countStart = now }
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let at = CGEvent(source: nil)?.location else { return }
            let time = CACurrentMediaTime()
            self.lock.withLock { self.newClicks.append((at, time)) }
        }
    }

    func stop() async {
        timer?.cancel()
        timer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        watchKeys(false)
        camera.select(deviceID: nil)
        let running: ActiveMeme? = lock.withLock {
            defer { meme = nil }
            return meme
        }
        running?.player.pause()
        await stopSource()
        lock.withLock {
            sourceFrame = nil
            cameraFrame = nil
        }
        renderQueue.sync {
            lastOutput = nil
            fadeFrom = nil
        }
    }

    /// Follows keyboard shortcuts (only combinations with ⌘, ⌃ or ⌥, never plain typing).
    func watchKeys(_ on: Bool) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard on else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let label = KeyShortcuts.label(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, flags: event.modifierFlags) else { return }
            let time = CACurrentMediaTime()
            self.lock.withLock { self.lastKey = (label, time) }
        }
    }

    func setConfig(_ new: LiveConfig) {
        lock.withLock {
            if new.scene != config.scene || new.bubble != config.bubble { stamp += 1 }
            config = new
        }
        segmenter.calm = new.backgroundCalm ?? 0.5
    }

    // MARK: Sources

    private func stopSource() async {
        let (oldScreen, oldDevice) = (screen, device)
        screen = nil
        device = nil
        await oldScreen?.stop()
        await oldDevice?.stop()
    }

    private func nextGeneration(area new: CGRect?) -> Int {
        lock.withLock {
            wantedGeneration += 1
            stamp += 1
            area = new
            return wantedGeneration
        }
    }

    private func receive(_ frame: CVPixelBuffer, _ generation: Int) {
        lock.withLock {
            guard generation == wantedGeneration else { return }
            sourceFrame = frame
            sourceGeneration = generation
        }
    }

    /// Returns a message if it did not work.
    func useScreen(filter: SCContentFilter, area: CGRect) async -> String? {
        let generation = nextGeneration(area: area)
        await stopSource()
        let source = LiveScreenSource(filter: filter) { [weak self] frame in self?.receive(frame, generation) }
        source.onError = { [weak self] error in self?.onProblem?("Die Quelle ist nicht mehr verfügbar: \(error.localizedDescription)") }
        screen = source
        do {
            try await source.start()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func useDevice(id: String, hear: Bool) async -> String? {
        let generation = nextGeneration(area: nil)
        await stopSource()
        let source = LiveDeviceSource(onFrame: { [weak self] frame in self?.receive(frame, generation) },
                                      onAudio: { [weak self] sample, clock in self?.write(sample, clock: clock, role: "system") })
        device = source
        do {
            try await source.start(deviceID: id, hear: hear)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// A captured window moved or changed its size.
    func updateArea(_ new: CGRect, resize: Bool) {
        lock.withLock { area = new }
        if resize { screen?.resize(to: new.size) }
    }

    // MARK: Picture

    private func tick() {
        let now = CACurrentMediaTime()
        let (cfg, currentStamp, frame, ready, where_, cam, fresh): (LiveConfig, Int, CVPixelBuffer?, Bool, CGRect?, CVPixelBuffer?, [(CGPoint, Double)]) = lock.withLock {
            let fresh = newClicks
            newClicks = []
            return (config, stamp, sourceFrame, sourceGeneration == wantedGeneration, area, cameraFrame, fresh)
        }
        if currentStamp != lastStamp {
            lastStamp = currentStamp
            fadeFrom = lastOutput.map { CIImage(cvPixelBuffer: $0) }
            fadeStart = nil
        }
        if fadeFrom != nil, fadeStart == nil, cfg.scene == .webcam || ready { fadeStart = now }

        var webcam = cam.map { CIImage(cvPixelBuffer: $0) }
        if cfg.background == true, let picture = lock.withLock({ backgroundImage }), let pair = segmenter.latest {
            webcam = LiveCompositor.person(CIImage(cvPixelBuffer: pair.frame), mask: LiveCompositor.maskImage(pair.mask), background: picture, edge: cfg.backgroundEdge ?? 0.5)
        }

        var image: CIImage
        if let from = fadeFrom, fadeStart == nil {
            image = from   // the new source has not delivered yet: the last picture stays
        } else {
            image = LiveCompositor.compose(config: cfg, source: ready ? frame.map { CIImage(cvPixelBuffer: $0) } : nil, camera: webcam,
                                           effects: effects(now: now, area: where_, fresh: fresh, config: cfg), meme: memeLayer(now: now))
            if let from = fadeFrom, let start = fadeStart {
                let p = (now - start) / 0.25
                if p >= 1 {
                    fadeFrom = nil
                    fadeStart = nil
                } else {
                    image = LiveCompositor.faded(image, p).composited(over: from).cropped(to: LiveCompositor.canvas)
                }
            }
        }
        guard let pool else { return }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        guard let buffer = made else { return }
        context.render(image, to: buffer, bounds: LiveCompositor.canvas, colorSpace: sRGB)
        lastOutput = buffer
        count(now)
        present(buffer)
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        writerQueue.async { self.writer?.append(buffer, at: time) }
    }

    /// The picture behind the person (nil: none). Large pictures are reduced, photos turned upright.
    func setBackground(url: URL?) {
        var image: CIImage?
        if let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1920,
           ] as CFDictionary) {
            image = CIImage(cgImage: picture)
        }
        lock.withLock { backgroundImage = image }
        segmenter.reset()
    }

    /// Starts a meme; pressing the same one again takes it away.
    func playMeme(url: URL, duration: Double, transparent: Bool = false) {
        let running: ActiveMeme? = lock.withLock { meme }
        running?.player.pause()
        guard running?.url != url else {
            lock.withLock { meme = nil }
            return
        }
        let new = ActiveMeme(url: url, duration: duration, transparent: transparent)
        lock.withLock { meme = new }
        new.player.play()
    }

    private func memeLayer(now: Double) -> (image: CIImage, alpha: Double, transparent: Bool)? {
        guard let current = lock.withLock({ meme }) else { return nil }
        let time = current.output.itemTime(forHostTime: now)
        guard time.isValid else { return nil }
        if current.output.hasNewPixelBuffer(forItemTime: time) {
            current.frame = current.output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) ?? current.frame
        }
        let seconds = max(0, time.seconds)
        if seconds >= current.duration - 0.02 {
            lock.withLock { if meme === current { meme = nil } }
            return nil
        }
        guard let frame = current.frame else { return nil }
        return (CIImage(cvPixelBuffer: frame), min(1, seconds / 0.15, (current.duration - seconds) / 0.15), current.transparent)
    }

    private func effects(now: Double, area: CGRect?, fresh: [(CGPoint, Double)], config: LiveConfig) -> LiveEffects {
        let key: (label: String, age: Double)? = config.keys == true ? lock.withLock { lastKey.map { ($0.label, now - $0.time) } } : nil
        guard let area, area.width > 0, area.height > 0 else { return LiveEffects(key: key) }
        func normalized(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - area.minX) / area.width, y: (p.y - area.minY) / area.height) }
        clicks += fresh.filter { area.contains($0.0) }
        clicks.removeAll { now - $0.1 > LiveCompositor.clickLife }
        if config.trail, let at = CGEvent(source: nil)?.location, area.contains(at) {
            if trail.last.map({ hypot($0.0.x - at.x, $0.0.y - at.y) > 0.5 }) ?? true { trail.append((at, now)) }
        }
        trail.removeAll { now - $0.1 > LiveCompositor.trailLife }
        return LiveEffects(trail: trail.map { (normalized($0.0), now - $0.1) }, clicks: clicks.map { (normalized($0.0), now - $0.1) }, key: key)
    }

    private func count(_ now: Double) {
        counted += 1
        if now - countStart >= 1 {
            framesPerSecond = Int((Double(counted) / (now - countStart)).rounded())
            counted = 0
            countStart = now
        }
    }

    private func present(_ buffer: CVPixelBuffer) {
        guard let onPresent else { return }
        let busy: Bool = lock.withLock {
            defer { presentPending = true }
            return presentPending
        }
        guard !busy else { return }
        DispatchQueue.main.async { [weak self] in
            onPresent(buffer)
            guard let self else { return }
            self.lock.withLock { self.presentPending = false }
        }
    }

    // MARK: Recording

    var isDeviceSource: Bool { device != nil }

    func startRecording(to url: URL, microphoneID: String?) throws -> [String] {
        let wantsDevice = device != nil
        var mic: LiveMicrophone?
        if let microphoneID {
            mic = LiveMicrophone(deviceID: microphoneID) { [weak self] sample, clock in self?.write(sample, clock: clock, role: "mic") }
        }
        let new = try DeviceMovieWriter(url: url, width: Int(LiveCompositor.canvas.width), height: Int(LiveCompositor.canvas.height),
                                        deviceAudio: wantsDevice, microphone: mic != nil, fps: 30)
        try new.start(at: CMClockGetTime(CMClockGetHostTimeClock()))
        writerQueue.sync {
            writer = new
            microphone = mic
        }
        mic?.start()
        return new.audioRoles
    }

    private func write(_ sample: CMSampleBuffer, clock: CMClock?) -> CMSampleBuffer? {
        var time = sample.presentationTimeStamp
        if let clock { time = CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock()) }
        return DeviceRecorder.moved(sample, to: time)
    }

    private func write(_ sample: CMSampleBuffer, clock: CMClock?, role: String) {
        guard let moved = write(sample, clock: clock) else { return }
        writerQueue.async { self.writer?.appendAudio(moved, role: role) }
    }

    /// Finishes the file and returns its length in seconds.
    func stopRecording() async throws -> Double {
        let (current, mic): (DeviceMovieWriter?, LiveMicrophone?) = writerQueue.sync {
            let result = (writer, microphone)
            writer = nil
            microphone = nil
            return result
        }
        mic?.stop()
        guard let current else { throw RecorderError.noFrames }
        return try await current.finish(end: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    // MARK: Tests

    /// Puts frames in directly and draws one picture.
    func renderForTest(source: CVPixelBuffer?, camera: CVPixelBuffer?) -> CVPixelBuffer? {
        lock.withLock {
            if let source {
                sourceFrame = source
                sourceGeneration = wantedGeneration
            }
            if let camera { cameraFrame = camera }
        }
        return renderQueue.sync {
            tick()
            return lastOutput
        }
    }
}

// MARK: - Trying it out

extension LiveEngine {
    private static var footprintMB: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    /// `--livetest <seconds> <picture> [--ipad] [--record <movie>]`: the live picture from real sources,
    /// with frame rate and memory. The picture of the program window is only saved for an iPad.
    @MainActor
    static func commandLine(seconds: Int, picture: String) -> Int32 {
        var code: Int32 = 1
        var done = false
        Task { @MainActor in
            defer { done = true }
            do {
                _ = NSApplication.shared
                NSApp.setActivationPolicy(.accessory)
                DeviceRecorder.allowDevices()
                print("Kamera-Berechtigung:", await AVCaptureDevice.requestAccess(for: .video))
                let arguments = CommandLine.arguments
                let engine = LiveEngine()
                let program = LiveProgramWindow()
                program.show()
                engine.onPresent = { buffer in
                    guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
                    MainActor.assumeIsolated { program.present(surface) }
                }
                var config = LiveConfig()
                config.trail = true
                if let i = arguments.firstIndex(of: "--background"), i + 1 < arguments.count {
                    engine.setBackground(url: URL(fileURLWithPath: arguments[i + 1]))
                    config.background = true
                }
                if arguments.contains("--webcamonly") { config.scene = .webcam }
                engine.setConfig(config)
                engine.start()
                engine.camera.select(deviceID: CameraRecorder.availableDevices().first?.uniqueID)
                let useDevice = arguments.contains("--ipad")
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                var problem: String?
                if useDevice {
                    var devices = DeviceRecorder.availableDevices()
                    for _ in 0..<40 where devices.isEmpty {
                        try await Task.sleep(for: .milliseconds(250))
                        devices = DeviceRecorder.availableDevices()
                    }
                    guard let device = devices.first else { print("Kein iPad"); return }
                    problem = await engine.useDevice(id: device.uniqueID, hear: false)
                } else if let display = content.displays.first {
                    let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                    problem = await engine.useScreen(filter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []), area: display.frame)
                }
                if let problem { print("Quelle:", problem) }
                var recording = false
                if let i = arguments.firstIndex(of: "--record"), i + 1 < arguments.count {
                    print("Spuren:", try engine.startRecording(to: URL(fileURLWithPath: arguments[i + 1]), microphoneID: nil))
                    recording = true
                }
                var peak = 0
                for second in 1...seconds {
                    try await Task.sleep(for: .seconds(1))
                    peak = max(peak, footprintMB)
                    if second % 5 == 0 { print(second, "s:", engine.framesPerSecond, "Bilder/s,", footprintMB, "MB") }
                }
                print("Höchstwert", peak, "MB")
                if let i = arguments.firstIndex(of: "--meme"), i + 1 < arguments.count {
                    engine.playMeme(url: URL(fileURLWithPath: arguments[i + 1]), duration: 3)
                    try await Task.sleep(for: .seconds(1))
                }
                if recording { print("Aufnahme:", try await engine.stopRecording(), "s") }
                if useDevice || arguments.contains("--webcamonly"), let number = program.windowNumber {
                    let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    if let window = fresh.windows.first(where: { Int($0.windowID) == number }) {
                        let shot = SCStreamConfiguration()
                        shot.width = Int(window.frame.width)
                        shot.height = Int(window.frame.height)
                        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: shot)
                        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: picture))
                        print("Programm-Fenster:", window.title ?? "", window.frame.size)
                    } else { print("Programm-Fenster nicht gefunden") }
                }
                program.close()
                await engine.stop()
                code = 0
            } catch {
                print("Fehler:", error.localizedDescription)
            }
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return code
    }
}
