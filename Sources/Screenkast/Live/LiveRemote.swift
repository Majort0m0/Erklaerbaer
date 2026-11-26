import AppKit
import Combine
import CoreImage
import Foundation

/// Picture of the live output for the remote control, kept from the last frame (any thread).
final class LiveRemoteFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private let context = CIContext(options: [.cacheIntermediates: false])

    func keep(_ buffer: CVPixelBuffer) { lock.withLock { frame = buffer } }
    func clear() { lock.withLock { frame = nil } }

    /// A small JPEG of the newest picture.
    func jpeg(width: CGFloat = 640) -> Data? {
        guard let frame = lock.withLock({ frame }) else { return nil }
        let image = CIImage(cvPixelBuffer: frame)
        let scale = width / max(1, image.extent.width)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.jpegRepresentation(of: small, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6])
    }
}

/// Device tokens that may control, readable from the server's thread.
final class LiveRemoteKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var byHash: [String: String] = [:]

    func set(_ devices: [LiveRemote.Device]) { lock.withLock { byHash = Dictionary(devices.map { ($0.tokenHash, $0.id) }, uniquingKeysWith: { a, _ in a }) } }
    /// The device a token belongs to (nil: not allowed).
    func device(for token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        let hash = LiveRemoteServer.hash(token)
        return lock.withLock { byHash[hash] }
    }
}

/// Control of the live mode from an iPhone or iPad in the same network: a web page that Erklärbär
/// serves itself, opened with a QR code. New devices must be allowed once on the Mac.
@MainActor
final class LiveRemote: ObservableObject {
    struct Device: Codable, Identifiable, Equatable {
        let id: String
        var name: String
        var tokenHash: String
        var added: Date
    }

    struct Request: Identifiable, Equatable {
        let id: String
        let device: String
        let name: String
        let asked: Date
    }

    static let preferredPort: UInt16 = 47_811

