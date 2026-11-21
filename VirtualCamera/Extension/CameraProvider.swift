import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import os

let log = Logger(subsystem: VirtualCameraIDs.extensionID, category: "Kamera")

/// Announces the one camera of this extension.
final class CameraProvider: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var camera: CameraDevice!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        camera = CameraDevice()
        do {
            try provider.addDevice(camera.device)
        } catch {
            fatalError("Die Kamera ließ sich nicht anmelden: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {
        camera.clientLeft(client)
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = VirtualCameraIDs.manufacturer }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

/// The camera: what Erklärbär puts into the input stream comes out of the picture stream that meeting
/// programs read. Without a fresh picture from Erklärbär it shows a note instead.
final class CameraDevice: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var picture: CameraStream!
    private var input: CameraStream!
    let frameDuration = CMTime(value: 1, timescale: VirtualCameraIDs.framesPerSecond)

    private let queue = DispatchQueue(label: "erklaerbaer.camera", qos: .userInteractive)
    // queue only
    private var showing = false
    private var feeder: CMIOExtensionClient?
    private var lastFed: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var note: (buffer: CVPixelBuffer, format: CMVideoFormatDescription)?

    override init() {
        super.init()
        device = CMIOExtensionDevice(localizedName: VirtualCameraIDs.cameraName, deviceID: VirtualCameraIDs.device, legacyDeviceID: nil, source: self)
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: VirtualCameraIDs.width, height: VirtualCameraIDs.height, extensions: nil, formatDescriptionOut: &description)
        let format = CMIOExtensionStreamFormat(formatDescription: description!, maxFrameDuration: frameDuration, minFrameDuration: frameDuration, validFrameDurations: nil)
        picture = CameraStream(name: "Erklärbär", id: VirtualCameraIDs.sourceStream, direction: .source, format: format, owner: self)
        input = CameraStream(name: "Erklärbär Eingang", id: VirtualCameraIDs.sinkStream, direction: .sink, format: format, owner: self)
        do {
            try device.addStream(picture.stream)
            try device.addStream(input.stream)
        } catch {
            fatalError("Die Kamera-Streams ließen sich nicht anlegen: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { result.model = VirtualCameraIDs.model }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    static func hostNanoseconds() -> UInt64 {
        UInt64(max(0, CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), timescale: 1_000_000_000, method: .default).value))
    }

    // MARK: Picture stream (meeting programs)

    func startShowing() {
        queue.async { [weak self] in
            guard let self else { return }
            self.showing = true
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / VirtualCameraIDs.framesPerSecond)), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.showNoteIfIdle() }
            timer.resume()
            self.timer = timer
        }
    }

    func stopShowing() {
        queue.async {
            self.showing = false
            self.timer?.cancel()
            self.timer = nil
        }
    }

    /// Erklärbär sends nothing (live mode is off): the note keeps the camera from going black.
    private func showNoteIfIdle() {
        let now = Self.hostNanoseconds()
        guard now &- lastFed > 600_000_000 else { return }
        if note == nil, let buffer = Placeholder.picture(width: Int(VirtualCameraIDs.width), height: Int(VirtualCameraIDs.height)) {
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
            if let format { note = (buffer, format) }
        }
        guard let note else { return }
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: note.buffer, formatDescription: note.format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        picture.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: now)
    }

    // MARK: Input stream (Erklärbär)

    func startFeeding(from client: CMIOExtensionClient) {
        queue.async {
            log.info("Erklärbär liefert jetzt Bilder")
            self.feeder = client
            self.consume(client)
        }
    }

    func stopFeeding() {
        queue.async {
            self.feeder = nil
            self.lastFed = 0
        }
    }

    func clientLeft(_ client: CMIOExtensionClient) {
        queue.async {
            if self.feeder === client {
                self.feeder = nil
                self.lastFed = 0
            }
        }
    }

    private func consume(_ client: CMIOExtensionClient) {
        input.stream.consumeSampleBuffer(from: client) { [weak self] buffer, sequence, _, _, error in
            guard let self else { return }
            self.queue.async {
                guard self.feeder === client else { return }
                guard let buffer else {
                    // Nothing there yet: ask again shortly instead of spinning.
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(error == nil ? 4 : 50)) {
                        if self.feeder === client { self.consume(client) }
                    }
                    return
                }
                let now = Self.hostNanoseconds()
                self.lastFed = now
                if self.showing {
                    self.picture.stream.send(buffer, discontinuity: [], hostTimeInNanoseconds: now)
                }
                self.input.stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: now))
                self.consume(client)
            }
        }
    }
}

/// One of the two streams of the camera.
final class CameraStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let owner: CameraDevice
    private let direction: CMIOExtensionStream.Direction
    private var client: CMIOExtensionClient?

    init(name: String, id: UUID, direction: CMIOExtensionStream.Direction, format: CMIOExtensionStreamFormat, owner: CameraDevice) {
        self.format = format
        self.owner = owner
        self.direction = direction
        super.init()
        stream = CMIOExtensionStream(localizedName: name, streamID: id, direction: direction, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        direction == .sink
            ? [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
               .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
            : [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = owner.frameDuration }
        if properties.contains(.streamSinkBufferQueueSize) { result.sinkBufferQueueSize = 3 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { result.sinkBuffersRequiredForStartup = 1 }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex { activeFormatIndex = index }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        guard direction == .sink else { return true }
        // Only Erklärbär itself may put pictures into the camera.
        guard Self.isErklaerbaer(client) else { return false }
        log.info("Eingang für Erklärbär (pid \(client.pid)) freigegeben")
        self.client = client
        return true
    }

    /// When macOS names the sender it must be Erklärbär. Usually it does not (requests come through a macOS
    /// helper), and inside its sandbox the extension may not look at other processes: then, like other
    /// virtual cameras, it accepts the picture (only one sender at a time).
    private static func isErklaerbaer(_ client: CMIOExtensionClient) -> Bool {
        // macOS reports "unknown" when it does not know the sender.
        guard let signing = client.signingID, !signing.isEmpty, signing != "unknown" else { return true }
        if signing == VirtualCameraIDs.appSigningID { return true }
        log.error("Eingang abgelehnt für \(signing, privacy: .public)")
        return false
    }

    func startStream() throws {
        if direction == .sink {
            if let client { owner.startFeeding(from: client) }
        } else {
            owner.startShowing()
        }
    }

    func stopStream() throws {
        if direction == .sink { owner.stopFeeding() } else { owner.stopShowing() }
    }
}
