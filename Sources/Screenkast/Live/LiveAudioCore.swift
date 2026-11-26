import AudioToolbox
import AVFoundation
import CoreAudio

/// The sample rate everything is mixed at.
enum LiveAudioFormat {
    static let sampleRate = 48_000.0
    static func gain(dB: Double) -> Float { dB <= -60 ? 0 : Float(pow(10, dB / 20)) }
}

/// Core Audio devices: lookup, names and whether they are headphones.
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

    static func defaultOutput() -> AudioObjectID? {
        let id: AudioObjectID? = value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(kAudioObjectUnknown))
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static func uid(_ device: AudioObjectID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    static func name(_ device: AudioObjectID) -> String? { string(device, kAudioObjectPropertyName) }

    static func transport(_ device: AudioObjectID) -> UInt32 {
        value(device, kAudioDevicePropertyTransportType, UInt32(0)) ?? 0
    }

    /// Bluetooth devices, the headphone jack and anything called headphones/headset. Speakers of the Mac,
    /// displays and AirPlay count as loudspeakers: the microphone hears them.
    static func isHeadphones(_ device: AudioObjectID) -> Bool {
        let kind = transport(device)
        if kind == kAudioDeviceTransportTypeBluetooth || kind == kAudioDeviceTransportTypeBluetoothLE { return true }
        if kind == kAudioDeviceTransportTypeBuiltIn {
            let source: UInt32? = value(device, kAudioDevicePropertyDataSource, UInt32(0), scope: kAudioObjectPropertyScopeOutput)
            return source == 0x6864_706E   // 'hdpn'
        }
        let lowered = (name(device) ?? "").lowercased()
        return ["kopfhörer", "headphone", "headset", "airpods", "beats", "earbuds", "buds"].contains { lowered.contains($0) }
    }

    /// Microphones that come over Bluetooth (AirPods): they switch the headphones to the dull telephone mode.
    static func isBluetoothMicrophone(uniqueID: String) -> Bool {
        guard let device = device(uid: uniqueID) else { return false }
        let kind = transport(device)
        return kind == kAudioDeviceTransportTypeBluetooth || kind == kAudioDeviceTransportTypeBluetoothLE
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return status == noErr ? result : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var text: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &text) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr, let text else { return nil }
        return text.takeRetainedValue() as String
    }

    static func list(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
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
    private var _gain: Float = 1

    init(frames: Int = 48_000) {
        capacity = frames
        buffer = .allocate(capacity: frames * 2)
        buffer.initialize(repeating: 0, count: frames * 2)
    }

    deinit { buffer.deallocate() }

    var gain: Float {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _gain }
        set { os_unfair_lock_lock(&lock); _gain = newValue; os_unfair_lock_unlock(&lock) }
    }

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
        let g = _gain
        if g > 0 {
            for i in 0..<available {
                let slot = (start + i) % capacity
                left[i] += buffer[slot * 2] * g
                right[i] += buffer[slot * 2 + 1] * g
            }
        }
        start = (start + available) % capacity
        count -= available
        if available < frames { primed = false }
    }

    /// Frames waiting (for tests).
    var waiting: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return count
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        start = 0
        count = 0
        primed = false
        os_unfair_lock_unlock(&lock)
    }
}

/// The loudest sample since the last look (for the level meters).
final class PeakMeter: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var peak: Float = 0

    func note(_ value: Float) {
        os_unfair_lock_lock(&lock)
        if value > peak { peak = value }
        os_unfair_lock_unlock(&lock)
    }

    func note(_ data: UnsafePointer<Float>, count: Int) {
        var most: Float = 0
        for i in 0..<count { most = max(most, abs(data[i])) }
        note(most)
    }

    /// Returns the peak and starts again.
    func take() -> Float {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let value = peak
        peak = 0
        return value
    }
}

/// Changes the sample rate of interleaved stereo sound by linear interpolation (good enough for
/// speech and music on their way into a meeting).
final class StereoResampler {
    private let ratio: Double
    private var position = 0.0
    private var last: (Float, Float) = (0, 0)
    private var output: [Float] = []

    init(from rate: Double) { ratio = rate / LiveAudioFormat.sampleRate }