    @Published var enabled = UserDefaults.standard.bool(forKey: "liveRemoteOn") {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: "liveRemoteOn")
            if enabled { start() } else { stop() }
        }
    }
    /// What the QR code opens (with the secret for pairing).
    @Published private(set) var pairingURL: URL?
    @Published private(set) var devices: [Device] = LiveRemote.loadDevices()
    @Published private(set) var requests: [Request] = []
    @Published private(set) var connected: Set<String> = []
    @Published private(set) var problem: String?

    let frame = LiveRemoteFrame()
    private let keys = LiveRemoteKeys()
    private var server: LiveRemoteServer?
    private var secret = LiveRemoteServer.randomSecret()
    /// Answers to pairing requests, collected by the device (token or nil when refused).
    private var decided: [String: (token: String?, at: Date)] = [:]
    private weak var live: LiveModel?
    private var watch: AnyCancellable?
    private var tick: Timer?
    private var levelTimer: Timer?
    private var pendingState = false
    private var starting = false

    init() { keys.set(devices) }

    func attach(_ live: LiveModel) {
        self.live = live
        if enabled { start() }
    }

    func detach() {
        stop()
        live = nil
    }

    /// Tests: starts without the switch (which is kept in the settings) and without sounds.
    private var testing = false
    /// Tests: new devices are allowed without asking.
    var autoAllow = false

    func startForTesting(_ live: LiveModel) {
        testing = true
        self.live = live
        start(force: true)
    }

    // MARK: Server

    private func start(force: Bool = false) {
        guard server == nil, !starting, live != nil else { return }
        starting = true
        problem = nil
        let keys = keys, frame = frame
        let server = LiveRemoteServer { [weak self] request, reply in
            // Pictures straight from the server's thread; everything else on the main thread.
            if request.method == "GET", request.path == "/api/preview.jpg" {
                guard keys.device(for: request.token) != nil else { return reply(.response(.unauthorized)) }
                guard let data = frame.jpeg() else { return reply(.response(.notFound)) }
                return reply(.response(LiveRemoteServer.Response(type: "image/jpeg", body: data)))
            }
            Task { @MainActor in
                guard let self else { return reply(.response(.notFound)) }
                reply(self.handle(request))
            }
        }
        server.onStreamsChanged = { [weak self] devices in
            Task { @MainActor in
                self?.connected = devices
                self?.pushState()
            }
        }
        Task {
            do {
                let port = try await server.start(preferred: Self.preferredPort)
                self.server = server
                self.starting = false
                guard self.enabled || force else { return self.stop() }
                self.secret = LiveRemoteServer.randomSecret()
                self.updateURL(port: port)
                self.observe()
            } catch {
                self.starting = false
                self.problem = "Die Fernsteuerung lässt sich nicht starten: \(error.localizedDescription)"
            }
        }
    }

    private var port: UInt16 = 0

    private func updateURL(port: UInt16) {
        self.port = port
        guard let host = LiveRemoteServer.localAddress() else {
            pairingURL = nil
            problem = "Der Mac ist in keinem Netzwerk. iPhone oder iPad müssen im selben WLAN sein."
            return
        }
        pairingURL = URL(string: "http://\(host):\(port)/#k=\(secret)")
    }

    /// A new QR code: the old one no longer pairs (allowed devices stay allowed).
    func newCode() {
        secret = LiveRemoteServer.randomSecret()
        updateURL(port: port)
    }

    private func stop() {
        watch = nil
        tick?.invalidate()
        tick = nil
        levelTimer?.invalidate()
        levelTimer = nil
        server?.stop()
        server = nil
        pairingURL = nil
        requests = []
        connected = []
        frame.clear()
    }

    /// Changes in the live mode go out at once; a slow tick catches the rest (a meme that ends by itself).
    private func observe() {
        guard let live else { return }
        let changes: [AnyPublisher<Void, Never>] = [
            live.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            live.audio.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            live.overlays.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            MemeBoard.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        watch = Publishers.MergeMany(changes).sink { [weak self] in self?.schedulePush() }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pushState()
                self?.pushStatus()
            }
        }
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushLevels() }
        }
    }

    private func schedulePush() {
        guard !pendingState else { return }
        pendingState = true
        // objectWillChange comes before the change: send a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingState = false
                self?.pushState()
            }
        }
    }

    /// The last state sent: the same again is not sent (every change of the page under the finger can cost
    /// a tap on iOS).
    private var lastState: Data?

    private func pushState(force: Bool = false) {
        guard let server, !connected.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: state(), options: [.sortedKeys]) else { return }
        guard force || data != lastState else { return }
        lastState = data
        server.send(event: "state", json: data)
    }

    /// What changes all the time (pictures per second, recording time) goes separately, once a second.
    private func pushStatus() {
        guard let server, !connected.isEmpty, let live else { return }
        let object: [String: Any] = ["fps": live.framesPerSecond, "recordingTime": live.recordingTime]
        if let data = try? JSONSerialization.data(withJSONObject: object) { server.send(event: "status", json: data) }
    }

    private func pushLevels() {
        guard let server, !connected.isEmpty, let live else { return }
        let levels = live.audio.levels
        var apps: [String: Float] = [:]
        for (id, value) in levels.apps { apps[id] = value }
        let object: [String: Any] = ["voice": levels.voice, "device": levels.device, "memes": levels.memes, "meeting": levels.meeting, "apps": apps]
        if let data = try? JSONSerialization.data(withJSONObject: object) { server.send(event: "levels", json: data) }
    }

    // MARK: Requests

    private func handle(_ request: LiveRemoteServer.Request) -> LiveRemoteServer.Reply {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .response(.text(LiveRemotePage.html, type: "text/html; charset=utf-8"))
        case ("GET", "/manifest.webmanifest"):
            return .response(.text(LiveRemotePage.manifest, type: "application/manifest+json"))
        case ("GET", "/icon.png"):
            return .response(LiveRemoteServer.Response(type: "image/png", body: Self.iconPNG))
        case ("POST", "/api/pair"):
            return .response(pair(request.json ?? [:]))
        case ("GET", let path) where path.hasPrefix("/api/pair/"):
            return .response(pairStatus(String(path.dropFirst("/api/pair/".count))))
        default:
            break
        }
        guard let device = keys.device(for: request.token) else { return .response(.unauthorized) }
        switch (request.method, request.path) {
        case ("GET", "/api/hello"):
            return .response(.json(["ok": true, "name": devices.first { $0.id == device }?.name ?? ""]))
        case ("GET", "/api/events"):
            // The first state follows as soon as the stream is open.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                MainActor.assumeIsolated {
                    self?.pushState(force: true)
                    self?.pushStatus()
                }
            }
            return .stream(device: device)
        case ("POST", "/api/command"):
            return .response(command(request.json ?? [:]))
        case ("POST", "/api/background"):
            return .response(uploadBackground(request))
        case ("GET", let path) where path.hasPrefix("/api/meme/"):
            return .response(memeThumbnail(Int(path.dropFirst("/api/meme/".count).replacingOccurrences(of: ".jpg", with: "")) ?? -1))
        case ("GET", let path) where path.hasPrefix("/api/logo/"):
            return .response(logoThumbnail(String(path.dropFirst("/api/logo/".count).replacingOccurrences(of: ".png", with: ""))))
        default:
            return .response(.notFound)
        }
    }

    private func pair(_ body: [String: Any]) -> LiveRemoteServer.Response {
        guard let given = body["secret"] as? String, given == secret else { return .json(["status": "expired"]) }
        guard let device = body["device"] as? String, !device.isEmpty, device.count < 100 else { return .json(["status": "expired"], status: 400) }
        let name = String((body["name"] as? String ?? "Gerät").prefix(40))
        // Known devices (storage of the browser lost, home screen) get a new key without asking again.
        if devices.contains(where: { $0.id == device }) { return .json(["status": "approved", "token": allow(device: device, name: name)]) }
        if autoAllow { return .json(["status": "approved", "token": allow(device: device, name: name)]) }
        if let open = requests.first(where: { $0.device == device }) { return .json(["status": "waiting", "request": open.id]) }
        let request = Request(id: LiveRemoteServer.randomSecret(bytes: 9), device: device, name: name, asked: Date())
        requests.append(request)
        if !testing {
            live?.expand()
            NSSound(named: "Ping")?.play()
        }
        return .json(["status": "waiting", "request": request.id])
    }

    private func pairStatus(_ id: String) -> LiveRemoteServer.Response {
        decided = decided.filter { Date().timeIntervalSince($0.value.at) < 120 }
        if let answer = decided[id] {
            decided[id] = nil
            return answer.token.map { .json(["status": "approved", "token": $0]) } ?? .json(["status": "denied"])
        }
        requests.removeAll { Date().timeIntervalSince($0.asked) > 180 }
        return requests.contains { $0.id == id } ? .json(["status": "waiting", "request": id]) : .json(["status": "expired"])
    }

    func answer(_ request: Request, allow allowed: Bool) {
        requests.removeAll { $0.id == request.id }
        decided[request.id] = (allowed ? allow(device: request.device, name: request.name) : nil, Date())
    }

    /// Remembers the device with a new key and returns the key.
    private func allow(device: String, name: String) -> String {
        let token = LiveRemoteServer.randomSecret(bytes: 24)
        if let index = devices.firstIndex(where: { $0.id == device }) {
            devices[index].tokenHash = LiveRemoteServer.hash(token)
        } else {
            devices.append(Device(id: device, name: name, tokenHash: LiveRemoteServer.hash(token), added: Date()))
        }
        saveDevices()
        return token
    }

    func remove(_ device: Device) {
        devices.removeAll { $0.id == device.id }
        saveDevices()
        server?.close(device: device.id)
    }

    private func saveDevices() {
        keys.set(devices)
        if let data = try? JSONEncoder().encode(devices) { UserDefaults.standard.set(data, forKey: "liveRemoteDevices") }
    }

    private static func loadDevices() -> [Device] {
        UserDefaults.standard.data(forKey: "liveRemoteDevices").flatMap { try? JSONDecoder().decode([Device].self, from: $0) } ?? []
    }

    // MARK: State and commands

    private func state() -> [String: Any] {
        guard let live else { return ["live": false] }
        let audio = live.audio
        let scene: String = live.config.scene == .webcam ? "webcam" : (live.config.bubble ? "sourceCam" : "source")
        let playing = live.engine.playingMemeURL
        let board = MemeBoard.shared
        let memes: [[String: Any]] = board.slots.enumerated().map { index, slot in
            guard let slot else { return ["index": index, "empty": true] }
            return ["index": index, "title": slot.title, "playing": playing == board.url(of: slot)]
        }
        let logos: [[String: Any]] = live.overlays.logos.map {
            ["id": $0.id.uuidString, "name": $0.name, "on": live.shownLogoID == $0.id, "corner": $0.corner.rawValue, "size": $0.size, "opacity": $0.opacity]
        }
        let banners: [[String: Any]] = live.overlays.banners.map {
            ["id": $0.id.uuidString, "title": $0.title, "subtitle": $0.subtitle, "on": live.shownBannerID == $0.id]
        }
        func channel(_ c: LiveMixSettings.Channel) -> [String: Any] {
            ["meetingOn": c.meetingOn, "meeting": c.meeting, "earOn": c.earOn, "ear": c.ear]
        }
        var sources: [[String: Any]] = [["id": "voice", "name": "Stimme", "earAllowed": audio.voiceInEarAllowed, "mix": channel(audio.settings.voice)]]
        if live.isDeviceSource { sources.append(["id": "device", "name": "iPad", "earAllowed": true, "mix": channel(audio.settings.device)]) }
        sources.append(["id": "memes", "name": "Memes", "earAllowed": true, "mix": channel(audio.settings.memes)])
        let apps: [[String: Any]] = audio.apps.map {
            ["id": $0.id, "name": $0.name, "playing": $0.playing, "isMeeting": $0.id == audio.meetingApp, "mix": channel(audio.settings.app($0.id))]
        }
        let meetingMic: String = switch audio.meetingState {
        case .running: "running"
        case .off: "off"
        case .missing: "missing"
        case .failed: "failed"
        }
        let app = live.app
        let config = live.config
        let bubble = LiveCompositor.bubbleRect(config)
        let canvas = LiveCompositor.canvas
        let camera = VirtualCamera.shared, mic = VirtualMicrophone.shared
        func meeting(_ ready: Bool, _ shown: Bool, _ sending: Bool) -> [String: Any] { ["shown": shown, "ready": ready, "sending": sending] }
        let cameraShown: Bool = { if case .unavailable = camera.status { return false } else { return true } }()
        let micShown: Bool = { if case .unavailable = mic.status { return false } else { return true } }()
        return [
            "live": true,
            "source": Self.sourceID(live.source) ?? "",
            "videoSources": [
                "displays": app.displays.map { ["id": "display:\($0.displayID)", "name": app.displayName($0)] },
                "devices": app.deviceChoices.map { ["id": "device:\($0.id)", "name": $0.name] },
                "windows": (app.windows + app.otherWindows).map { ["id": "window:\($0.windowID)", "name": app.windowName($0)] },
            ],
            "sourceLost": live.sourceLost ?? NSNull(),
            "message": live.message ?? NSNull(),
            "isDevice": live.isDeviceSource,
            "camera": live.cameraID,
            "cameras": app.cameras.map { ["id": $0.uniqueID, "name": $0.localizedName] },
            "bubble": ["size": config.bubbleSize, "x": config.bubbleX, "y": config.bubbleY,
                       "cx": bubble.midX / canvas.width, "cy": 1 - bubble.midY / canvas.height, "d": bubble.height / canvas.height],
            "mockup": config.mockup?.rawValue ?? "",
            "mockups": MockupKind.allCases.map { ["id": $0.rawValue, "name": $0.label] },
            "background": config.background == true,
            "backgroundStyle": live.backgroundStyle.rawValue,
            "backgroundBlur": config.backgroundBlur ?? 0.5,
            "backgroundImage": live.backgroundFile != nil,
            "backgroundEdge": config.backgroundEdge ?? 0.5,
            "backgroundCalm": config.backgroundCalm ?? 0.5,
            "clicks": config.clicks,
            "trail": config.trail,
            "keys": config.keys == true,
            "memeSpot": config.memeSpot.rawValue,
            "memeSpots": MemeSpot.allCases.map { ["id": $0.rawValue, "name": $0.label] },
            "corners": CameraCorner.allCases.map { ["id": $0.rawValue, "name": $0.label] },
            "microphone": live.microphoneID,
            "microphones": app.microphones.map { ["id": $0.uniqueID, "name": $0.localizedName] },
            "meetingCamera": meeting(camera.status == .ready, cameraShown, camera.sending),
            "meetingMicrophone": meeting(mic.status == .ready, micShown, mic.sending),
            "meetingApp": mic.meetingApp,
            "showProgram": live.showProgram,
            "runningApps": VirtualMicrophone.runningApps().map { ["id": $0.id, "name": $0.name] },
            "recording": live.isRecording,
            "scene": scene,
            "muted": audio.settings.muted,
            "meetingMic": meetingMic,
            "ear": audio.ear.map { ["name": $0.name, "headphones": $0.headphones] } ?? NSNull(),
            "memes": memes,
            "logos": logos,
            "banners": banners,
            "sources": sources,
            "apps": apps,
            "range": [LiveMixSettings.range.lowerBound, LiveMixSettings.range.upperBound],
        ]
    }

    private func command(_ body: [String: Any]) -> LiveRemoteServer.Response {
        guard let live, let action = body["action"] as? String else { return .json(["ok": false], status: 400) }
        switch action {
        case "scene":
            switch body["value"] as? String {
            case "webcam": live.config.scene = .webcam
            case "source":
                live.config.scene = .source
                live.config.bubble = false
            case "sourceCam":
                live.config.scene = .source
                live.config.bubble = true
            default: return .json(["ok": false], status: 400)
            }
        case "meme":
            guard let index = body["index"] as? Int, MemeBoard.shared.slots.indices.contains(index), let slot = MemeBoard.shared.slots[index] else {
                return .json(["ok": false], status: 400)
            }
            live.playMeme(slot)
        case "logo":
            guard let id = (body["id"] as? String).flatMap(UUID.init(uuidString:)), let logo = live.overlays.logos.first(where: { $0.id == id }) else {
                return .json(["ok": false], status: 400)
            }
            live.toggle(logo: logo)
        case "banner":
            guard let id = (body["id"] as? String).flatMap(UUID.init(uuidString:)), let banner = live.overlays.banners.first(where: { $0.id == id }) else {
                return .json(["ok": false], status: 400)
            }
            live.toggle(banner: banner)
        case "mute":
            live.audio.settings.muted = body["value"] as? Bool ?? !live.audio.settings.muted
        case "record":
            live.toggleRecording()
        case "set":
            guard let key = body["key"] as? String, set(key, body["value"], on: live) else { return .json(["ok": false], status: 400) }
        case "refreshSources":
            // Tests run without the permission for screen recording: macOS would ask.
            guard !testing else { break }
            Task {
                await live.app.refreshSources()
                live.app.refreshDevices()
                self.pushState()
            }
        case "restartSource":
            live.restartSource()
        case "logoSettings":
            guard let id = (body["id"] as? String).flatMap(UUID.init(uuidString:)), var logo = live.overlays.logo(id) else {
                return .json(["ok": false], status: 400)
            }
            if let corner = (body["corner"] as? String).flatMap(CameraCorner.init(rawValue:)) { logo.corner = corner }
            if let size = (body["size"] as? NSNumber)?.doubleValue { logo.size = min(0.4, max(0.05, size)) }
            if let opacity = (body["opacity"] as? NSNumber)?.doubleValue { logo.opacity = min(1, max(0.2, opacity)) }
            live.overlays.update(logo)
        case "mix":
            guard let source = body["source"] as? String, let path = body["path"] as? String, path == "meeting" || path == "ear" else {
                return .json(["ok": false], status: 400)
            }
            func change(_ channel: inout LiveMixSettings.Channel) {
                if let on = body["on"] as? Bool { if path == "meeting" { channel.meetingOn = on } else { channel.earOn = on } }
                if let db = (body["db"] as? NSNumber)?.doubleValue {
                    let value = min(LiveMixSettings.range.upperBound, max(LiveMixSettings.range.lowerBound, db))
                    if path == "meeting" { channel.meeting = value } else { channel.ear = value }
                }
            }
            switch source {
            case "voice": change(&live.audio.settings.voice)
            case "device": change(&live.audio.settings.device)
            case "memes": change(&live.audio.settings.memes)
            default:
                guard source.hasPrefix("app:"), path == "meeting" else { return .json(["ok": false], status: 400) }
                let id = String(source.dropFirst(4))
                guard id != live.audio.meetingApp else { return .json(["ok": false], status: 400) }
                change(&live.audio.settings.apps[id, default: LiveMixSettings.newApp])
            }
        default:
            return .json(["ok": false], status: 400)
        }
        schedulePush()
        return .json(["ok": true])
    }

    /// One setting of the control window; false if the key or the value is not known.
    private func set(_ key: String, _ value: Any?, on live: LiveModel) -> Bool {
        let number = (value as? NSNumber)?.doubleValue
        let flag = value as? Bool
        let text = value as? String
        func clamp(_ range: ClosedRange<Double>) -> Double? { number.map { min(range.upperBound, max(range.lowerBound, $0)) } }
        switch key {
        case "source":
            guard let text, let selection = Self.selection(text) else { return false }
            live.source = selection
        case "camera":
            guard let text, text.isEmpty || live.app.cameras.contains(where: { $0.uniqueID == text }) else { return false }
            live.cameraID = text
        case "bubbleSize":
            guard let size = clamp(0.12...0.9) else { return false }
            live.config.bubbleSize = size
        case "bubble":
            guard let point = value as? [String: Any], let x = (point["x"] as? NSNumber)?.doubleValue, let y = (point["y"] as? NSNumber)?.doubleValue else { return false }
            var config = live.config
            config.bubbleX = min(1, max(0, x))
            config.bubbleY = min(1, max(0, y))
            live.config = config
        case "mockup":
            guard let text else { return false }
            live.config.mockup = MockupKind(rawValue: text)
        case "background":
            guard let flag else { return false }
            // Without a picture the switch stays off: the remote asks for one first.
            live.config.background = flag && live.backgroundFile != nil
        case "backgroundStyle":
            guard let style = text.flatMap(LiveModel.BackgroundStyle.init(rawValue:)), style != .image || live.backgroundFile != nil else { return false }
            live.setBackgroundStyle(style)
        case "backgroundBlur":
            guard let amount = clamp(0...1) else { return false }
            var new = live.config
            new.background = true
            new.backgroundBlur = amount
            live.config = new
        case "backgroundEdge":
            guard let edge = clamp(0.1...0.9) else { return false }
            live.config.backgroundEdge = edge
        case "backgroundCalm":
            guard let calm = clamp(0...0.9) else { return false }
            live.config.backgroundCalm = calm
        case "clicks":
            guard let flag else { return false }
            live.config.clicks = flag
        case "trail":
            guard let flag else { return false }
            live.config.trail = flag
        case "keys":
            guard let flag else { return false }
            live.setKeys(flag)
        case "memeSpot":
            guard let spot = text.flatMap(MemeSpot.init(rawValue:)) else { return false }
            live.config.memeSpot = spot
        case "microphone":
            guard let text, !live.isRecording, text.isEmpty || live.app.microphones.contains(where: { $0.uniqueID == text }) else { return false }
            live.microphoneID = text
        case "meetingCamera":
            guard let flag, VirtualCamera.shared.status == .ready else { return false }
            VirtualCamera.shared.sending = flag
        case "meetingMicrophone":
            guard let flag, VirtualMicrophone.shared.status == .ready else { return false }
            VirtualMicrophone.shared.sending = flag
        case "meetingApp":
            guard let text else { return false }
            VirtualMicrophone.shared.meetingApp = text
        case "showProgram":
            guard let flag else { return false }
            live.showProgram = flag
        case "headphones":
            guard let flag else { return false }
            live.audio.setHeadphones(flag)
        default:
            return false
        }
        return true
    }

    /// A picture from the phone becomes the background behind the person.
    private func uploadBackground(_ request: LiveRemoteServer.Request) -> LiveRemoteServer.Response {
        guard let live, !request.body.isEmpty else { return .json(["ok": false], status: 400) }
        let type = request.headers["content-type"] ?? ""
        let ext = type.contains("png") ? "png" : type.contains("heic") ? "heic" : "jpg"
        do {
            try live.adoptBackground(request.body, fileExtension: ext)
            schedulePush()
            return .json(["ok": true])
        } catch {
            return .json(["ok": false, "error": error.localizedDescription], status: 400)
        }
    }

    static func sourceID(_ selection: SourceSelection?) -> String? {
        switch selection {
        case .display(let id): return "display:\(id)"
        case .window(let id): return "window:\(id)"
        case .device(let id): return "device:\(id)"
        case .region(let id, _): return "display:\(id)"
        case nil: return nil
        }
    }

    static func selection(_ id: String) -> SourceSelection? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        let kind = id[..<colon], value = String(id[id.index(after: colon)...])
        switch kind {
        case "display": return UInt32(value).map { .display($0) }
        case "window": return UInt32(value).map { .window($0) }
        case "device": return value.isEmpty ? nil : .device(value)
        default: return nil
        }
    }

    private func memeThumbnail(_ index: Int) -> LiveRemoteServer.Response {
        let board = MemeBoard.shared
        guard board.slots.indices.contains(index), let slot = board.slots[index], let image = board.thumbnail(of: slot),
              let data = Self.encode(image, maxSize: 240, jpeg: true) else { return .notFound }
        return LiveRemoteServer.Response(type: "image/jpeg", body: data)
    }

    private func logoThumbnail(_ id: String) -> LiveRemoteServer.Response {
        guard let live, let uuid = UUID(uuidString: id), let logo = live.overlays.logos.first(where: { $0.id == uuid }),
              let image = NSImage(contentsOfFile: live.overlays.path(of: logo)), let data = Self.encode(image, maxSize: 160, jpeg: false) else { return .notFound }
        return LiveRemoteServer.Response(type: "image/png", body: data)
    }

    private static func encode(_ image: NSImage, maxSize: CGFloat, jpeg: Bool) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxSize / CGFloat(max(cg.width, cg.height)))
        let width = max(1, Int(CGFloat(cg.width) * scale)), height = max(1, Int(CGFloat(cg.height) * scale))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSImage(cgImage: cg, size: .zero).draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: 0.7] : [:])
    }

    /// The app icon for the home screen of the iPhone.
    private static let iconPNG: Data = {
        let icon = NSApp?.applicationIconImage ?? NSImage(size: NSSize(width: 180, height: 180))
        return encode(icon, maxSize: 180, jpeg: false) ?? Data()
    }()

    // MARK: QR code

    static func qrImage(for url: URL, size: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = (size / output.extent.width).rounded(.down)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: max(1, scale), y: max(1, scale)))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
