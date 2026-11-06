import SwiftUI
import ScreenCaptureKit
import AVFoundation
import QuartzCore
import ServiceManagement

enum SourceSelection: Hashable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    /// Part of a display (rect in display points, origin top-left).
    case region(CGDirectDisplayID, CGRect)
}

extension CGRect: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(origin.x); hasher.combine(origin.y); hasher.combine(size.width); hasher.combine(size.height)
    }
}

@MainActor
final class AppModel: ObservableObject {
    // Sources
    @Published var displays: [SCDisplay] = []
    /// Windows on screen …
    @Published var windows: [SCWindow] = []
    /// … and the others (Stage Manager sets at the side, other desktops, hidden apps).
    @Published var otherWindows: [SCWindow] = []
    /// A second window recorded at the same time (shown as picture in picture in the editor).
    @Published var overlayWindowID: CGWindowID?
    /// Floating control bar (record, pause, source) that is never captured.
    @Published var showControlBar: Bool = UserDefaults.standard.bool(forKey: "showControlBar") {
        didSet {
            UserDefaults.standard.set(showControlBar, forKey: "showControlBar")
            updateControlBar()
        }
    }
    let controlBar = ControlBar()
    /// Always in the menu bar (not only while recording).
    @Published var showInMenuBar: Bool = UserDefaults.standard.bool(forKey: "showInMenuBar") {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar") }
    }
    /// Starts when logging in to the Mac (a login item).
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published var selection: SourceSelection?
    @Published var microphones: [AVCaptureDevice] = []
    /// "" = microphone off
    @Published var microphoneID: String = UserDefaults.standard.string(forKey: "microphoneID") ?? "" {
        didSet { UserDefaults.standard.set(microphoneID, forKey: "microphoneID") }
    }
    @Published var systemAudio: Bool = UserDefaults.standard.bool(forKey: "systemAudio") {
        didSet { UserDefaults.standard.set(systemAudio, forKey: "systemAudio") }
    }
    @Published var cameras: [AVCaptureDevice] = []
    /// "" = camera off
    @Published var cameraID: String = UserDefaults.standard.string(forKey: "cameraID") ?? "" {
        didSet {
            UserDefaults.standard.set(cameraID, forKey: "cameraID")
            if cameraID != oldValue { Task { await setCameraPreview(active: true) } }
        }
    }
    @Published var cameraDenied = false
    @Published var recordShortcuts: Bool = UserDefaults.standard.bool(forKey: "recordShortcuts") {
        didSet {
            UserDefaults.standard.set(recordShortcuts, forKey: "recordShortcuts")
            if recordShortcuts { shortcutsTrusted = KeyShortcuts.isTrusted(prompt: true) }
        }
    }
    @Published var shortcutsTrusted = KeyShortcuts.isTrusted(prompt: false)
    /// 3-2-1 before the recording starts.
    @Published var countdown: Bool = UserDefaults.standard.object(forKey: "countdown") as? Bool ?? true {
        didSet { UserDefaults.standard.set(countdown, forKey: "countdown") }
    }
    /// Speaker notes shown in a floating window while recording.
    @Published var notes: String = UserDefaults.standard.string(forKey: "speakerNotes") ?? "" {
        didSet { UserDefaults.standard.set(notes, forKey: "speakerNotes") }
    }
    @Published var showNotes: Bool = UserDefaults.standard.bool(forKey: "showNotes") {
        didSet { UserDefaults.standard.set(showNotes, forKey: "showNotes") }
    }
    let notesPanel = NotesPanel()
    @Published var permissionProblem: String?
    /// Granted while the app was running: the capture works only after a restart.
    @Published var permissionGrantedNeedsRestart = false

    // Recording state
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var isBusy = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var errorMessage: String?
    /// A new project from an own video or an empty one is being created.
    @Published var creatingProject = false

    // Library / editor
    @Published var library: [URL] = []
    @Published var editor: EditorModel?

