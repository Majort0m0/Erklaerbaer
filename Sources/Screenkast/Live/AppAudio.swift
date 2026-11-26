import AppKit
import CoreAudio

/// Programs that play sound, as Core Audio sees them. Helpers count for the program they belong to:
/// browsers play from helper processes (Brave, Chrome: "… Helper"; Safari and other WebKit programs:
/// com.apple.WebKit.GPU), so taking the program alone would miss its sound.
enum AudioApps {
    struct App: Equatable, Identifiable {
        /// Bundle id of the program (not of the helper).
        let id: String
        let name: String
        /// Core Audio process objects of the program and its helpers.
        var processes: [AudioObjectID]
        /// Plays sound right now.
        var playing: Bool
    }

    /// All programs that have sound processes, each once.
    static func current() -> [App] {
        let own = Bundle.main.bundleIdentifier ?? VirtualCameraIDs.appSigningID
        var apps: [String: App] = [:]
        var order: [String] = []
        for process in AudioDevices.list(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            guard let pid: pid_t = AudioDevices.value(process, kAudioProcessPropertyPID, pid_t(0)), pid > 0 else { continue }
            let owner = responsible(for: pid)
            // Programs only (with a window or a menu bar item), not background services of macOS.
            guard let running = NSRunningApplication(processIdentifier: owner) ?? NSRunningApplication(processIdentifier: pid),
                  running.activationPolicy != .prohibited, let id = running.bundleIdentifier, !id.isEmpty else { continue }
            // Erklärbär itself never: what it plays into the meeting would come back endlessly.
            if id == own || id.hasPrefix("com.apple.") && running.activationPolicy != .regular { continue }
            let playing = (AudioDevices.value(process, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0
            if var app = apps[id] {
                app.processes.append(process)
                app.playing = app.playing || playing
                apps[id] = app
            } else {
                apps[id] = App(id: id, name: running.localizedName ?? id, processes: [process], playing: playing)
                order.append(id)
            }
        }
        return order.compactMap { apps[$0] }
    }

    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    private static let responsibleFunction: Responsible? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Responsible.self)
    }()

    /// The program a helper process works for (the process itself if it is a program).
    static func responsible(for pid: pid_t) -> pid_t {
        guard let function = responsibleFunction else { return pid }
        let owner = function(pid)
        return owner > 0 ? owner : pid
    }

    static func icon(_ id: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

/// Takes up the sound of one program (with its helpers) through a Core Audio tap, without changing what
/// the program plays: the person keeps hearing it as before. Or, for recordings without a known meeting
/// program, the sound of all programs except Erklärbär.
final class AppTap: @unchecked Sendable {
    enum Target {
        case processes([AudioObjectID])
        case allExcept([AudioObjectID])
    }

    /// Id for "everything except Erklärbär".
    static let everything = "*"

    let appID: String
    let source = MixSource()
    private(set) var processes: [AudioObjectID]
    private let excluding: Bool
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let queue: DispatchQueue
    private var rate = LiveAudioFormat.sampleRate
    private var channels = 2
    private var interleaved = true
    private var resampler: StereoResampler?
    private let lock = NSLock()
    private var timed: (@Sendable (UnsafePointer<Float>, Int, Int64) -> Void)?
    /// Something arrived (macOS delivers silence while the permission is missing).
    private(set) var heardAnything = false

    var formatDescription: String { "\(Int(rate)) Hz, \(channels) Kanäle, \(interleaved ? "verschränkt" : "getrennt")" }

    /// Also hands out the sound with its time (interleaved stereo at 48 kHz, first frame on the host clock), for recordings.
    var onTimed: (@Sendable (UnsafePointer<Float>, Int, Int64) -> Void)? {
        get { lock.withLock { timed } }
        set { lock.withLock { timed = newValue } }
    }

    init(appID: String, target: Target) throws {
        self.appID = appID
        switch target {
        case .processes(let list):
            processes = list
            excluding = false
        case .allExcept(let list):
            processes = list
            excluding = true
        }
        queue = DispatchQueue(label: "screenkast.apptap.\(appID)", qos: .userInteractive)
        do {
            try start()
        } catch {
            stop()
            throw error
        }
    }

    convenience init(appID: String, processes: [AudioObjectID]) throws {
        try self.init(appID: appID, target: .processes(processes))
    }

    /// The Core Audio objects of Erklärbär's own process.
    static func ownProcesses() -> [AudioObjectID] {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return object == kAudioObjectUnknown ? [] : [object]
    }

    private func start() throws {
        let description = excluding ? CATapDescription(stereoGlobalTapButExcludeProcesses: processes) : CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Erklärbär \(appID)"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), "Tap")
        if let format: AudioStreamBasicDescription = AudioDevices.value(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription()) {
            rate = format.mSampleRate > 0 ? format.mSampleRate : LiveAudioFormat.sampleRate
            channels = max(1, Int(format.mChannelsPerFrame))
            interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        }
        resampler = abs(rate - LiveAudioFormat.sampleRate) > 1 ? StereoResampler(from: rate) : nil
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Erklärbär \(appID)",
            kAudioAggregateDeviceUIDKey: "Erklaerbaer-Tap-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate), "Gerät")
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { [weak self] _, input, inputTime, _, _ in
            self?.receive(input, at: inputTime.pointee)
        }, "Rückruf")
        try check(AudioDeviceStart(aggregate, proc), "Start")
    }

    /// On the tap's queue: the sound as interleaved stereo at 48 kHz, into the mixer and, with its time, to a recording.
    private func receive(_ input: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData else { return }
        let floats = data.assumingMemoryBound(to: Float.self)
        var stereo: [Float]
        if interleaved {
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let frames = count / channels
            guard frames > 0 else { return }
            stereo = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                stereo[i * 2] = floats[i * channels]
                stereo[i * 2 + 1] = floats[i * channels + min(1, channels - 1)]
            }
        } else {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return }
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? floats : floats
            stereo = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                stereo[i * 2] = floats[i]
                stereo[i * 2 + 1] = right[i]
            }
        }
        if !heardAnything, stereo.contains(where: { $0 != 0 }) { heardAnything = true }
        if let resampler {
            stereo.withUnsafeBufferPointer { stereo = resampler.convert($0.baseAddress!, frames: stereo.count / 2) }
        }
        let frames = stereo.count / 2
        guard frames > 0 else { return }
        let start = time.mFlags.contains(.hostTimeValid) ? HostFrames.frame(hostTime: time.mHostTime) : HostFrames.now - Int64(frames)
        stereo.withUnsafeBufferPointer { pointer in
            source.write([pointer.baseAddress!], frames: frames, channels: 2, interleaved: true)
            onTimed?(pointer.baseAddress!, frames, start)
        }
    }

    /// The program started or ended helpers: the tap takes up the new set.
    func update(processes new: [AudioObjectID]) throws {
        guard Set(new) != Set(processes) else { return }
        stop()
        processes = new
        try start()
    }

    func stop() {
        if aggregate != kAudioObjectUnknown {
            if let proc {
                AudioDeviceStop(aggregate, proc)
                AudioDeviceDestroyIOProcID(aggregate, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        proc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
        source.clear()
    }

    deinit { stop() }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw RecorderError.writerFailed("\(step) (\(status))") }
    }
}