    /// `input`: interleaved stereo; returns interleaved stereo at 48 kHz (valid until the next call).
    func convert(_ input: UnsafePointer<Float>, frames: Int) -> [Float] {
        output.removeAll(keepingCapacity: true)
        guard frames > 0 else { return output }
        func sample(_ index: Int) -> (Float, Float) {
            index < 0 ? last : (input[index * 2], input[index * 2 + 1])
        }
        // `position` counts from the last frame of the previous block (index -1).
        while position < Double(frames - 1) + 1 {
            let base = Int(floor(position)) - 1
            let t = Float(position - floor(position))
            let a = sample(base), b = sample(base + 1)
            output.append(a.0 + (b.0 - a.0) * t)
            output.append(a.1 + (b.1 - a.1) * t)
            position += ratio
        }
        position -= Double(frames)
        last = (input[(frames - 1) * 2], input[(frames - 1) * 2 + 1])
        return output
    }
}

/// One source of the mixer: its sound goes on two ways, into the meeting and into the ear, each
/// with its own volume. What comes in is measured for the level meter.
final class MixSource: @unchecked Sendable {
    let meeting = AudioFIFO()
    let ear = AudioFIFO()
    let level = PeakMeter()
    private var resampler: StereoResampler?
    private var resamplerRate = 0.0
    private let lock = NSLock()

    func setGains(meeting: Float, ear: Float) {
        self.meeting.gain = meeting
        self.ear.gain = ear
    }

    func clear() {
        meeting.clear()
        ear.clear()
    }

    func write(_ data: [UnsafePointer<Float>], frames: Int, channels: Int, interleaved: Bool) {
        if channels == 1 || !interleaved {
            for channel in data.prefix(2) { level.note(channel, count: frames) }
        } else {
            level.note(data[0], count: frames * channels)
        }
        meeting.write(data, frames: frames, channels: channels, interleaved: interleaved)
        ear.write(data, frames: frames, channels: channels, interleaved: interleaved)
    }

    /// Interleaved stereo at any rate.
    func writeStereo(_ data: UnsafePointer<Float>, frames: Int, rate: Double) {
        guard abs(rate - LiveAudioFormat.sampleRate) > 1 else {
            return write([data], frames: frames, channels: 2, interleaved: true)
        }
        let converted: [Float] = lock.withLock {
            if resampler == nil || resamplerRate != rate {
                resampler = StereoResampler(from: rate)
                resamplerRate = rate
            }
            return resampler!.convert(data, frames: frames)
        }
        converted.withUnsafeBufferPointer { write([$0.baseAddress!], frames: converted.count / 2, channels: 2, interleaved: true) }
    }

    /// The sound of a sample buffer (Float32 or Int16, as delivered by AVFoundation).
    func write(_ sample: CMSampleBuffer) {
        guard let sound = AudioSamples.interleavedStereo(sample) else { return }
        sound.data.withUnsafeBufferPointer { writeStereo($0.baseAddress!, frames: sound.data.count / 2, rate: sound.rate) }
    }
}

/// Sound of sample buffers as plain numbers.
enum AudioSamples {
    /// Interleaved stereo floats (mono copied to both sides) and the sample rate; nil for other formats.
    static func interleavedStereo(_ sample: CMSampleBuffer) -> (data: [Float], rate: Double)? {
        guard let format = sample.formatDescription?.audioStreamBasicDescription, format.mFormatID == kAudioFormatLinearPCM else { return nil }
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        let isShort = format.mFormatFlags & kAudioFormatFlagIsFloat == 0 && format.mBitsPerChannel == 16
        guard isFloat || isShort else { return nil }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0 else { return nil }
        var block: CMBlockBuffer?
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
                                                                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let list = AudioBufferList.allocate(maximumBuffers: max(1, size / MemoryLayout<AudioBuffer>.stride))
        defer { free(list.unsafeMutablePointer) }
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
                                                                      bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                                                                      blockBufferOut: &block) == noErr else { return nil }
        let channels = max(1, Int(format.mChannelsPerFrame))
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        var stereo = [Float](repeating: 0, count: frames * 2)
        for side in 0..<2 {
            let channel = min(side, channels - 1)
            if interleaved {
                guard let data = list.first?.mData else { return nil }
                for i in 0..<frames {
                    stereo[i * 2 + side] = isShort ? Float(data.assumingMemoryBound(to: Int16.self)[i * channels + channel]) / 32_768
                                                   : data.assumingMemoryBound(to: Float.self)[i * channels + channel]
                }
            } else {
                guard channel < list.count, let data = list[channel].mData else { return nil }
                for i in 0..<frames {
                    stereo[i * 2 + side] = isShort ? Float(data.assumingMemoryBound(to: Int16.self)[i]) / 32_768 : data.assumingMemoryBound(to: Float.self)[i]
                }
            }
        }
        return (stereo, format.mSampleRate)
    }
}