    private var shareable: SCShareableContent?
    private let recorder = ScreenRecorder()
    private let pauseGate = PauseGate()
    let camera = CameraRecorder()
    private let cameraPanel = FloatingCameraPanel()
    private var cameraPreviewWanted = false
    private let tracker = CursorTracker()
    private let windowRecorder = WindowRecorder()
    private var overlayWindowName: String?
    private var barHoverHost: Double?
    fileprivate var permissionTimer: Timer?
    /// Saves a stack sample if the app freezes during a recording.
    private let watchdog = HangWatchdog()
    /// Crash safety: recording info and cursor track saved every 2 s during a recording.
    private var progressWriter: RecordingProgressWriter?
    private var progressTimer: Timer?
    private var currentURL: URL?
    private var currentTarget: CaptureTarget?
    private var geometry: CaptureGeometry?
    private var firstHost: Double = 0
    private var menuOpenedHost: Double?
    /// Recording times at which a pause started (menu bar clicks right before them are dropped).
    private var pauseMarks: [Double] = []
    private var elapsedTimer: Timer?
    private var hotKey: GlobalHotKey?
    private var screenshotHotKey: GlobalHotKey?
    private var hiddenWindows: [NSWindow] = []

    /// Snapshot of the start page (`--uisnapshot home`): no hot keys, no recovery.
    nonisolated(unsafe) static var snapshotMode = false

