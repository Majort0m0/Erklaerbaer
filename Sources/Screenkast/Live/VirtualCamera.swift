import AppKit
import AVFoundation
import CoreMediaIO
import SystemExtensions

/// The camera "Erklärbär" for meetings: a camera extension inside the app (VirtualCamera/Extension) that
/// macOS installs once, after the user allows it in System Settings. Only builds signed with an Apple
/// Developer team contain it (see scripts/build-app.sh).
@MainActor
final class VirtualCamera: NSObject, ObservableObject {
    static let shared = VirtualCamera()

    enum Status: Equatable {
        case checking
        /// This copy of the app has no camera inside or cannot install it.
        case unavailable(String)
        case notInstalled
        case installing
        case needsApproval
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .checking
    /// Send the live picture to the camera while live mode runs.
    @Published var sending: Bool = UserDefaults.standard.object(forKey: "virtualCameraOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sending, forKey: "virtualCameraOn") }
    }

    private enum Purpose { case look, install, update, remove }
    private var pending: [ObjectIdentifier: Purpose] = [:]
    private var approvalTimer: Timer?

    static var bundledExtension: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(VirtualCameraIDs.extensionID).systemextension")
    }

    static var bundledVersion: String? {
        Bundle(url: bundledExtension)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    var isBundled: Bool { FileManager.default.fileExists(atPath: Self.bundledExtension.path) }

    /// An older installed camera is being replaced by the one inside this app.
    var isUpdating: Bool { pending.values.contains(.update) }

    /// macOS installs camera extensions only from apps in /Applications.
    var isInApplications: Bool { Bundle.main.bundleURL.path.hasPrefix("/Applications/") }

    /// Asks macOS whether the camera is installed (and quietly brings an older installed one up to date).
    func refresh() {
        guard isBundled else {
            status = .unavailable("Diese Ausgabe von Erklärbär enthält keine Kamera für Meetings.")
            return
        }
        submit(.propertiesRequest(forExtensionWithIdentifier: VirtualCameraIDs.extensionID, queue: .main), .look)
    }

    func install() {
        guard isBundled else { return refresh() }
        guard isInApplications else {
            status = .failed("Die Kamera lässt sich nur einrichten, wenn Erklärbär im Ordner „Programme“ liegt. Bitte die App dorthin ziehen und neu öffnen.")
            return
        }
        status = .installing
        submit(.activationRequest(forExtensionWithIdentifier: VirtualCameraIDs.extensionID, queue: .main), .install)
    }

    func remove() {
        submit(.deactivationRequest(forExtensionWithIdentifier: VirtualCameraIDs.extensionID, queue: .main), .remove)
    }

    #if DEBUG
    /// Pictures of the control window in a state (debug builds only).
    func pretend(_ new: Status) { status = new }
    #endif

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    private func submit(_ request: OSSystemExtensionRequest, _ purpose: Purpose) {
        pending[ObjectIdentifier(request)] = purpose
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// While macOS waits for the switch in System Settings, look again every few seconds.
    private func watchApproval(_ on: Bool) {
        approvalTimer?.invalidate()
        approvalTimer = nil
        guard on else { return }
        approvalTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.status == .needsApproval, !self.pending.values.contains(.look) else { return }
                self.submit(.propertiesRequest(forExtensionWithIdentifier: VirtualCameraIDs.extensionID, queue: .main), .look)
            }
        }
    }

    private func set(_ new: Status) {
        status = new
        watchApproval(new == .needsApproval)
    }

    private static func describe(_ error: Error) -> String {
        let error = error as NSError
        guard error.domain == OSSystemExtensionErrorDomain, let code = OSSystemExtensionError.Code(rawValue: error.code) else {
            return error.localizedDescription
        }
        switch code {
        case .unsupportedParentBundleLocation:
            return "Die Kamera lässt sich nur einrichten, wenn Erklärbär im Ordner „Programme“ liegt."
        case .requestCanceled:
            return "Das Einrichten wurde abgebrochen."
        case .authorizationRequired:
            return "macOS braucht dafür die Erlaubnis eines Administrators."
        case .forbiddenBySystemPolicy:
            return "Eine Richtlinie dieses Macs verbietet die Kamera-Erweiterung."
        case .codeSignatureInvalid, .validationFailed, .missingEntitlement:
            return "macOS lehnt die Kamera-Erweiterung ab (Signatur, Fehler \(error.code)). Diese Ausgabe von Erklärbär kann die Kamera nicht einrichten."
        default:
            return "Die Kamera ließ sich nicht einrichten (Fehler \(error.code)): \(error.localizedDescription)"
        }
    }
}

