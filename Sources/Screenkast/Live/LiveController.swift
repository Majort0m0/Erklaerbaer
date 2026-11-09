import AppKit
import AVFoundation
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
    @Published var hearDevice: Bool { didSet { if hearDevice != oldValue, isDeviceSource { applySource() } } }
    @Published private(set) var isRecording = false
    @Published private(set) var recordingTime: TimeInterval = 0
    @Published private(set) var framesPerSecond = 0
    @Published var message: String?

    var isDeviceSource: Bool { if case .device = source { return true } else { return false } }

    init(app: AppModel) {
        self.app = app
        config = UserDefaults.standard.data(forKey: "liveConfig").flatMap { try? JSONDecoder().decode(LiveConfig.self, from: $0) } ?? LiveConfig()
        let savedCamera = UserDefaults.standard.string(forKey: "liveCameraID") ?? app.cameraID
        cameraID = app.cameras.contains { $0.uniqueID == savedCamera } ? savedCamera : (app.cameras.first?.uniqueID ?? "")
        let savedMic = UserDefaults.standard.string(forKey: "liveMicrophoneID") ?? app.microphoneID
        microphoneID = app.microphones.contains { $0.uniqueID == savedMic } ? savedMic : ""
        hearDevice = app.hearDevice
        super.init()
    }

    func begin() {
        engine.setBackground(url: backgroundFile)
        engine.setConfig(config)
        previewLayer.contentsGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        engine.onPresent = { [weak self] buffer in
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
        engine.start()
        if config.keys == true, KeyShortcuts.isTrusted(prompt: false) { engine.watchKeys(true) }
        program.onClose = { [weak self] in Task { @MainActor in await self?.end() } }
        program.show()
        showPanel()
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
        let host = NSHostingView(rootView: LiveControlView(live: self, app: app))
        host.sizingOptions = [.intrinsicContentSize]
        let size = host.fittingSize
        let rect = NSRect(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: rect, styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Erklärbär Live – Steuerung"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none   // never to be seen in the meeting, even when a whole screen is shared
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
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
            panel.animator().setFrame(open, display: true)
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
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Screenkast/Backgrounds", isDirectory: true)
        let target = folder.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            message = "Das Bild ließ sich nicht übernehmen: \(error.localizedDescription)"
            return
        }
        if let old = backgroundFile { try? FileManager.default.removeItem(at: old) }
        backgroundFile = target
        UserDefaults.standard.set(target.path, forKey: "liveBackground")
        engine.setBackground(url: target)
        config.background = true
    }

    func playMeme(_ slot: MemeSlot) {
        engine.playMeme(url: MemeBoard.shared.url(of: slot), duration: slot.duration, transparent: slot.transparent == true)
    }

    // MARK: Source

    private func applySource() {
        let previous = sourceTask
        let selection = source
        let hear = hearDevice
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
            let roles = try engine.startRecording(to: url.appendingPathComponent("screen.mov"), microphoneID: microphoneID.isEmpty ? nil : microphoneID)
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
            let duration = try await engine.stopRecording()
            let project = Project(url: url, info: Self.info(duration: duration, roles: recordingRoles), cursor: CursorTrack(), settings: ProjectFactory.plainSettings(aspect: .wide))
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
