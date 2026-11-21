import AppKit
import AVFoundation
import CoreAudio
import ScreenCaptureKit

/// What the app and its audio driver (VirtualCamera/Audio) agree on.
enum VirtualMicrophoneIDs {
    /// The input device meeting programs record from.
    static let micUID = "ErklaerbaerMikrofon"
    /// The hidden output device Erklärbär plays its mix into.
    static let feedUID = "ErklaerbaerZuspielung"
    static let driverName = "ErklaerbaerAudio.driver"
    static let installed = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/ErklaerbaerAudio.driver")
    static let sampleRate = 48_000.0

    static func isOwnMicrophone(_ uniqueID: String) -> Bool { uniqueID == micUID || uniqueID == feedUID }
}

/// The microphone "Erklärbär" for meetings: an audio driver inside the app that is copied to
/// /Library/Audio/Plug-Ins/HAL once (with the administrator password). Then Erklärbär sends the chosen
/// microphone and, if wanted, the sound of the Mac through it.
@MainActor
final class VirtualMicrophone: ObservableObject {
    static let shared = VirtualMicrophone()

    enum Status: Equatable {
        case checking
        case unavailable(String)
        case notInstalled
        /// Installed, but an older driver than the one inside the app.
        case outdated
        case installing
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .checking
    @Published var sending: Bool = UserDefaults.standard.object(forKey: "virtualMicOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sending, forKey: "virtualMicOn") }
    }
    /// Also send the sound of the Mac (all programs except the meeting program).
    @Published var systemAudio: Bool = UserDefaults.standard.object(forKey: "virtualMicSystem") as? Bool ?? true {
        didSet { UserDefaults.standard.set(systemAudio, forKey: "virtualMicSystem") }
    }
    /// Bundle id of the meeting program whose sound is never sent back into the meeting ("" = none).
    @Published var meetingApp: String = UserDefaults.standard.string(forKey: "virtualMicMeetingApp") ?? "" {
        didSet { UserDefaults.standard.set(meetingApp, forKey: "virtualMicMeetingApp") }
    }

    static var bundledDriver: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Audio/\(VirtualMicrophoneIDs.driverName)") }

