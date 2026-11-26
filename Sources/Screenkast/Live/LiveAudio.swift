import AppKit
import AVFoundation
import Combine
import CoreAudio

/// How loud each source is in the meeting and in the ear; kept between live sessions.
struct LiveMixSettings: Codable, Equatable {
    struct Channel: Codable, Equatable {
        var meetingOn: Bool
        /// Decibels, −40 … +10.
        var meeting: Double
        var earOn: Bool
        var ear: Double

        var meetingGain: Float { meetingOn ? LiveAudioFormat.gain(dB: meeting) : 0 }
        var earGain: Float { earOn ? LiveAudioFormat.gain(dB: ear) : 0 }
    }

    /// The own voice: never in the ear unless switched on (and only with headphones), else it echoes.
    var voice = Channel(meetingOn: true, meeting: 0, earOn: false, ear: -15)
    var device = Channel(meetingOn: true, meeting: -3, earOn: true, ear: -3)
    var memes = Channel(meetingOn: true, meeting: -6, earOn: true, ear: -6)
    /// Programs by bundle id. Only switched-on ones go into the meeting.
    var apps: [String: Channel] = [:]
    /// The voice does not go into the meeting (key M).
    var muted = false
    /// Output devices (UID) marked as headphones (true) or loudspeakers (false) against the guess.
    var headphones: [String: Bool] = [:]

    static let range: ClosedRange<Double> = -40...10
    static let newApp = Channel(meetingOn: false, meeting: -6, earOn: true, ear: 0)

    func app(_ id: String) -> Channel { apps[id] ?? Self.newApp }

    static func load() -> LiveMixSettings {
        UserDefaults.standard.data(forKey: "liveMix").flatMap { try? JSONDecoder().decode(LiveMixSettings.self, from: $0) } ?? LiveMixSettings()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "liveMix") }
    }
}

/// The sources and the two mixes. Runs on the sound threads; everything here is safe to call from anywhere.
final class LiveMixGraph: @unchecked Sendable {
    let voice = MixSource()
    let device = MixSource()
    let memes = ClipSource()
    /// What goes into the meeting, after the limiter.
    let meetingLevel = PeakMeter()
    private var lock = os_unfair_lock()
    private var apps: [MixSource] = []

    func setApps(_ sources: [MixSource]) {
        os_unfair_lock_lock(&lock)
        apps = sources
        os_unfair_lock_unlock(&lock)
    }

    /// Into the microphone "Erklärbär".
    func renderMeeting(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int) {
        voice.meeting.add(to: left, right, frames: frames)
        device.meeting.add(to: left, right, frames: frames)
        memes.addMeeting(to: left, right, frames: frames)
        os_unfair_lock_lock(&lock)
        let sources = apps
        os_unfair_lock_unlock(&lock)
        for source in sources { source.meeting.add(to: left, right, frames: frames) }
        Self.limit(left, right, frames)
        meetingLevel.note(left, count: frames)
        meetingLevel.note(right, count: frames)
    }

    /// Into the headphones (or loudspeakers) of the Mac. Programs are not in it: they play there themselves.
    func renderEar(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int) {
        voice.ear.add(to: left, right, frames: frames)
        device.ear.add(to: left, right, frames: frames)
        memes.addEar(to: left, right, frames: frames)
        Self.limit(left, right, frames)
    }

    /// Soft limit so that several sources together never clip.
    private static func limit(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int) {
        for i in 0..<frames {
            left[i] = tanhf(left[i])
            right[i] = tanhf(right[i])
        }
    }
}

/// The recording that runs (if any) and its volumes, reachable from the sound threads.
final class RecordingTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var mix: RecordingMix?
    private var device: Float = 1
    private var memes: Float = 1

    func set(_ new: RecordingMix?) { lock.withLock { mix = new } }
    func gains(device: Float, memes: Float) { lock.withLock { self.device = device; self.memes = memes } }

    func deviceSound(_ sample: CMSampleBuffer) {
        guard let (mix, gain) = lock.withLock({ mix.map { ($0, device) } }) else { return }
        mix.write(sample, gain: gain)
    }

    func clip(_ samples: [Float]?, at frame: Int64) {
        guard let (mix, gain) = lock.withLock({ mix.map { ($0, memes) } }) else { return }
        mix.clip(samples, startedAt: frame, gain: gain)
    }
}