    init() {
        if Self.snapshotMode {
            reloadLibrary()
            return
        }
        hotKey = GlobalHotKey { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }
        screenshotHotKey = GlobalHotKey(keyCode: GlobalHotKey.screenshotKeyCode, id: 2) { [weak self] in
            Task { @MainActor in
                guard let self, !self.isRecording else { return }
                await self.takeScreenshot(.region)
            }
        }
        recorder.pauseGate = pauseGate
        camera.pauseGate = pauseGate
        tracker.pauseGate = pauseGate
        windowRecorder.pauseGate = pauseGate
        recorder.onStreamError = { [weak self] error in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.errorMessage = "Aufnahme unterbrochen: \(error.localizedDescription)"
                await self.stopRecording()
            }
        }
        reloadLibrary()
        Task { await recoverInterruptedRecordings() }
    }

    /// Turns recordings that were interrupted by a crash or force quit into normal projects.
    private func recoverInterruptedRecordings() async {
        let result = await RecordingRecovery.recoverAll()
        guard !result.recovered.isEmpty || !result.failed.isEmpty else { return }
        reloadLibrary()
        var lines: [String] = []
        if result.recovered.count == 1 {
            lines.append("Eine abgebrochene Aufnahme wurde wiederhergestellt („wiederhergestellt“ im Namen).")
        } else if result.recovered.count > 1 {
            lines.append("\(result.recovered.count) abgebrochene Aufnahmen wurden wiederhergestellt („wiederhergestellt“ im Namen).")
        }
        if !result.failed.isEmpty {
            lines.append("Nicht wiederherstellbar (zu kurz oder beschädigt): " + result.failed.map { $0.deletingPathExtension().lastPathComponent }.joined(separator: ", "))
        }
        errorMessage = lines.joined(separator: "\n\n")
    }

    // MARK: Sources

    func refreshSources() async {
        do {
            // All windows, not only those on screen: with Stage Manager the windows of the other
            // sets count as off screen.
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            shareable = content
            permissionProblem = nil
            permissionTimer?.invalidate()
            permissionTimer = nil
            displays = content.displays
            let myPID = ProcessInfo.processInfo.processIdentifier
            let usable = content.windows.filter { w in
                w.windowLayer == 0 && w.frame.width >= 120 && w.frame.height >= 80 &&
                w.owningApplication?.processID != myPID &&
                !(w.title ?? "").isEmpty
            }
            .sorted { (($0.owningApplication?.applicationName ?? ""), $0.title ?? "") < (($1.owningApplication?.applicationName ?? ""), $1.title ?? "") }
            windows = usable.filter(\.isOnScreen)
            otherWindows = usable.filter { !$0.isOnScreen }
            if let id = overlayWindowID, !usable.contains(where: { $0.windowID == id }) { overlayWindowID = nil }
            if selection == nil || !isSelectionValid {
                if let main = displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? displays.first {
                    selection = .display(main.displayID)
                }
            }
        } catch {
            permissionProblem = "Erklärbär braucht die Berechtigung „Bildschirm- und Systemaudioaufnahme“. Bitte in Systemeinstellungen › Datenschutz & Sicherheit erlauben."
            watchPermission()
        }
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                       mediaType: .audio, position: .unspecified).devices
        if !microphoneID.isEmpty && !microphones.contains(where: { $0.uniqueID == microphoneID }) {
            microphoneID = ""
        }
        cameras = CameraRecorder.availableDevices()
        if !cameraID.isEmpty && !cameras.contains(where: { $0.uniqueID == cameraID }) {
            cameraID = ""
        }
    }

    private var isSelectionValid: Bool {
        switch selection {
        case .display(let id): return displays.contains { $0.displayID == id }
        case .window(let id): return (windows + otherWindows).contains { $0.windowID == id }
        case .region(let id, _): return displays.contains { $0.displayID == id }
        case nil: return false
        }
    }

    private func target(for selection: SourceSelection?) -> CaptureTarget? {
        switch selection {
        case .display(let id): return displays.first { $0.displayID == id }.map(CaptureTarget.display)
        case .window(let id): return (windows + otherWindows).first { $0.windowID == id }.map(CaptureTarget.window)
        case .region(let id, let rect): return displays.first { $0.displayID == id }.map { CaptureTarget.region($0, rect) }
        case nil: return nil
        }
    }

    func displayName(_ d: SCDisplay) -> String {
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID }
        return "\(screen?.localizedName ?? "Bildschirm") (\(d.width)×\(d.height))"
    }

    func windowName(_ w: SCWindow) -> String {
        let app = w.owningApplication?.applicationName ?? "?"
        let title = w.title ?? ""
        return title.isEmpty ? app : "\(app) – \(title)"
    }

    // MARK: Camera

    /// Runs the camera for the live preview (home screen) or stops it to free the device.
    func setCameraPreview(active: Bool) async {
        cameraPreviewWanted = active
        guard !isRecording, !Self.snapshotMode else { return }
        if active && !cameraID.isEmpty {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraDenied = !granted
            camera.select(deviceID: granted ? cameraID : nil)
        } else {
            camera.select(deviceID: nil)
        }
    }

    // MARK: Recording

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else if !isBusy {
            Task { await startRecording() }
        }
    }

    func startRecording() async {
        guard !isRecording, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil

        await refreshSources()
        guard let chosen = target(for: selection), let content = shareable else {
            errorMessage = permissionProblem ?? "Bitte eine Aufnahmequelle auswählen."
            return
        }
        if !microphoneID.isEmpty {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                errorMessage = "Kein Zugriff aufs Mikrofon – die Aufnahme läuft ohne Ton."
                microphoneID = ""
            }
        }

        var useCamera = !cameraID.isEmpty
        if useCamera {
            if await AVCaptureDevice.requestAccess(for: .video) {
                camera.select(deviceID: cameraID)
            } else {
                cameraDenied = true
                useCamera = false
                errorMessage = "Kein Zugriff auf die Kamera – die Aufnahme läuft ohne Kamera."
            }
        }

        // Close the editor and get our windows out of the way.
        editor?.pause()
        editor = nil
        hiddenWindows = NSApp.windows.filter { $0.isVisible && $0.level == .normal && $0.canBecomeMain }
        hiddenWindows.forEach { $0.orderOut(nil) }
        // A recorded window comes to the front (in Stage Manager: its set moves to the center).
        // Its frame changes then, so the sources are read again afterwards.
        var target = chosen
        var overlayWindow = overlayWindowID.flatMap { id in (windows + otherWindows).first { $0.windowID == id } }
        if case .window(let w) = target, overlayWindow?.windowID == w.windowID { overlayWindow = nil }
        if overlayWindow != nil || { if case .window = target { return true } else { return false } }() {
            if let overlayWindow { WindowFocus.bringToFront(overlayWindow) }
            if case .window(let w) = target { WindowFocus.bringToFront(w) }
            try? await Task.sleep(for: .milliseconds(700))
            await refreshSources()
            if let fresh = self.target(for: selection) { target = fresh }
            overlayWindow = overlayWindow.flatMap { o in (windows + otherWindows).first { $0.windowID == o.windowID } }
        } else {
            try? await Task.sleep(for: .milliseconds(350))
        }

        if countdown {
            let display: CGDirectDisplayID? = switch target {
            case .display(let d), .region(let d, _): d.displayID
            case .window: nil
            }
            await Countdown.run(on: display)
        }

        let url = Project.makeNewProjectURL()
        pauseGate.reset()
        pauseMarks = []
        isPaused = false
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let (geo, host) = try await recorder.start(target: target,
                                                      microphoneID: microphoneID.isEmpty ? nil : microphoneID,
                                                      systemAudio: systemAudio,
                                                      excludedApps: ownApps,
                                                      outputURL: url.appendingPathComponent("screen.mov"))
            if useCamera {
                cameraPanel.show(session: camera.session)
                try? camera.startWriting(to: url.appendingPathComponent("camera.mov"),
                                         start: CMTime(seconds: host, preferredTimescale: 1_000_000_000))
            }
            overlayWindowName = nil
            if let overlayWindow {
                do {
                    try await windowRecorder.start(window: overlayWindow, url: url.appendingPathComponent("window2.mov"),
                                                   start: CMTime(seconds: host, preferredTimescale: 1_000_000_000))
                    overlayWindowName = windowName(overlayWindow)
                } catch {
                    errorMessage = "Das zweite Fenster konnte nicht aufgenommen werden: \(error.localizedDescription)"
                }
            }
            currentURL = url
            currentTarget = target
            if showNotes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let display: CGDirectDisplayID? = switch target {
                case .display(let d), .region(let d, _): d.displayID
                case .window: nil
                }
                notesPanel.show(text: notes, on: display)
            }
            geometry = geo
            firstHost = host
            menuOpenedHost = nil
            tracker.recordShortcuts = recordShortcuts && KeyShortcuts.isTrusted(prompt: false)
            tracker.start(rect: geo.frame, hostStart: host)
            let progressInfo = RecordingInfo(pixelWidth: Int(geo.pixelSize.width), pixelHeight: Int(geo.pixelSize.height),
                                             pointPixelScale: geo.pointPixelScale, duration: 0, createdAt: Date(),
                                             sourceName: target.name,
                                             hasMicrophone: recorder.audioTrackRoles.contains("mic"),
                                             cameraFile: useCamera ? "camera.mov" : nil,
                                             audioTracks: recorder.audioTrackRoles)
            progressWriter = try? RecordingProgressWriter(folder: url, info: progressInfo)
            updateControlBar()
            let saveTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let writer = self.progressWriter else { return }
                    let (track, images) = self.tracker.snapshot()
                    writer.save(cursor: track, images: images)
                }
            }
            RunLoop.main.add(saveTimer, forMode: .common)
            progressTimer = saveTimer
            isRecording = true
            watchdog.start()
            elapsed = 0
            elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.elapsed = self.pauseGate.recordingTime(at: CACurrentMediaTime()) - self.firstHost
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            errorMessage = error.localizedDescription
            showMainWindow()
        }
    }

    /// Pauses or resumes all streams (screen, audio, camera, cursor) at the same host time.
    func togglePause() {
        guard isRecording else { return }
        let now = CACurrentMediaTime()
        if pauseGate.isPaused {
            pauseGate.resume(at: now)
            isPaused = false
            menuOpenedHost = nil   // the click on "Fortsetzen" is not a stop gesture
        } else {
            pauseGate.pause(at: now)
            pauseMarks.append(pauseGate.recordingTime(at: now) - firstHost)
            isPaused = true
        }
        elapsed = pauseGate.recordingTime(at: now) - firstHost
    }

    /// Called when the menu bar panel opens; clicks after this point belong to stopping.
    func menuOpened() {
        if isRecording { menuOpenedHost = CACurrentMediaTime() }
    }

    /// The mouse is over the control bar (it moves there to stop: that part is cut away).
    func controlBarHover(_ inside: Bool) {
        guard isRecording else { return }
        barHoverHost = inside ? CACurrentMediaTime() : nil
    }

    func stopRecording(fromControlBar: Bool = false) async {
        guard isRecording, let url = currentURL, let geo = geometry, let target = currentTarget else { return }
        if fromControlBar, let host = barHoverHost { menuOpenedHost = host }
        isRecording = false
        watchdog.stop()
        isBusy = true
        defer { isBusy = false }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        progressTimer?.invalidate()
        progressTimer = nil
        // Pending progress saves must not overwrite the final cursor.json written below.
        progressWriter?.flush()

        let menuTime = menuOpenedHost.map { pauseGate.recordingTime(at: $0) - firstHost }
        isPaused = false
        var (track, pngs) = tracker.stop()
        let cameraEnd = CMTime(seconds: pauseGate.recordingTime(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds),
                               preferredTimescale: 1_000_000_000)
        let cameraOK = await camera.stopWriting(end: cameraEnd)
        let windowOK = overlayWindowName != nil ? await windowRecorder.stop(end: cameraEnd) : false
        let windowSize = windowRecorder.size
        cameraPanel.hide()
        notesPanel.hide()
        updateControlBar()
        if !cameraPreviewWanted { camera.select(deviceID: nil) }
        do {
            let duration = try await recorder.stop()

            // Cut away the part where the user reached for the stop button in the menu bar.
            var cut: Double?
            if let menuTime { cut = menuTime - 0.25 }
            let menuBarFraction = 40.0 / max(1, geo.frame.height)
            for click in track.clicks where click.t > duration - 4 {
                let inMenuBar = (click.y < menuBarFraction && { if case .display = target { return true } else { return false } }()) || !click.isInsideCapture
                if inMenuBar { cut = min(cut ?? .infinity, click.t - 0.25) }
            }
            if let c = cut {
                track.clicks.removeAll { $0.t >= c }
            }
            // Clicks on the menu bar icon right before pausing are not part of the demo.
            let isDisplay: Bool = { if case .display = target { return true } else { return false } }()
            track.clicks.removeAll { click in
                let inMenuBar = (isDisplay && click.y < menuBarFraction) || !click.isInsideCapture
                return inMenuBar && pauseMarks.contains { click.t <= $0 + 0.05 && click.t > $0 - 3 }
            }

            let fm = FileManager.default
            if !pngs.isEmpty {
                try fm.createDirectory(at: url.appendingPathComponent("cursors"), withIntermediateDirectories: true)
                for (i, png) in pngs.enumerated() {
                    try png.write(to: url.appendingPathComponent(track.images[i].file))
                }
            }
            var info = RecordingInfo(pixelWidth: Int(geo.pixelSize.width), pixelHeight: Int(geo.pixelSize.height),
                                     pointPixelScale: geo.pointPixelScale, duration: duration, createdAt: Date(),
                                     sourceName: target.name,
                                     hasMicrophone: recorder.audioTrackRoles.contains("mic"),
                                     cameraFile: cameraOK ? "camera.mov" : nil,
                                     audioTracks: recorder.audioTrackRoles)
            if windowOK {
                info.overlayVideoFile = "window2.mov"
                info.overlaySourceName = overlayWindowName
                info.overlayAspect = windowSize.height > 0 ? windowSize.width / windowSize.height : nil
            }
            var settings = EditSettings()
            if let c = cut, c > 1, c < duration { settings.trimEnd = c }
            settings.zoomSegments = AutoZoom.segments(for: track.clicks, duration: duration, scale: settings.defaultZoom)
            let project = Project(url: url, info: info, cursor: track, settings: settings)
            try project.saveAll()
            progressWriter?.finish()
            progressWriter = nil
            reloadLibrary()
            showMainWindow()
            open(project: project)
            // Start assistant: what to make, polish in one go.
            if UserDefaults.standard.object(forKey: "showAssistant") as? Bool ?? true { editor?.showPolishSheet = true }
        } catch {
            errorMessage = error.localizedDescription
            progressWriter = nil
            try? FileManager.default.removeItem(at: url)
            showMainWindow()
        }
        currentURL = nil
        currentTarget = nil
        geometry = nil
    }

    func cancelRecording() async {
        guard isRecording else { return }
        isRecording = false
        watchdog.stop()
        isPaused = false
        elapsedTimer?.invalidate()
        progressTimer?.invalidate()
        progressTimer = nil
        progressWriter?.flush()   // no late write may recreate the deleted folder
        progressWriter = nil
        _ = tracker.stop()
        camera.cancelWriting()
        cameraPanel.hide()
        notesPanel.hide()
        await windowRecorder.cancel()
        await recorder.cancel()
        updateControlBar()
        if let url = currentURL { try? FileManager.default.removeItem(at: url) }
        currentURL = nil
        showMainWindow()
    }

    // MARK: Library

    func reloadLibrary() {
        library = Project.listLibrary()
    }

    func open(url: URL) {
        do {
            open(project: try Project.load(from: url))
        } catch {
            errorMessage = "Projekt konnte nicht geöffnet werden: \(error.localizedDescription)"
        }
    }

    func open(project: Project) {
        editor?.pause()
        let e = EditorModel(project: project)
        e.openProject = { [weak self] url in self?.open(url: url) }
        editor = e
    }

    func closeEditor() {
        editor?.pause()
        editor?.saveNow()
        editor = nil
        reloadLibrary()
    }

    func delete(url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reloadLibrary()
    }

    func showMainWindow() {
        NSApp.activate()
        let windows = hiddenWindows.isEmpty ? NSApp.windows.filter { $0.canBecomeMain } : hiddenWindows
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
        hiddenWindows = []
    }
}