    private static func version(_ driver: URL) -> String? {
        (NSDictionary(contentsOf: driver.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleVersion"] as? String
    }

    var isBundled: Bool { FileManager.default.fileExists(atPath: Self.bundledDriver.path) }

    func refresh() {
        guard status != .installing else { return }
        guard isBundled else {
            status = .unavailable("Diese Ausgabe von Erklärbär enthält kein Mikrofon für Meetings.")
            return
        }
        guard let installed = Self.version(VirtualMicrophoneIDs.installed) else {
            status = .notInstalled
            return
        }
        if installed != Self.version(Self.bundledDriver) {
            status = .outdated
        } else if AudioDevices.device(uid: VirtualMicrophoneIDs.feedUID) == nil {
            status = .failed("Das Mikrofon ist eingerichtet, meldet sich aber nicht. Ein Neustart des Macs hilft meist.")
        } else {
            status = .ready
        }
        if meetingApp.isEmpty { meetingApp = Self.guessMeetingApp() ?? "" }
    }

    private static let shell = "/Library/Audio/Plug-Ins/HAL"
    /// The sound system loads drivers only when it starts.
    private static let restartAudio = "(/bin/launchctl kickstart -k system/com.apple.audio.coreaudiod || /usr/bin/killall coreaudiod)"

    /// Copies the driver (macOS asks for the administrator password) and restarts the sound system.
    func install() {
        guard isBundled else { return refresh() }
        status = .installing
        let source = Self.bundledDriver.path
        let target = VirtualMicrophoneIDs.installed.path
        let command = "/bin/mkdir -p \(Self.shell) && /bin/rm -rf \(target) && /usr/bin/ditto \" & quoted form of \"\(Self.escaped(source))\" & \" \(target) && /usr/sbin/chown -R root:wheel \(target) && \(Self.restartAudio)"
        runAsAdministrator(command, prompt: "Erklärbär möchte das Mikrofon „Erklärbär“ für Meetings einrichten.") { [weak self] error in
            guard let self else { return }
            if let error {
                self.status = .failed(error)
                return
            }
            Task { @MainActor in
                // The sound system needs a moment until the new devices are there.
                for _ in 0..<40 where AudioDevices.device(uid: VirtualMicrophoneIDs.feedUID) == nil {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                self.status = .checking
                self.refresh()
            }
        }
    }

    func remove() {
        let target = VirtualMicrophoneIDs.installed.path
        runAsAdministrator("/bin/rm -rf \(target) && \(Self.restartAudio)",
                           prompt: "Erklärbär möchte das Mikrofon „Erklärbär“ entfernen.") { [weak self] error in
            self?.status = error.map { .failed($0) } ?? .notInstalled
        }
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Runs the shell command with administrator rights (macOS shows its password dialog).
    private func runAsAdministrator(_ command: String, prompt: String, done: @escaping @MainActor (String?) -> Void) {
        let source = "do shell script \"\(command)\" with prompt \"\(Self.escaped(prompt))\" with administrator privileges"
        // Give SwiftUI a moment to show the spinner before the dialog blocks the main thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            var info: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&info)
            guard let info else { return done(nil) }
            let code = info[NSAppleScript.errorNumber] as? Int ?? 0
            done(code == -128 ? "Abgebrochen." : "Das ging nicht: \(info[NSAppleScript.errorMessage] as? String ?? "Fehler \(code)")")
        }
    }

    #if DEBUG
    /// Pictures of the control window in a state (debug builds only).
    func pretend(_ new: Status) { status = new }
    #endif

    // MARK: Meeting program

    /// Programs whose sound must not go back into the meeting, most likely first.
    static let meetingApps = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp",
        "com.apple.FaceTime", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.skype.skype",
        "com.brave.Browser", "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static func guessMeetingApp() -> String? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return meetingApps.first { running.contains($0) }
    }

    /// Programs to choose from: the running ones with a window.
    static func runningApps() -> [(id: String, name: String)] {
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != own }
            .map { ($0.bundleIdentifier!, $0.localizedName ?? $0.bundleIdentifier!) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Core Audio devices by their UID.
enum AudioDevices {
    static func device(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var name = uid as CFString
        let status = withUnsafeMutablePointer(to: &name) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }
}

/// Collects stereo sound from one source and hands it out at the pace of the output; keeps a small,
/// steady reserve because the source and the output run on slightly different clocks.
final class AudioFIFO: @unchecked Sendable {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private var start = 0
    private var count = 0
    private var primed = false
    private var lock = os_unfair_lock()
    /// Reserve in frames (50 ms) and the most that may pile up (150 ms) before old sound is dropped.
    private let target = 2_400
    private let most = 7_200
    var gain: Float = 1

    init(frames: Int = 48_000) {
        capacity = frames
        buffer = .allocate(capacity: frames * 2)
        buffer.initialize(repeating: 0, count: frames * 2)
    }

    deinit { buffer.deallocate() }

    /// `channels` 1 (mono, copied to both sides) or 2; `interleaved` false: one block per channel.
    func write(_ data: [UnsafePointer<Float>], frames: Int, channels: Int, interleaved: Bool) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        for i in 0..<frames {
            if count == capacity { start = (start + 1) % capacity; count -= 1 }
            let slot = (start + count) % capacity
            let left: Float, right: Float
            if channels == 1 {
                left = data[0][i]
                right = left
            } else if interleaved {
                left = data[0][i * channels]
                right = data[0][i * channels + 1]
            } else {
                left = data[0][i]
                right = data[1][i]
            }
            buffer[slot * 2] = left
            buffer[slot * 2 + 1] = right
            count += 1
        }
        if count > most {
            let drop = count - target
            start = (start + drop) % capacity
            count = target
        }
    }

    /// Adds `frames` frames to the two channel blocks (silence while too little is there).
    func add(to left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if !primed {
            guard count >= target else { return }
            primed = true
        }
        let available = min(frames, count)
        let g = gain
        for i in 0..<available {
            let slot = (start + i) % capacity
            left[i] += buffer[slot * 2] * g
            right[i] += buffer[slot * 2 + 1] * g
        }
        start = (start + available) % capacity
        count -= available
        if available < frames { primed = false }
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        start = 0
        count = 0
        primed = false
        os_unfair_lock_unlock(&lock)
    }

    /// Copies the sound of a sample buffer (Float32 or Int16, as delivered by AVFoundation or ScreenCaptureKit).
    func write(_ sample: CMSampleBuffer) {
        guard let format = sample.formatDescription?.audioStreamBasicDescription, format.mFormatID == kAudioFormatLinearPCM else { return }
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        let isShort = format.mFormatFlags & kAudioFormatFlagIsFloat == 0 && format.mBitsPerChannel == 16
        guard isFloat || isShort else { return }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0 else { return }
        var block: CMBlockBuffer?
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
                                                                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let list = AudioBufferList.allocate(maximumBuffers: max(1, size / MemoryLayout<AudioBuffer>.stride))
        defer { free(list.unsafeMutablePointer) }
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
                                                                      bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                                                                      blockBufferOut: &block) == noErr else { return }
        let channels = Int(format.mChannelsPerFrame)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        if isShort {
            // Whole numbers (the iPad): as floating point, interleaved.
            guard interleaved, let data = list.first?.mData else { return }
            let shorts = data.assumingMemoryBound(to: Int16.self)
            var floats = [Float](repeating: 0, count: frames * channels)
            for i in 0..<(frames * channels) { floats[i] = Float(shorts[i]) / 32_768 }
            floats.withUnsafeBufferPointer { write([$0.baseAddress!], frames: frames, channels: channels, interleaved: true) }
            return
        }
        let pointers = list.compactMap { $0.mData.map { UnsafePointer($0.assumingMemoryBound(to: Float.self)) } }
        guard !pointers.isEmpty else { return }
        if interleaved {
            write([pointers[0]], frames: frames, channels: channels, interleaved: true)
        } else {
            write(pointers.count >= 2 ? [pointers[0], pointers[1]] : [pointers[0]], frames: frames, channels: min(2, pointers.count), interleaved: false)
        }
    }
}

/// Plays the mix of microphone and sound of the Mac into the hidden device of the driver; meeting
/// programs hear it from the microphone "Erklärbär".
final class VirtualMicFeed: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum State: Equatable { case off, running, missing, failed(String) }

    var onState: ((State) -> Void)?
    /// The chosen microphone.
    let voice = AudioFIFO()
    /// Other programs (never Erklärbär itself: what it plays into the microphone would come back endlessly).
    let sound = AudioFIFO()
    /// The iPad's sound, straight from the live source.
    let device = AudioFIFO()
    /// A meme's sound, decoded from its file (stereo, 48 kHz, interleaved), repeated until it ends.
    private let clipLock = NSLock()
    private var clip: (samples: [Float], position: Int)?
    private var clipID = 0
    /// Sound of the Mac (other programs, iPad, memes) goes along.
    private var mixSound = false

    // Changed only by the chain of reconfigurations, one after the other.
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let captureQueue = DispatchQueue(label: "screenkast.virtualmic.capture", qos: .userInteractive)
    private var micSession: AVCaptureSession?
    private var systemStream: SCStream?
    private var current: (mic: String?, system: Bool, exclude: String)?
    private let chainLock = NSLock()
    private var chain: Task<Void, Never>?

    /// Sets what is sent (`on` false: nothing, everything stops). Changes run one after the other.
    func apply(mic: String?, system: Bool, exclude: String, on: Bool) {
        enqueue { await $0.reconfigure(on ? (mic, system, exclude) : nil) }
    }

    private func enqueue(_ step: @escaping @Sendable (VirtualMicFeed) async -> Void) {
        chainLock.withLock {
            let previous = chain
            chain = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                await step(self)
            }
        }
    }