/// The chosen microphone as a source (mono, 48 kHz).
final class LiveVoiceCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "screenkast.liveaudio.voice", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "screenkast.liveaudio.voice.session")
    private let target: MixSource
    let deviceID: String

    init?(deviceID: String, into target: MixSource) {
        self.deviceID = deviceID
        self.target = target
        super.init()
        guard let device = AVCaptureDevice(uniqueID: deviceID), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return nil }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: LiveAudioFormat.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
        sessionQueue.async { [session] in session.startRunning() }
    }

    func stop() {
        sessionQueue.async { [session] in session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        target.write(sample)
    }
}

/// Levels for the meters, refreshed a dozen times a second (an object of its own, so that only the
/// meters redraw).
@MainActor
final class LiveLevels: ObservableObject {
    @Published private(set) var voice: Float = 0
    @Published private(set) var device: Float = 0
    @Published private(set) var memes: Float = 0
    @Published private(set) var meeting: Float = 0
    @Published private(set) var apps: [String: Float] = [:]

    func update(voice v: Float, device d: Float, memes m: Float, meeting out: Float, apps a: [String: Float]) {
        func fall(_ old: Float, _ new: Float) -> Float { max(new, old * 0.75) }
        voice = fall(voice, v)
        device = fall(device, d)
        memes = fall(memes, m)
        meeting = fall(meeting, out)
        apps = a.reduce(into: [:]) { result, item in result[item.key] = fall(apps[item.key] ?? 0, item.value) }
    }
}

/// Sound of the live mode: mixes the voice, the iPad, memes and chosen programs into the microphone
/// "Erklärbär" (the meeting) and, separately, into the person's ear. Both outputs are bound to their
/// device: plugging in headphones never moves the meeting mix into them.
@MainActor
final class LiveAudio: ObservableObject {
    enum MeetingState: Equatable { case off, running, missing, failed(String) }

    struct Ear: Equatable {
        let uid: String
        let name: String
        let headphones: Bool
    }