extension AppModel {
    /// Lets the user drag a region on the selected (or main) display and selects it.
    func chooseRegion() async {
        await refreshSources()
        let current: (CGDirectDisplayID, CGRect?)? = switch selection {
        case .display(let id): (id, nil)
        case .region(let id, let r): (id, r)
        default: displays.first.map { ($0.displayID, nil) }
        }
        guard let (displayID, initial) = current else { return }
        let hidden = NSApp.windows.filter { $0.isVisible && $0.level == .normal }
        hidden.forEach { $0.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(200))
        let rect = await RegionSelector.select(on: displayID, initial: initial)
        hidden.forEach { $0.makeKeyAndOrderFront(nil) }
        if let rect {
            selection = .region(displayID, rect)
            UserDefaults.standard.set(NSStringFromRect(rect), forKey: "lastRegion")
        }
    }

    func regionName(_ id: CGDirectDisplayID, _ rect: CGRect) -> String {
        let display = displays.first { $0.displayID == id }.map(displayName) ?? "Bildschirm"
        return "Bereich \(Int(rect.width))×\(Int(rect.height)) auf \(display)"
    }
}

// MARK: - Permission, control bar

extension AppModel {
    /// While the screen recording permission is missing: check every 1.5 s, so the hint goes away
    /// as soon as it is granted.
    func watchPermission() {
        guard permissionTimer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.permissionProblem != nil else { return }
                if CGPreflightScreenCaptureAccess() {
                    self.permissionProblem = nil
                    self.permissionGrantedNeedsRestart = true
                    self.permissionTimer?.invalidate()
                    self.permissionTimer = nil
                    Task { await self.refreshSources() }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    /// Starts a new instance and quits this one (macOS applies a new screen permission only then;
    /// its permission dialog closes with it).
    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        let url = Bundle.main.bundleURL
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func updateControlBar() {
        if showControlBar || isRecording && controlBar.isVisible {
            controlBar.show(model: self)
        } else {
            controlBar.hide()
        }
    }
}

// MARK: - Login item

extension AppModel {
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Start beim Anmelden ließ sich nicht \(on ? "einschalten" : "ausschalten"): \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if on, SMAppService.mainApp.status == .requiresApproval {
            errorMessage = "macOS fragt nach: Bitte in Systemeinstellungen › Allgemein › Anmeldeobjekte Erklärbär erlauben."
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