    /// Waits until everything is stopped (when live mode ends).
    func stopNow() async {
        apply(mic: nil, system: false, exclude: "", on: false)
        await chainLock.withLock({ chain })?.value
    }

    private func reconfigure(_ wanted: (mic: String?, system: Bool, exclude: String)?) async {
        guard let wanted else {
            await stopAll()
            onState?(.off)
            current = nil
            return
        }
        if !engine.isRunning {
            do {
                try startEngine()
            } catch {
                onState?(AudioDevices.device(uid: VirtualMicrophoneIDs.feedUID) == nil ? .missing : .failed(error.localizedDescription))
                return
            }
        }
        if current?.mic != wanted.mic { startMicrophone(wanted.mic) }
        if current?.system != wanted.system || current?.exclude != wanted.exclude {
            await startSystemAudio(wanted.system, exclude: wanted.exclude)
        }
        current = wanted
        onState?(.running)
    }

    private func startEngine() throws {
        guard let feedDevice = AudioDevices.device(uid: VirtualMicrophoneIDs.feedUID) else { throw RecorderError.writerFailed("Zuspielung fehlt") }
        guard let unit = engine.outputNode.audioUnit else { throw RecorderError.writerFailed("Ausgabe fehlt") }
        var id = feedDevice
        let set = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard set == noErr else { throw RecorderError.writerFailed("Gerät \(set)") }
        if sourceNode == nil {
            let format = AVAudioFormat(standardFormatWithSampleRate: VirtualMicrophoneIDs.sampleRate, channels: 2)!
            let voice = voice, sound = sound, ipad = self.device
            let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                guard buffers.count >= 2, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                      let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                let n = Int(frameCount)
                l.update(repeating: 0, count: n)
                r.update(repeating: 0, count: n)
                voice.add(to: l, r, frames: n)
                sound.add(to: l, r, frames: n)
                ipad.add(to: l, r, frames: n)
                self?.addClip(to: l, r, frames: n)
                // Soft limit so that voice and sound together never clip.
                for i in 0..<n {
                    l[i] = tanhf(l[i])
                    r[i] = tanhf(r[i])
                }
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            sourceNode = node
        }
        engine.prepare()
        try engine.start()
    }

