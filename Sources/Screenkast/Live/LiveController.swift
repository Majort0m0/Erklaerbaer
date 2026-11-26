import AppKit
import AVFoundation
import Combine
import SwiftUI
import ScreenCaptureKit

/// The window with the finished picture: this one is shared in Zoom, Teams or Meet.
@MainActor
final class LiveProgramWindow: NSObject, NSWindowDelegate {
    static let title = "Erklärbär – Programm"
    private var window: NSWindow?
    private let layer = CALayer()
    var onClose: (() -> Void)?
    var windowNumber: Int? { window?.windowNumber }

    func show() {
        guard window == nil else { return }
        let size = NSSize(width: 960, height: 540)
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: visible.minX + 40, y: visible.maxY - size.height - 40, width: size.width, height: size.height)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = Self.title
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentAspectRatio = size
        window.delegate = self
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        layer.backgroundColor = NSColor.black.cgColor
        layer.contentsGravity = .resizeAspect
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func present(_ surface: Any) { layer.contents = surface }

    func close() {
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

/// Where the control window goes when it is folded away.
enum LiveDrawer {
    static let handleSize = CGSize(width: 30, height: 104)

    static func frames(panel: NSRect, screen: NSRect, visible: NSRect) -> (hidden: NSRect, handle: NSRect, atRight: Bool) {
        let atRight = panel.midX >= visible.midX
        var hidden = panel
        hidden.origin.x = atRight ? screen.maxX : screen.minX - panel.width
        let y = min(visible.maxY - handleSize.height, max(visible.minY, panel.midY - handleSize.height / 2))
        let handle = NSRect(x: atRight ? screen.maxX - handleSize.width : screen.minX, y: y, width: handleSize.width, height: handleSize.height)
        return (hidden, handle, atRight)
    }
}

/// State of the live mode and its two windows.
@MainActor
final class LiveModel: NSObject, ObservableObject, NSWindowDelegate {
    unowned let app: AppModel
    let engine = LiveEngine()
    let previewLayer = CALayer()
    private let program = LiveProgramWindow()
    private var panel: NSPanel?
    private var handle: NSPanel?
    private var openFrame: NSRect?
    private var sourceTask: Task<Void, Never>?
    private var ending = false
    private var areaTimer: Timer?
    private var statsTimer: Timer?
    private var recordingURL: URL?
    private var recordingStart: Date?
    private var progress: RecordingProgressWriter?
    private var trackedSize: CGSize?
    var dragStart: LiveConfig?

    /// The chosen picture behind the person, kept in the app's own folder.
    @Published private(set) var backgroundFile: URL? = UserDefaults.standard.string(forKey: "liveBackground").map { URL(fileURLWithPath: $0) }.flatMap {
        FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
    }

    @Published var config: LiveConfig {
        didSet {
            engine.setConfig(config)
            if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: "liveConfig") }
        }
    }
    @Published var source: SourceSelection? { didSet { if source != oldValue { applySource() } } }
    @Published var cameraID: String {
        didSet {
            UserDefaults.standard.set(cameraID, forKey: "liveCameraID")
            engine.camera.select(deviceID: cameraID.isEmpty ? nil : cameraID)
        }
    }
    @Published var microphoneID: String { didSet { UserDefaults.standard.set(microphoneID, forKey: "liveMicrophoneID") } }
    /// The big window with the live picture (for screen sharing). Off when only the camera "Erklärbär" is used.
    @Published var showProgram: Bool = UserDefaults.standard.object(forKey: "liveShowProgram") as? Bool ?? true {
        didSet {
            guard showProgram != oldValue else { return }
            UserDefaults.standard.set(showProgram, forKey: "liveShowProgram")
            guard panel != nil else { return }
            if showProgram { program.show() } else { program.close() }
        }
    }
    @Published private(set) var isRecording = false
    @Published private(set) var recordingTime: TimeInterval = 0
    @Published private(set) var framesPerSecond = 0
    @Published var message: String?
    /// Why the screen or window no longer comes in (nil: it does).
    @Published private(set) var sourceLost: String?
    /// How far the live picture is from the camera "Erklärbär".
    @Published private(set) var meetingCameraState: VirtualCameraFeed.State = .off
    private var meetingCameraWatch: AnyCancellable?
    /// How far the sound is from the microphone "Erklärbär".
    @Published private(set) var meetingMicState: LiveAudio.MeetingState = .off
    /// The sound: mixer for the meeting and the ear.
    let audio = LiveAudio()
    /// Control from an iPhone or iPad in the same network.
    let remote = LiveRemote()
    private var meetingMicWatch: AnyCancellable?
    private var audioStateWatch: AnyCancellable?
    private var mixer: NSPanel?
    let overlays = LiveOverlayLibrary.shared
    private var overlayWatch: AnyCancellable?
    private var bannerEditor: NSWindow?