/// A meme's sound, decoded from its file (stereo, 48 kHz, interleaved) and repeated until it is stopped;
/// the meeting and the ear each play it at their own pace.
final class ClipSource: @unchecked Sendable {
    let level = PeakMeter()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var meetingPosition = 0
    private var earPosition = 0
    private var playing = false
    private var generation = 0
    private var meetingGain: Float = 1
    private var earGain: Float = 1
    /// Tells a recording which sound starts when (nil: none any more), at the time the meme was pressed.
    var onStart: (@Sendable ([Float]?, Int64) -> Void)?

    func setGains(meeting: Float, ear: Float) {
        lock.withLock {
            meetingGain = meeting
            earGain = ear
        }
    }

    /// Starts the sound of a file (nil: stops). Files without sound change nothing.
    func play(_ url: URL?) {
        let pressed = HostFrames.now
        let (id, report): (Int, (@Sendable ([Float]?, Int64) -> Void)?) = lock.withLock {
            generation += 1
            playing = false
            samples = []
            return (generation, onStart)
        }
        report?(nil, pressed)
        guard let url else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let decoded = await Self.decode(url), let self else { return }
            let current: Bool = self.lock.withLock {
                guard self.generation == id else { return false }
                self.samples = decoded
                self.meetingPosition = 0
                self.earPosition = 0
                self.playing = true
                return true
            }
            if current { report?(decoded, pressed) }
        }
    }

    func addMeeting(to left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) {
        add(to: left, right, frames: frames, meeting: true)
    }

    func addEar(to left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) {
        add(to: left, right, frames: frames, meeting: false)
    }

    private func add(to left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int, meeting: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard playing, samples.count >= 2 else { return }
        let total = samples.count / 2
        var position = meeting ? meetingPosition : earPosition
        let g = meeting ? meetingGain : earGain
        var most: Float = 0
        for i in 0..<frames {
            let l = samples[position * 2], r = samples[position * 2 + 1]
            most = max(most, abs(l), abs(r))
            left[i] += l * g
            right[i] += r * g
            position = (position + 1) % total
        }
        if meeting { meetingPosition = position } else { earPosition = position }
        level.note(most)
    }

    static func decode(_ url: URL) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: LiveAudioFormat.sampleRate, AVNumberOfChannelsKey: 2,
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
}

/// Plays 48 kHz stereo into exactly one device (a HAL output unit bound to it). Unlike AVAudioEngine it
/// never follows the default output of the Mac: when headphones connect, the sound stays where it is.
final class DeviceOutput: @unchecked Sendable {
    typealias Render = (_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int) -> Void

    let device: AudioObjectID
    fileprivate let render: Render
    private var unit: AudioComponentInstance?

    init(device: AudioObjectID, render: @escaping Render) throws {
        self.device = device
        self.render = render
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw RecorderError.writerFailed("Keine Tonausgabe") }
        var made: AudioComponentInstance?
        try Self.check(AudioComponentInstanceNew(component, &made), "Ausgabe")
        guard let unit = made else { throw RecorderError.writerFailed("Ausgabe") }
        self.unit = unit
        do {
            var on: UInt32 = 1, off: UInt32 = 0
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on, 4), "Ausgang")
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &off, 4), "Eingang")
            var id = device
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                                UInt32(MemoryLayout<AudioObjectID>.size)), "Gerät")
            var format = AudioStreamBasicDescription(mSampleRate: LiveAudioFormat.sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                     mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                                     mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
                                                     mBitsPerChannel: 32, mReserved: 0)
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
                                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Format")
            var slice: UInt32 = 4_096
            AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &slice, 4)
            var callback = AURenderCallbackStruct(inputProc: deviceOutputRender, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                                UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Rückruf")
            try Self.check(AudioUnitInitialize(unit), "Start")
            try Self.check(AudioOutputUnitStart(unit), "Start")
        } catch {
            AudioComponentInstanceDispose(unit)
            self.unit = nil
            throw error
        }
    }

    /// The device the unit really plays into (to make sure).
    var currentDevice: AudioObjectID? {
        guard let unit else { return nil }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr else { return nil }
        return id
    }

    func stop() {
        guard let unit else { return }
        self.unit = nil
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    deinit { stop() }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw RecorderError.writerFailed("\(step) (\(status))") }
    }
}

private func deviceOutputRender(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                                _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let data else { return noErr }
    let output = Unmanaged<DeviceOutput>.fromOpaque(refCon).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(data)
    guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
          let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
    let n = Int(frames)
    left.update(repeating: 0, count: n)
    right.update(repeating: 0, count: n)
    output.render(left, right, n)
    return noErr
}