    private func addClip(to left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) {
        clipLock.lock()
        defer { clipLock.unlock() }
        guard mixSound, var playing = clip, playing.samples.count >= 2 else { return }
        let total = playing.samples.count / 2
        for i in 0..<frames {
            left[i] += playing.samples[playing.position * 2]
            right[i] += playing.samples[playing.position * 2 + 1]
            playing.position = (playing.position + 1) % total
        }
        clip = playing
    }

    /// Starts the sound of a meme (nil: stops it). Memes without sound change nothing.
    func playClip(_ url: URL?) {
        let id: Int = clipLock.withLock {
            clipID += 1
            clip = nil
            return clipID
        }
        guard let url else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let samples = await Self.decode(url) else { return }
            guard let self else { return }
            self.clipLock.withLock { if self.clipID == id { self.clip = (samples, 0) } }
        }
    }

    /// The iPad's sound (any queue).
    func takeDeviceSound(_ sample: CMSampleBuffer) {
        guard clipLock.withLock({ mixSound }) else { return }
        device.write(sample)
    }

    private static func decode(_ url: URL) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: VirtualMicrophoneIDs.sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let data = buffer.dataBuffer, let bytes = try? data.dataBytes() else { continue }
            bytes.withUnsafeBytes { samples += $0.bindMemory(to: Float.self) }
        }
        return samples.isEmpty ? nil : samples
    }

    private func startMicrophone(_ id: String?) {
        micSession?.stopRunning()
        micSession = nil
        voice.clear()
        guard let id, let device = AVCaptureDevice(uniqueID: id), let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: VirtualMicrophoneIDs.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        session.startRunning()
        micSession = session
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        voice.write(sample)
    }

    /// The sound of all programs except the meeting program (its sound would come back as an echo) and
    /// except Erklärbär: what Erklärbär plays into the microphone would be taken up again and go round
    /// endlessly. Memes and the iPad are mixed in directly instead.
    private func startSystemAudio(_ on: Bool, exclude: String) async {
        if let old = systemStream { try? await old.stopCapture() }
        systemStream = nil
        sound.clear()
        device.clear()
        clipLock.withLock { mixSound = on }
        guard on, let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
              let display = content.displays.first else { return }
        let own = Bundle.main.bundleIdentifier ?? VirtualCameraIDs.appSigningID
        let excluded = content.applications.filter { $0.bundleIdentifier == own || (!exclude.isEmpty && $0.bundleIdentifier == exclude) }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(VirtualMicrophoneIDs.sampleRate)
        config.channelCount = 2
        // The picture is not needed: as small and rare as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
            systemStream = stream
        } catch {
            onState?(.failed("Der Systemton lässt sich nicht aufnehmen: \(error.localizedDescription)"))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sample.isValid else { return }
        sound.write(sample)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        enqueue { feed in
            guard feed.systemStream === stream else { return }
            feed.systemStream = nil
            feed.current?.system = false
            feed.onState?(.failed("Der Systemton wird nicht mehr aufgenommen (\(error.localizedDescription))."))
        }
    }

    private func stopAll() async {
        micSession?.stopRunning()
        micSession = nil
        if let stream = systemStream { try? await stream.stopCapture() }
        systemStream = nil
        if engine.isRunning { engine.stop() }
        voice.clear()
        sound.clear()
        device.clear()
        clipLock.withLock {
            mixSound = false
            clip = nil
        }
    }
}