    @Published var settings = LiveMixSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            applyGains()
            if settings.apps != oldValue.apps { syncTaps() }
        }
    }
    @Published private(set) var meetingState: MeetingState = .off
    @Published private(set) var ear: Ear?
    @Published private(set) var earProblem: String?
    /// Programs shown in the mixer: those that play sound (or did a moment ago) and those switched on.
    @Published private(set) var apps: [AudioApps.App] = []
    @Published private(set) var appProblem: String?
    let levels = LiveLevels()
    let graph = LiveMixGraph()

    /// Microphone, meeting on/off and the meeting program, as set by the live window.
    private var microphoneID: String?
    private var meetingWanted = false
    private(set) var meetingApp = ""
    private var voice: LiveVoiceCapture?
    private var meetingOut: DeviceOutput?
    private var earOut: DeviceOutput?
    private var taps: [String: AppTap] = [:]
    private var tapStarted: [String: Date] = [:]
    private var lastPlaying: [String: Date] = [:]
    private var running = false
    private var meterTimer: Timer?
    private var watchTimer: Timer?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    /// The tracks of a live recording apart from the own voice: "meeting" (the others, from the meeting
    /// program) and "system" (programs, iPad, memes). Without a known meeting program everything is "system".
    private var recording: RecordingMix?
    private var meetingRecording: RecordingMix?
    private let recordingTarget = RecordingTarget()

    var earRunning: Bool { earOut != nil }

    init() {
        let target = recordingTarget
        graph.memes.onStart = { samples, frame in target.clip(samples, at: frame) }
    }

    func start() {
        guard !running else { return }
        running = true
        applyGains()
        startEar()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.startEar() }
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        defaultListener = listener
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMeters() }
        }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watch() }
        }
        watch()
    }

    /// What the live window wants: the microphone, whether the meeting microphone runs, the meeting program.
    func configure(microphone: String?, meeting: Bool, meetingApp: String) {
        guard running else { return }
        let appChanged = meetingApp != self.meetingApp
        self.meetingApp = meetingApp
        if meeting != meetingWanted {
            meetingWanted = meeting
            if meeting { startMeeting() } else { stopMeeting() }
        }
        if microphone != microphoneID {
            microphoneID = microphone
            voice?.stop()
            voice = nil
            graph.voice.clear()
            if let microphone { voice = LiveVoiceCapture(deviceID: microphone, into: graph.voice) }
        }
        if appChanged { syncTaps() }
        refreshApps()
    }

    func stop() {
        guard running else { return }
        running = false
        meterTimer?.invalidate()
        watchTimer?.invalidate()
        meterTimer = nil
        watchTimer = nil
        if let listener = defaultListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        defaultListener = nil
        voice?.stop()
        voice = nil
        microphoneID = nil
        stopMeeting()
        meetingWanted = false
        earOut?.stop()
        earOut = nil
        graph.memes.play(nil)
        graph.voice.clear()
        graph.device.clear()
        recording = nil
        meetingRecording = nil
        recordingTarget.set(nil)
    }

    // MARK: Recording

    /// From now on the sound of the meeting goes into the recording: the others from the meeting program
    /// (without it: everything except Erklärbär), switched-on programs, iPad and memes as in the meeting.
    func startRecording(at start: CMTime, separateMeeting: Bool, deliver: @escaping @Sendable (CMSampleBuffer, String) -> Void) {
        let mix = RecordingMix(start: start) { deliver($0, "system") }
        recording = mix
        meetingRecording = separateMeeting ? RecordingMix(start: start) { deliver($0, "meeting") } : nil
        recordingTarget.set(mix)
        syncTaps()
    }

    /// Whether a recording started now gets its own track for the others in the meeting.
    var recordsMeetingSeparately: Bool { !meetingApp.isEmpty }

    /// Waits for sound that is still on its way, writes everything up to `end` and stops taking it up.
    func finishRecording(at end: CMTime) async {
        guard let mix = recording else { return }
        try? await Task.sleep(for: .milliseconds(Int(RecordingMix.delay * 1_000 / Int64(LiveAudioFormat.sampleRate)) + 60))
        mix.finish(at: end)
        meetingRecording?.finish(at: end)
        recording = nil
        meetingRecording = nil
        recordingTarget.set(nil)
        syncTaps()
    }

    /// Which taps feed the recording, at which volume.
    private func wireRecording() {
        let global = taps[AppTap.everything] != nil
        for (id, tap) in taps {
            guard let mix = recording else {
                tap.onTimed = nil
                continue
            }
            let gain: Float
            if id == AppTap.everything || id == meetingApp {
                gain = 1
            } else {
                // With the tap of everything the programs are in it already.
                gain = global ? 0 : settings.app(id).meetingGain
            }
            guard gain > 0 else {
                tap.onTimed = nil
                continue
            }
            // The others in the meeting on their own track, if there is one.
            let target = id == meetingApp ? meetingRecording ?? mix : mix
            // Runs on the tap's queue, not on the main thread.
            let feed: @Sendable (UnsafePointer<Float>, Int, Int64) -> Void = { data, frames, start in
                target.write(data, frames: frames, at: start, gain: gain)
            }
            tap.onTimed = feed
        }
    }

    // MARK: Sources from the live engine

    nonisolated func playClip(_ url: URL?) { graph.memes.play(url) }
    /// The iPad's sound with its time on the host clock.
    nonisolated func takeDeviceSound(_ sample: CMSampleBuffer) {
        graph.device.write(sample)
        recordingTarget.deviceSound(sample)
    }

    func toggleMute() { settings.muted.toggle() }

    // MARK: Meeting

    private func startMeeting() {
        meetingOut?.stop()
        meetingOut = nil
        guard let feed = AudioDevices.device(uid: VirtualMicrophoneIDs.feedUID) else {
            meetingState = .missing
            return
        }
        do {
            let graph = graph
            meetingOut = try DeviceOutput(device: feed) { graph.renderMeeting($0, $1, $2) }
            meetingState = .running
        } catch {
            meetingState = .failed("Das Mikrofon „\(VirtualCameraIDs.cameraName)“ lässt sich nicht beliefern: \(error.localizedDescription)")
        }
        syncTaps()
    }

    private func stopMeeting() {
        meetingOut?.stop()
        meetingOut = nil
        meetingState = .off
        syncTaps()
    }

    // MARK: Ear

    /// Plays into the current output of the Mac; follows it when it changes (that is wanted here).
    private func startEar() {
        guard running else { return }
        guard let device = AudioDevices.defaultOutput(), let uid = AudioDevices.uid(device), !VirtualMicrophoneIDs.isOwnMicrophone(uid) else {
            earOut?.stop()
            earOut = nil
            ear = nil
            return
        }
        let headphones = settings.headphones[uid] ?? AudioDevices.isHeadphones(device)
        ear = Ear(uid: uid, name: AudioDevices.name(device) ?? uid, headphones: headphones)
        applyGains()
        if let earOut, earOut.device == device, earOut.currentDevice == device { return }
        earOut?.stop()
        earOut = nil
        graph.voice.ear.clear()
        graph.device.ear.clear()
        do {
            let graph = graph
            earOut = try DeviceOutput(device: device) { graph.renderEar($0, $1, $2) }
            earProblem = nil
        } catch {
            earProblem = "Der Ton fürs Ohr lässt sich nicht abspielen: \(error.localizedDescription)"
        }
    }

    /// Marks the current output as headphones or loudspeakers (when the guess is wrong).
    func setHeadphones(_ on: Bool) {
        guard let ear else { return }
        settings.headphones[ear.uid] = on
        self.ear = Ear(uid: ear.uid, name: ear.name, headphones: on)
        applyGains()
    }

    /// The own voice in the ear only with headphones: from loudspeakers the microphone would take it up again.
    var voiceInEarAllowed: Bool { ear?.headphones == true }

    private func applyGains() {
        var voice = settings.voice
        if settings.muted { voice.meetingOn = false }
        if !voiceInEarAllowed { voice.earOn = false }
        graph.voice.setGains(meeting: voice.meetingGain, ear: voice.earGain)
        graph.device.setGains(meeting: settings.device.meetingGain, ear: settings.device.earGain)
        graph.memes.setGains(meeting: settings.memes.meetingGain, ear: settings.memes.earGain)
        for (id, tap) in taps {
            tap.source.setGains(meeting: id == meetingApp || id == AppTap.everything ? 0 : settings.app(id).meetingGain, ear: 0)
        }
        recordingTarget.gains(device: settings.device.meetingGain, memes: settings.memes.meetingGain)
        wireRecording()
    }

    // MARK: Programs

    /// Takes up exactly the switched-on programs (never the meeting program), only while the meeting runs.
    private func syncTaps() {
        guard running else { return }
        let current = AudioApps.current()
        var wanted: [String: [AudioObjectID]] = [:]
        if meetingOut != nil || recording != nil {
            for app in current where app.id != meetingApp && settings.app(app.id).meetingOn {
                wanted[app.id] = app.processes
            }
        }
        if recording != nil {
            // The others in the meeting; without a known meeting program everything except Erklärbär.
            if !meetingApp.isEmpty, let meeting = current.first(where: { $0.id == meetingApp }) {
                wanted[meetingApp] = meeting.processes
            } else if meetingApp.isEmpty {
                wanted[AppTap.everything] = AppTap.ownProcesses()
            }
        }
        for (id, tap) in taps where wanted[id] == nil {
            tap.stop()
            taps[id] = nil
            tapStarted[id] = nil
        }
        var failed: [String] = []
        for (id, processes) in wanted {
            do {
                if let tap = taps[id] {
                    if id != AppTap.everything { try tap.update(processes: processes) }
                } else {
                    taps[id] = try AppTap(appID: id, target: id == AppTap.everything ? .allExcept(processes) : .processes(processes))
                    tapStarted[id] = Date()
                }
            } catch {
                taps[id]?.stop()
                taps[id] = nil
                failed.append(current.first { $0.id == id }?.name ?? (id == AppTap.everything ? "anderen Programmen" : id))
            }
        }
        graph.setApps(taps.values.map(\.source))
        applyGains()
        appProblem = failed.isEmpty ? nil : "Der Ton von \(failed.joined(separator: ", ")) lässt sich nicht abgreifen."
    }

    private func refreshApps() {
        let now = Date()
        let current = AudioApps.current()
        for app in current where app.playing { lastPlaying[app.id] = now }
        let own = Bundle.main.bundleIdentifier
        let shown = current.filter { app in
            app.id != own && (app.playing || settings.apps[app.id]?.meetingOn == true || app.id == meetingApp
                || lastPlaying[app.id].map { now.timeIntervalSince($0) < 30 } == true)
        }
        .sorted { a, b in
            if (a.id == meetingApp) != (b.id == meetingApp) { return a.id == meetingApp }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        if shown != apps { apps = shown }
        // Helpers come and go (a browser opens a tab): the taps follow.
        let tapped = Dictionary(uniqueKeysWithValues: current.map { ($0.id, Set($0.processes)) })
        if taps.contains(where: { id, tap in tapped[id].map { $0 != Set(tap.processes) } ?? false }) { syncTaps() }
        // macOS delivers only silence while the permission for system audio is missing.
        let silent = taps.filter { id, tap in
            !tap.heardAnything && (tapStarted[id].map { now.timeIntervalSince($0) > 3 } ?? false) && current.contains { $0.id == id && $0.playing }
        }
        if !silent.isEmpty {
            appProblem = "macOS gibt den Ton der Programme nicht heraus. Bitte Erklärbär erlauben: Systemeinstellungen › Datenschutz & Sicherheit › Bildschirm- & Systemaudioaufnahme."
        } else if appProblem?.hasPrefix("macOS gibt") == true {
            appProblem = nil
        }
    }

    /// Once a second: is the meeting mix still where it belongs, did the output change, which programs play?
    private func watch() {
        guard running else { return }
        if meetingWanted {
            let feed = AudioDevices.device(uid: VirtualMicrophoneIDs.feedUID)
            if feed == nil || meetingOut == nil || meetingOut?.device != feed || meetingOut?.currentDevice != feed {
                startMeeting()
            }
        }
        if let earOut, let device = AudioDevices.defaultOutput(), earOut.device != device || earOut.currentDevice != device {
            startEar()
        } else if earOut == nil {
            startEar()
        }
        refreshApps()
    }

    #if DEBUG
    /// Pictures of the mixer in a state (debug builds only).
    func pretend(ear: Ear?, apps: [AudioApps.App], meetingApp: String, meeting: MeetingState) {
        self.ear = ear
        self.apps = apps
        self.meetingApp = meetingApp
        meetingState = meeting
        levels.update(voice: 0.5, device: 0.2, memes: 0, meeting: 0.45, apps: [apps.last?.id ?? "": 0.3])
    }
    #endif

    private func updateMeters() {
        var appLevels: [String: Float] = [:]
        for (id, tap) in taps { appLevels[id] = tap.source.level.take() }
        levels.update(voice: graph.voice.level.take(), device: graph.device.level.take(), memes: graph.memes.level.take(),
                      meeting: graph.meetingLevel.take(), apps: appLevels)
    }
}