extension VirtualCamera: OSSystemExtensionRequestDelegate {
    // All requests are answered on the main queue.

    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { set(.needsApproval) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated {
            let purpose = pending.removeValue(forKey: ObjectIdentifier(request))
            if result == .willCompleteAfterReboot {
                set(.failed(purpose == .remove ? "Die Kamera verschwindet nach dem nächsten Neustart des Macs."
                                                : "Die Kamera ist nach dem nächsten Neustart des Macs bereit."))
            } else {
                set(purpose == .remove ? .notInstalled : .ready)
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            let purpose = pending.removeValue(forKey: ObjectIdentifier(request))
            switch purpose {
            case .look: set(.unavailable(Self.describe(error)))
            case .update: set(.ready)   // the installed older camera keeps working
            default: set(.failed(Self.describe(error)))
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        MainActor.assumeIsolated {
            pending.removeValue(forKey: ObjectIdentifier(request))
            let current = properties.filter { !$0.isUninstalling }
            if let on = current.first(where: { $0.isEnabled }) {
                if on.bundleVersion != Self.bundledVersion, isInApplications {
                    // Nobody of ours may use the camera meanwhile: while the old one still runs, macOS
                    // sometimes fails to start the new one (then only a restart of the Mac helps).
                    set(.installing)
                    if !pending.values.contains(.update) {
                        submit(.activationRequest(forExtensionWithIdentifier: VirtualCameraIDs.extensionID, queue: .main), .update)
                    }
                } else {
                    set(.ready)
                }
            } else if current.contains(where: { $0.isAwaitingUserApproval }) {
                set(.needsApproval)
            } else if status != .installing {
                set(.notInstalled)
            }
        }
    }
}

/// Puts the live picture into the input stream of the camera "Erklärbär", as a CoreMediaIO client.
/// Looks for the camera every two seconds while it is wanted, so it also connects once the camera
/// has been installed or macOS restarted it.
final class VirtualCameraFeed: @unchecked Sendable {
    enum State: Equatable {
        case off, searching, connected
        /// Installed but not to be found for a while: after an update macOS sometimes starts the
        /// camera only after a restart of the Mac.
        case missing
    }

    /// Called on a background queue when the state changes.
    var onState: ((State) -> Void)?

    private let lock = NSLock()
    private var queue: CMSimpleQueue?               // lock
    private var format: CMVideoFormatDescription?   // lock
    private let worker = DispatchQueue(label: "screenkast.virtualcamera")
    // worker only
    private var wanted = false
    private var device: CMIOObjectID = 0
    private var stream: CMIOStreamID = 0
    private var timer: DispatchSourceTimer?
    private var misses = 0
    private var state: State = .off {
        didSet { if state != oldValue { onState?(state) } }
    }

    var isConnected: Bool { lock.withLock { queue != nil } }

    func setActive(_ on: Bool) {
        worker.async { [weak self] in
            guard let self, on != self.wanted else { return }
            self.wanted = on
            self.timer?.cancel()
            self.timer = nil
            if on {
                self.misses = 0
                self.state = .searching
                let timer = DispatchSource.makeTimerSource(queue: self.worker)
                timer.schedule(deadline: .now(), repeating: 2)
                timer.setEventHandler { [weak self] in self?.check() }
                timer.resume()
                self.timer = timer
            } else {
                self.disconnect()
                self.state = .off
            }
        }
    }

    /// Waits until the camera is let go (when live mode ends).
    func stopNow() {
        setActive(false)
        worker.sync {}
    }

    /// One live picture (any queue). Skipped while the camera is behind.
    func send(_ buffer: CVPixelBuffer) {
        lock.withLock {
            guard let queue, CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return }
            if let current = format, CMVideoFormatDescriptionMatchesImageBuffer(current, imageBuffer: buffer) {
            } else {
                format = nil
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
            }
            guard let format else { return }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: VirtualCameraIDs.framesPerSecond),
                                            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
                                                           sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
            // The queue holds the sample with one retain; the camera releases it after taking it out.
            let element = Unmanaged.passRetained(sample)
            if CMSimpleQueueEnqueue(queue, element: element.toOpaque()) != noErr { element.release() }
        }
    }

    // MARK: Connection (worker)

    private func check() {
        guard wanted else { return }
        if stream != 0 {
            if Self.objects(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices).contains(device) { return }
            disconnect()   // the camera went away (updated or restarted by macOS)
        }
        connect()
    }

    private func connect() {
        let uid = VirtualCameraIDs.device.uuidString
        guard let found = Self.objects(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
                .first(where: { Self.string($0, kCMIODevicePropertyDeviceUID)?.caseInsensitiveCompare(uid) == .orderedSame }) else {
            misses += 1
            if misses >= 4 { state = .missing }
            return
        }
        misses = 0
        let streams = Self.objects(found, kCMIODevicePropertyStreams)
        // Direction 0 is the stream a client writes into.
        guard let sink = streams.first(where: { Self.uint32($0, kCMIOStreamPropertyDirection) == 0 }) else {
            NSLog("Erklärbär-Kamera: kein Eingang gefunden (%d Streams)", streams.count)
            return
        }
        var queueRef: Unmanaged<CMSimpleQueue>?
        let copied = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &queueRef)
        guard copied == noErr, let newQueue = queueRef?.takeRetainedValue() else {
            NSLog("Erklärbär-Kamera: Eingang nicht erreichbar (%d)", copied)
            return
        }
        let started = CMIODeviceStartStream(found, sink)
        guard started == noErr else {
            NSLog("Erklärbär-Kamera: Eingang ließ sich nicht starten (%d)", started)
            return
        }
        device = found
        stream = sink
        lock.withLock { queue = newQueue }
        state = .connected
    }

    private func disconnect() {
        guard stream != 0 else { return }
        let old: CMSimpleQueue? = lock.withLock {
            defer {
                queue = nil
                format = nil
            }
            return queue
        }
        CMIODeviceStopStream(device, stream)
        // Pictures still waiting in the queue belong to us again.
        if let old {
            while let element = CMSimpleQueueDequeue(old) { Unmanaged<CMSampleBuffer>.fromOpaque(element).release() }
        }
        device = 0
        stream = 0
        if wanted { state = .searching }
    }

    // MARK: CoreMediaIO properties

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    static func objects(_ object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    static func string(_ object: CMIOObjectID, _ selector: Int) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, $0)
        }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func uint32(_ object: CMIOObjectID, _ selector: Int) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr else { return nil }
        return value
    }
}