    var isDeviceSource: Bool { if case .device = source { return true } else { return false } }

    init(app: AppModel) {
        self.app = app
        config = UserDefaults.standard.data(forKey: "liveConfig").flatMap { try? JSONDecoder().decode(LiveConfig.self, from: $0) } ?? LiveConfig()
        let savedCamera = UserDefaults.standard.string(forKey: "liveCameraID") ?? app.cameraID
        cameraID = app.cameras.contains { $0.uniqueID == savedCamera } ? savedCamera : (app.cameras.first?.uniqueID ?? "")
        let savedMic = UserDefaults.standard.string(forKey: "liveMicrophoneID") ?? app.microphoneID
        microphoneID = app.microphones.contains { $0.uniqueID == savedMic } ? savedMic : ""
        super.init()
        adoptOldLogo()
        syncOverlays()
        // Edited or removed logos and banners show at once.
        overlayWatch = overlays.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.syncOverlays() }
        }
    }

    func begin() {
        engine.setBackground(url: backgroundFile)
        engine.setConfig(config)
        previewLayer.contentsGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        let remoteFrame = remote.frame
        engine.onPresent = { [weak self] buffer in
            remoteFrame.keep(buffer)
            guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
            MainActor.assumeIsolated {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self?.program.present(surface)
                self?.previewLayer.contents = surface
                CATransaction.commit()
            }
        }
        engine.onProblem = { [weak self] text in
            Task { @MainActor in self?.message = text }
        }
        engine.onSourceLost = { [weak self] error in
            Task { @MainActor in self?.lostSource(error) }
        }
        engine.virtualCamera.onState = { [weak self] state in
            Task { @MainActor in self?.meetingCameraState = state }
        }
        engine.start()
        let meetingCamera = VirtualCamera.shared
        meetingCamera.refresh()
        meetingCameraWatch = meetingCamera.$sending.combineLatest(meetingCamera.$status).sink { [weak self] sending, status in
            // Only once macOS has answered (and an update is through): using the camera during an update can
            // keep macOS from starting the new one.
            self?.engine.virtualCamera.setActive(sending && status == .ready)
        }
        let mic = VirtualMicrophone.shared
        mic.refresh()
        // The meeting needs a voice: without a chosen microphone the Mac's own one is taken.
        if microphoneID.isEmpty, mic.status == .ready, mic.sending, let standard = AVCaptureDevice.default(for: .audio),
           app.microphones.contains(where: { $0.uniqueID == standard.uniqueID }) {
            microphoneID = standard.uniqueID
        }
        audio.start()
        audioStateWatch = audio.$meetingState.sink { [weak self] state in self?.meetingMicState = state }
        // Memes and the iPad go into the mixer directly (Erklärbär's own sound is never taken up from the Mac).
        let audio = audio
        engine.onMemeSound = { url in audio.playClip(url) }
        engine.onDeviceSound = { sample in audio.takeDeviceSound(sample) }
        meetingMicWatch = mic.$status.combineLatest(mic.$sending, mic.$meetingApp)
            .combineLatest($microphoneID)
            .sink { [weak self] values, micID in
                let (status, sending, meetingApp) = values
                self?.audio.configure(microphone: micID.isEmpty ? nil : micID, meeting: sending && status == .ready, meetingApp: meetingApp)
            }
        if config.keys == true, KeyShortcuts.isTrusted(prompt: false) { engine.watchKeys(true) }
        program.onClose = { [weak self] in Task { @MainActor in await self?.end() } }
        if showProgram { program.show() }
        showPanel()
        remote.attach(self)
        if !cameraID.isEmpty { engine.camera.select(deviceID: cameraID) }
        // Windows move and change size while they are live.
        areaTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followWindow() }
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.framesPerSecond = self.engine.framesPerSecond
                if let start = self.recordingStart { self.recordingTime = Date().timeIntervalSince(start) }
            }
        }
        applySource()
    }

    private func showPanel() {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // The window follows its content when sections open and close.
        let controller = NSHostingController(rootView: LiveControlView(live: self, app: app))
        controller.sizingOptions = [.preferredContentSize]
        let size = controller.view.fittingSize
        let rect = NSRect(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: rect, styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Erklärbär Live – Steuerung"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none   // never to be seen in the meeting, even when a whole screen is shared
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = controller
        panel.setContentSize(size)
        panel.delegate = self
        panel.orderFrontRegardless()
        self.panel = panel
    }

    // MARK: Drawer

    /// Slides the control window off the screen; a handle stays at the edge.
    func collapse() {
        guard let panel, handle == nil, let screen = panel.screen ?? NSScreen.main else { return }
        let place = LiveDrawer.frames(panel: panel.frame, screen: screen.frame, visible: screen.visibleFrame)
        openFrame = panel.frame
        let handle = NSPanel(contentRect: place.handle, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        handle.level = .floating
        handle.isFloatingPanel = true
        handle.hidesOnDeactivate = false
        handle.isReleasedWhenClosed = false
        handle.isOpaque = false
        handle.backgroundColor = .clear
        handle.sharingType = .none
        handle.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        handle.contentView = NSHostingView(rootView: LiveDrawerHandle(live: self, atRight: place.atRight))
        self.handle = handle
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            panel.animator().setFrame(place.hidden, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            handle.orderFrontRegardless()
        })
    }

    /// Brings the control window back.
    func expand() {
        guard let panel, let handle, let open = openFrame else { return }
        handle.orderOut(nil)
        self.handle = nil
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().setFrame(NSRect(x: open.minX, y: open.maxY - panel.frame.height, width: panel.frame.width, height: panel.frame.height), display: true)
            panel.animator().alphaValue = 1
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in await self.end() }
    }

    func end() async {
        guard !ending else { return }
        ending = true
        if isRecording { await stopRecording() }
        areaTimer?.invalidate()
        statsTimer?.invalidate()
        meetingCameraWatch = nil
        meetingMicWatch = nil
        audioStateWatch = nil
        remote.detach()
        audio.stop()
        mixer?.orderOut(nil)
        mixer = nil
        bannerEditor?.close()
        bannerEditor = nil
        engine.onPresent = nil
        program.onClose = nil
        program.close()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        handle?.orderOut(nil)
        handle = nil
        await sourceTask?.value
        await engine.stop()
        app.liveEnded()
    }

    /// Keyboard shortcuts in the picture; macOS asks for the permission the first time.
    func setKeys(_ on: Bool) {
        config.keys = on
        guard on else {
            engine.watchKeys(false)
            return
        }
        if KeyShortcuts.isTrusted(prompt: true) {
            engine.watchKeys(true)
            message = nil
        } else {
            message = "Für die Tastatur-Einblendung bitte Erklärbär unter Systemeinstellungen › Datenschutz & Sicherheit › Bedienungshilfen erlauben und den Schalter neu setzen."
        }
    }

    func chooseBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Bild für den Hintergrund der Webcam"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try adoptBackground(Data(contentsOf: url), fileExtension: url.pathExtension)
        } catch {
            message = "Das Bild ließ sich nicht übernehmen: \(error.localizedDescription)"
        }
    }

    /// Keeps a picture (from the Mac or sent by the remote control) as the background behind the person and shows it.
    func adoptBackground(_ data: Data, fileExtension: String) throws {
        guard NSImage(data: data) != nil else { throw RecorderError.writerFailed("Das ist kein Bild.") }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Screenkast/Backgrounds", isDirectory: true)
        let target = folder.appendingPathComponent(UUID().uuidString + "." + (fileExtension.isEmpty ? "jpg" : fileExtension.lowercased()))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: target)
        if let old = backgroundFile { try? FileManager.default.removeItem(at: old) }
        backgroundFile = target
        UserDefaults.standard.set(target.path, forKey: "liveBackground")
        engine.setBackground(url: target)
        var new = config
        new.background = true
        new.backgroundBlur = nil   // a picture was chosen: the picture, not the blur
        config = new
    }

    enum BackgroundStyle: String { case real, blur, image }

    /// What is behind the person: the real room, the room blurred, or a picture.
    var backgroundStyle: BackgroundStyle {
        config.background != true ? .real : (config.backgroundBlur != nil ? .blur : .image)
    }

    /// Switches the background; a picture is asked for when there is none yet.
    func setBackgroundStyle(_ style: BackgroundStyle) {
        var new = config
        switch style {
        case .real:
            new.background = false
        case .blur:
            new.background = true
            new.backgroundBlur = new.backgroundBlur ?? 0.5
        case .image:
            guard backgroundFile != nil else { return chooseBackground() }
            new.background = true
            new.backgroundBlur = nil
        }
        config = new
    }

    // MARK: Logos and banners

    /// Older versions kept one logo in the live settings: it becomes the first logo of the library.
    private func adoptOldLogo() {
        guard config.logoID == nil, let old = config.logo,
              let logo = overlays.adopt(file: old.file, corner: old.corner, size: old.size, opacity: old.opacity) else { return }
        config.logoID = config.logoOn == true ? logo.id : nil
        if config.logoOn != true { config.logo = nil }
    }

    /// Puts the current state of the shown logo and banner into the picture (after edits in the library).
    private func syncOverlays() {
        var new = config
        if let logo = overlays.logo(new.logoID), new.logoOn == true {
            new.logo = overlays.watermark(logo)
        } else {
            new.logoID = nil
            new.logoOn = false
        }
        new.banner = overlays.banner(new.banner?.id).map(overlays.resolved)
        if new != config { config = new }
    }

    var shownLogoID: UUID? { config.logoOn == true ? config.logoID : nil }
    var shownBannerID: UUID? { config.banner?.id }

    /// Shows the logo, or takes it away when it is already shown. Another logo takes its place.
    func toggle(logo: LiveLogo) {
        if shownLogoID == logo.id {
            config.logoOn = false
            config.logoID = nil
        } else {
            config.logoID = logo.id
            config.logo = overlays.watermark(logo)
            config.logoOn = true
        }
    }

    func toggle(banner: LiveBanner) {
        config.banner = shownBannerID == banner.id ? nil : overlays.resolved(banner)
    }

    /// Asks for picture files and keeps them as logos. Returns the new logos.
    @discardableResult
    func pickLogos() -> [LiveLogo] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Logos für das Live-Bild (am besten PNGs mit transparentem Hintergrund)"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return [] }
        do {
            return try overlays.addLogos(panel.urls)
        } catch {
            message = "Das Logo ließ sich nicht übernehmen: \(error.localizedDescription)"
            return []
        }
    }

    /// New logos from files; a single new one is shown at once.
    func addLogos() {
        let added = pickLogos()
        if added.count == 1, let first = added.first { toggle(logo: first) }
    }

    func newBanner() {
        let banner = overlays.addBanner()
        editBanner(banner.id)
    }

    /// The banner in its own window: typing there never reaches the shortcuts of the control window.
    func editBanner(_ id: UUID) {
        bannerEditor?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Banner bearbeiten"
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.level = .floating
        let controller = NSHostingController(rootView: LiveBannerEditor(live: self, library: overlays, bannerID: id))
        controller.sizingOptions = [.preferredContentSize]
        window.contentViewController = controller
        window.center()
        bannerEditor = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// The mixer in a window of its own, next to the control window; never seen in the meeting.
    func openMixer() {
        if let mixer {
            mixer.orderFrontRegardless()
            return
        }
        let controller = NSHostingController(rootView: LiveMixerView(live: self, audio: audio))
        controller.sizingOptions = [.preferredContentSize]
        let size = controller.view.fittingSize
        let anchor = panel?.frame ?? (NSScreen.main?.visibleFrame ?? .zero)
        let rect = NSRect(x: max(0, anchor.minX - size.width - 12), y: anchor.maxY - size.height, width: size.width, height: size.height)
        let window = NSPanel(contentRect: rect, styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        window.title = "Erklärbär – Ton"
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentViewController = controller
        window.setContentSize(size)
        window.orderFrontRegardless()
        mixer = window
    }

    func closeBannerEditor() {
        bannerEditor?.close()
        bannerEditor = nil
    }

    func playMeme(_ slot: MemeSlot) {
        // With the ear mix running, the meme is heard through it (with its own volume).
        engine.memeSoundOnMac = !audio.earRunning
        engine.playMeme(url: MemeBoard.shared.url(of: slot), length: slot.liveLength, transparent: slot.transparent == true)
    }

    // MARK: Source

    func lostSource(_ error: Error) {
        let what = if case .window = source { "Die Aufnahme des Fensters" } else { "Die Bildschirmaufnahme" }
        let error = error as NSError
        if error.domain == SCStreamErrorDomain, error.code == SCStreamError.Code.userStopped.rawValue {
            sourceLost = "\(what) wurde beendet, wohl über „Nicht mehr teilen“ im macOS-Menü oben rechts. Das Live-Bild zeigt so lange das letzte Bild."
        } else if error.domain == SCStreamErrorDomain, error.code == SCStreamError.Code.noCaptureSource.rawValue {
            sourceLost = "\(what) ist nicht mehr möglich: Das Fenster oder der Bildschirm ist weg. Bitte eine andere Quelle wählen."
        } else {
            sourceLost = "macOS hat \(what.replacingOccurrences(of: "Die ", with: "die ")) beendet (\(error.localizedDescription)). Das Live-Bild zeigt so lange das letzte Bild."
        }
    }

    /// Starts the capture of the chosen screen or window again.
    func restartSource() { applySource() }

    private func applySource() {
        sourceLost = nil
        let previous = sourceTask
        let selection = source
        // The iPad is heard through the ear mix (with its own volume), not straight from the capture.
        let hear = false
        sourceTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            var problem: String?
            switch selection {
            case .display(let id):
                if let d = self.app.displays.first(where: { $0.displayID == id }) {
                    self.trackedSize = nil
                    problem = await self.engine.useScreen(filter: SCContentFilter(display: d, excludingApplications: self.app.ownApplications, exceptingWindows: []), area: d.frame)
                }
            case .window(let id):
                if let w = (self.app.windows + self.app.otherWindows).first(where: { $0.windowID == id }) {
                    self.trackedSize = w.frame.size
                    WindowFocus.bringToFront(w)
                    problem = await self.engine.useScreen(filter: SCContentFilter(desktopIndependentWindow: w), area: w.frame)
                }
            case .device(let id):
                self.trackedSize = nil
                problem = await self.engine.useDevice(id: id, hear: hear)
            default:
                break
            }
            self.message = problem
        }
    }

    private func followWindow() {
        guard case .window(let id) = source,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds) else { return }
        let changed = trackedSize.map { abs($0.width - frame.width) > 1 || abs($0.height - frame.height) > 1 } ?? false
        if changed { trackedSize = frame.size }
        engine.updateArea(frame, resize: changed)
    }

    // MARK: Recording

    func toggleRecording() {
        Task { if isRecording { await stopRecording() } else { await startRecording() } }
    }

    private func startRecording() async {
        guard !isRecording else { return }
        message = nil
        if !microphoneID.isEmpty, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            message = "Kein Zugriff aufs Mikrofon – die Aufnahme läuft ohne Mikrofon."
            microphoneID = ""
        }
        let url = Project.makeNewProjectURL(in: ProjectLocations.recordingFolder)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let separate = audio.recordsMeetingSeparately
            let (roles, start) = try engine.startRecording(to: url.appendingPathComponent("screen.mov"),
                                                           microphoneID: microphoneID.isEmpty ? nil : microphoneID, meeting: separate)
            // The others in the meeting ("Meeting") and programs, iPad and memes ("Systemton") on their own tracks.
            let engine = engine
            audio.startRecording(at: start, separateMeeting: separate) { sample, role in engine.appendRecordedSound(sample, role: role) }
            let info = Self.info(duration: 0, roles: roles)
            progress = try? RecordingProgressWriter(folder: url, info: info)
            recordingRoles = roles
            recordingURL = url
            recordingStart = Date()
            recordingTime = 0
            isRecording = true
        } catch {
            try? FileManager.default.removeItem(at: url)
            message = "Die Aufnahme ließ sich nicht starten: \(error.localizedDescription)"
        }
    }

    private var recordingRoles: [String] = []

    private static func info(duration: Double, roles: [String]) -> RecordingInfo {
        RecordingInfo(pixelWidth: Int(LiveCompositor.canvas.width), pixelHeight: Int(LiveCompositor.canvas.height), pointPixelScale: 1, duration: duration,
                      createdAt: Date(), sourceName: "Live-Aufnahme", hasMicrophone: roles.contains("mic"), cameraFile: nil, audioTracks: roles)
    }

    private func stopRecording() async {
        guard isRecording, let url = recordingURL else { return }
        isRecording = false
        recordingStart = nil
        recordingURL = nil
        progress?.flush()
        do {
            let duration = try await engine.stopRecording { [audio] end in await audio.finishRecording(at: end) }
            var settings = ProjectFactory.plainSettings(aspect: .wide)
            // The meeting comes out of headphones or loudspeakers and the microphone picks a little of it up:
            // the voice track is cleaned against what was played.
            settings.removeEcho = recordingRoles.contains("mic") && (recordingRoles.contains("system") || recordingRoles.contains("meeting"))
            let project = Project(url: url, info: Self.info(duration: duration, roles: recordingRoles), cursor: CursorTrack(), settings: settings)
            try project.saveAll()
            progress?.finish()
            progress = nil
            ProjectLocations.remember(url)
            app.reloadLibrary()
            message = "Die Aufnahme liegt jetzt in deinen Projekten."
        } catch {
            progress = nil
            if let saved = try? await RecordingRecovery.recover(url) {
                ProjectLocations.remember(saved)
                app.reloadLibrary()
                message = "Die Aufnahme ließ sich nicht sauber beenden, der aufgenommene Teil ist gerettet. (\(error.localizedDescription))"
            } else {
                try? FileManager.default.removeItem(at: url)
                message = "Die Aufnahme ist fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }
}
