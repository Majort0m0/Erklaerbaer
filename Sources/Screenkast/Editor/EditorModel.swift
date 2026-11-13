import SwiftUI
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// What is selected in the timeline (one thing at a time). `segment`: the part of the recording
/// between two split points that starts at this source time.
enum EditorSelection: Equatable {
    case zoom(UUID), cut(UUID), mask(UUID), mute(UUID), voiceOver(UUID), text(UUID), segment(Double), join(Double), freeze(UUID)
    case cameraLayout(UUID), annotation(UUID), image(UUID), insert(UUID), chapter(UUID), videoOverlay(UUID), cursorRange(UUID)
    /// A whole audio lane (volume, enhancement, cutting it into ranges).
    case audioLane(AudioLane)
    /// A lane or a part of the picture without its own item (camera, captions, logo …): its settings.
    case panel(EditorPanel)
}

/// Settings opened by clicking a lane header or an element in the preview.
enum EditorPanel: String, CaseIterable {
    case video, camera, cursor, zoom, masks, annotations, texts, media, captions, logo

    var title: String {
        switch self {
        case .video: return "Aufnahme"
        case .camera: return "Kamera"
        case .cursor: return "Cursor"
        case .zoom: return "Zoom"
        case .masks: return "Masken"
        case .annotations: return "Markierungen"
        case .texts: return "Texte"
        case .media: return "Medien"
        case .captions: return "Untertitel"
        case .logo: return "Logo"
        }
    }

    var icon: String {
        switch self {
        case .video: return "film"
        case .camera: return "web.camera"
        case .cursor: return "cursorarrow.rays"
        case .zoom: return "plus.magnifyingglass"
        case .masks: return "square.grid.3x3"
        case .annotations: return "arrow.up.right"
        case .texts: return "textformat"
        case .media: return "photo.on.rectangle.angled"
        case .captions: return "captions.bubble"
        case .logo: return "seal"
        }
    }
}

/// Pages of the inspector when nothing is selected.
enum InspectorTab: String, CaseIterable, Identifiable {
    case style, camera, cursor, zoom, audio, text, media, transcript
    var id: String { rawValue }

    var title: String {
        switch self {
        case .style: return "Stil"
        case .camera: return "Kamera"
        case .cursor: return "Cursor"
        case .zoom: return "Zoom"
        case .audio: return "Audio"
        case .text: return "Text"
        case .media: return "Medien"
        case .transcript: return "Skript"
        }
    }

    var icon: String {
        switch self {
        case .style: return "paintpalette"
        case .camera: return "web.camera"
        case .cursor: return "cursorarrow"
        case .zoom: return "plus.magnifyingglass"
        case .audio: return "speaker.wave.2"
        case .text: return "textformat"
        case .media: return "photo.on.rectangle.angled"
        case .transcript: return "text.quote"
        }
    }

    var help: String {
        switch self {
        case .style: return "Vorlage, Hintergrund, Format, Rahmen und Farbkorrektur"
        case .camera: return "Kamerablase"
        case .cursor: return "Cursor, Klicks und Tastenkürzel"
        case .zoom: return "Auto-Zoom und Bewegungsunschärfe"
        case .audio: return "Mischpult, Stimme, Musik, Voice-over, Echo"
        case .text: return "Bauchbinden, Titelkarten, Designs, Kapitel und Untertitel"
        case .media: return "Bilder, Videos (Bild im Bild oder eingefügt) und Logo"
        case .transcript: return "Schneiden über den Text, Füllwörter und Pausen entfernen"
        }
    }
}

/// Where the mouse hovers over an empty timeline lane (ghost block to add an item there).
/// Kept outside the published editor state, so moving the mouse redraws only the ghost.
final class TimelineHover: ObservableObject {
    enum Lane { case zoom, mask, text, annotation, camera, media, cursor }
    @Published var lane: Lane?
    @Published var range: ClosedRange<Double> = 0...0
}

/// Editor state. Times are source times of the recording (0…duration); the intro title card
/// lies before 0 (−introLead…0) and the outro after `duration`. An intro/outro pushed over the
/// recording (cross dissolve) only takes the rest of its length outside.
@MainActor
final class EditorModel: ObservableObject {
    let project: Project
    let renderer: FrameRenderer
    let player = AVPlayer()

    @Published var settings: EditSettings {
        didSet { settingsChanged(from: oldValue) }
    }
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var selection: EditorSelection? {
        didSet {
            // A click on anything outside the group ends the group.
            if !multiSelection.isEmpty, selection.map({ !multiSelection.contains($0) }) ?? true { multiSelection = [] }
            if selection != oldValue, multiSelection.isEmpty { revealSelection() }
        }
    }
    @Published var inspectorTab: InspectorTab = .style

    // Voice enhancement, pauses, transcript
    enum VoiceState: Equatable { case idle, processing, ready(VoiceProcessor.Result?), failed(String) }
    @Published var voiceState: VoiceState = .idle
    @Published var pauseOptions = PauseDetector.Options()
    /// Words selected in the transcript (indices into `settings.words`).
    @Published var transcriptSelection: ClosedRange<Int>?
    /// Where someone speaks on the microphone (source time; music ducks there).
    private(set) var speechRanges: [ClosedRange<Double>] = []
    @Published var gifProgress: Double?
    @Published var levelState: LevelState = .idle
    @Published var aiState: AIState = .idle
    @Published var aiSuggestions: AISuggestions?
    @Published var polishState: PolishState = .idle
    @Published var showPolishSheet = false
    @Published var showPalette = false
    @Published var showSpeechSheet = false
    @Published var showAISheet = false
    @Published var showSensitiveSheet = false
    @Published var breathState: String?
    var breathTask: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?
    /// Export or import of the voice running / its result.
    @Published var isExchangingVoice = false
    @Published var voiceExchangeStatus: String?
    @Published var showGuideSheet = false
    /// Fewer lanes and controls (masks and markings appear once they are used).
    @Published var simpleMode: Bool = UserDefaults.standard.bool(forKey: "simpleMode") {
        didSet { UserDefaults.standard.set(simpleMode, forKey: "simpleMode") }
    }
    /// Opens another project (a clip made from this one).
    var openProject: ((URL) -> Void)?
    /// Renames this project (closes and reopens it; set by the app).
    var renameProject: (() -> Void)?
    /// Loudness of the last export when it was brought to the target.
    @Published var masterResult: AudioMastering.MasterResult?
    var annotationDragOrigin: Annotation?
    var imageDragOrigin: ImageOverlay?
    var cameraLayoutDragOrigin: CameraLayoutRange?
    var chapterDragOrigin: Chapter?
    var videoOverlayDragOrigin: VideoOverlay?
    var cursorRangeDragOrigin: CursorRange?
    @Published var showShortcutHelp = false
    @Published var showMemeBoard = false
    /// What dragging a part's edge or body does.
    @Published var trimMode: TrimMode = .normal
    var rollOrigin: RollOrigin?
    var slipOrigin: RollOrigin?
    /// The mask being followed, and a message about it.
    @Published var trackingMask: UUID?
    @Published var maskMessage: String?
    /// The rectangle being dragged in the timeline to select several things.
    @Published var marquee: CGRect?
    /// Teleprompter while speaking a voice-over.
    let prompter = NotesPanel()
    /// Bumped when the library of the project changes.
    @Published var libraryVersion = 0
    let timelineHover = TimelineHover()

    // Undo / redo of the edit settings. Changes in quick succession (typing, a slider or
    // timeline drag) form one step.
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var undoStack: [EditSettings] = []
    private var redoStack: [EditSettings] = []
    private var undoBurstStart: EditSettings?
    private var undoBurstTask: Task<Void, Never>?
    private var applyingUndo = false

    /// Timeline edges snap to the playhead, split points and other items.
    /// Clips on a lane pull together at their ends when dragged near each other.
    @Published var magnet: Bool = UserDefaults.standard.object(forKey: "timelineMagnet") as? Bool ?? true {
        didSet { UserDefaults.standard.set(magnet, forKey: "timelineMagnet") }
    }
    @Published var snapping: Bool = UserDefaults.standard.object(forKey: "timelineSnapping") as? Bool ?? true {
        didSet { UserDefaults.standard.set(snapping, forKey: "timelineSnapping") }
    }
    /// Time where the dragged edge snapped (drawn as a guide line).
    @Published var snapGuide: Double?
    /// A dragged lower third snapped to the horizontal center of the video.
    @Published var textCenterGuide = false

    /// Item state at the beginning of a drag (timeline or preview).
    var maskDragOrigin: BlurMask?
    var cutDragOrigin: CutRange?
    var zoomDragOrigin: ZoomSegment?
    var muteDragOrigin: AudioMute?
    var voiceOverDragOrigin: VoiceOverClip?
    var textDragOrigin: TextOverlay?
    @Published var loadError: String?

    @Published var isExporting = false
    @Published var showExportSheet = false
    /// The YouTube upload helper (title, description, chapters, captions, picture, exported video).
    @Published var showYouTubeSheet = false
    /// The export was started from the YouTube helper: afterwards it leads back there.
    @Published var exportForYouTube = false
    /// Sheet to open once the current one has closed (sheets cannot be stacked).
    var nextSheet: EditorSheet?
    /// "Von einer Adresse laden" (media library).
    @Published var showURLImport = false
    /// A problem with the media library (shown below it).
    @Published var libraryMessage: String?
    enum EchoState: Equatable {
        case notNeeded, processing, ready(EchoCanceller.Stats?), failed(String)
    }
    @Published var echoState: EchoState = .notNeeded
    @Published var captionStatus: String?
    @Published var captionError: String?
    @Published var isGeneratingCaptions = false
    @Published var exportProgress: Double = 0
    @Published var exportResult: URL?
    @Published var exportError: String?

    /// Waveform peaks (100 per second): "mic", "system" (recording time) and voice-over files (file time).
    @Published var waveforms: [String: [Float]] = [:] {
        didSet {
            for (key, peaks) in waveforms where waveformPeaks[key] == nil {
                waveformPeaks[key] = peaks.max() ?? 0
            }
        }
    }
    /// Loudest peak per waveform (the timeline scales each waveform to it).
    var waveformPeaks: [String: Float] = [:]

    // Timeline zoom
    /// Visible length of the timeline in seconds (nil = everything fits).
    @Published var zoomSpan: Double?
    /// Timeline time at the left edge while zoomed in.
    @Published var scrollStart: Double = 0
    /// Width of the timeline lanes in points (set by the timeline view).
    var timelineWidth: CGFloat = 900
    /// Closest zoom: this many points per second.
    static let maxPointsPerSecond = 800.0

    /// True while the user drags something in the timeline. Changes that need a new
    /// composition wait for the end of the drag (rebuilding on every mouse move made it jerky).
    private(set) var isInteracting = false
    /// Visible part of the timeline (start, span) kept during a drag.
    var frozenViewport: (start: Double, span: Double)?
    private var rebuildPending = false
    private var buildGeneration = 0
    private var seekInFlight = false
    private var pendingSeek: Double?

    /// Height of the timeline area (resizable, remembered).
    @Published var timelineHeight: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "timelineHeight")
        return saved > 0 ? CGFloat(saved) : 360
    }() {
        didSet { UserDefaults.standard.set(Double(timelineHeight), forKey: "timelineHeight") }
    }

    // Voice-over recording
    enum VoiceOverState: Equatable {
        case idle, countdown(Int), recording, saving
    }
    @Published var voiceOverState: VoiceOverState = .idle {
        didSet { if voiceOverState == .idle { prompter.hide() } }
    }
    @Published var voiceOverLevel: Float = 0
    @Published var voiceOverError: String?
    /// Hear the video while narrating (only with headphones, otherwise it is recorded too).
    @Published var monitorWhileNarrating: Bool = UserDefaults.standard.bool(forKey: "voiceOverMonitor") {
        didSet { UserDefaults.standard.set(monitorWhileNarrating, forKey: "voiceOverMonitor") }
    }
    private var voiceOverRecorder: VoiceOverRecorder?
    private var voiceOverFile: String?
    /// Continuous playback stretches while narrating; a new one starts at every jump over a cut.
    private struct NarrationSpan {
        var hostStart: Double
        var anchorHost: Double?
        var anchorSource: Double?
    }
    private var narrationSpans: [NarrationSpan] = []
    private var narrationAnchorAllowed = false
    private var levelTimer: Timer?

    private var media: MediaComposition?
    private var timeObserver: Any?
    private var saveTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastRefresh: CFTimeInterval = 0
    private var exportSession: AVAssetExportSession?

    var duration: Double { project.info.duration }
    var hasCamera: Bool { project.cameraURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    var trimEnd: Double { min(settings.trimEnd ?? duration, duration) }
    /// Time the intro/outro plays before/after the recording (without the part pushed over it).
    var introLead: Double { settings.introLead(duration: duration) }
    var outroLead: Double { settings.outroLead(duration: duration) }
    /// Start and end of the timeline including intro and outro.
    var timelineStart: Double { -introLead }
    var timelineEnd: Double { duration + outroLead }
    /// Composition time of source time 0 in the current player item (= intro length when it was built).
    private var playerOffset: Double { media?.recordingOffset ?? settings.introLead(duration: duration) }

    /// Source time ↔ timeline time (speed changes, freeze frames). `currentTime` and all items are
    /// in source time; the player, the timeline view and the zoom work in timeline time.
    private(set) var timeMap: TimeMap
    func display(_ source: Double) -> Double { timeMap.timeline(source) }
    func sourceTime(_ timeline: Double) -> Double { timeMap.source(timeline) }
    /// Timeline stretch of a source range (first unbroken part; nil if it was cut away).
    func displayRun(_ start: Double, _ end: Double) -> ClosedRange<Double>? { timeMap.run(start, end) }
    /// Timeline range of the edited timeline (intro … outro).
    var displayStart: Double { -introLead }
    var displayEnd: Double { timeMap.total + outroLead }

    init(project: Project) {
        self.project = project
        self.settings = project.settings
        self.renderer = FrameRenderer(project: project)
        self.timeMap = project.settings.editMap(duration: project.info.duration)
        Task { await setup() }
    }

    private func setup() async {
        if let url = project.cameraURL, let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), size.height > 0 {
            cameraAspect = size.width / size.height
        }
        addSyncedOverlayIfNeeded()
        migrateAutomaticCuts()
        await buildPlayerItem()
        prepareEchoRemoval()
        loadWaveforms()
        if settings.voice.enabled { prepareVoice() }
        // Breath reduction from before breaths became ranges: find them now.
        if settings.voice.reducesBreaths, breathRegions.isEmpty { await detectBreathRegions() }
    }

    /// Cuts from before automatic cuts were marked: one that spans exactly a recognized word (±30 ms)
    /// came from removing filler words, one in a gap between words from shortening pauses. They get
    /// their label and the soft sound crossfade (not an undo step).
    private func migrateAutomaticCuts() {
        guard !settings.words.isEmpty, settings.cuts.contains(where: { $0.origin == nil }) else { return }
        var s = settings
        for i in s.cuts.indices where s.cuts[i].origin == nil && s.cuts[i].dissolve == 0 {
            let c = s.cuts[i]
            let overlapping = s.words.filter { (c.start...c.end).contains(($0.start + $0.end) / 2) }
            if overlapping.count == 1, let w = overlapping.first, abs(c.start - max(0, w.start - 0.03)) < 0.006, abs(c.end - (w.end + 0.03)) < 0.006 {
                s.cuts[i].origin = .filler
            } else if overlapping.isEmpty, c.end - c.start > 0.15 {
                s.cuts[i].origin = .pause
            } else {
                continue
            }
            s.cuts[i].dissolve = CutRange.speechCrossfade
        }
        guard s != settings else { return }
        applyingUndo = true
        settings = s
        applyingUndo = false
    }

    /// (Re)builds the composition and player item, keeping the playhead.
    private func buildPlayerItem() async {
        buildGeneration += 1
        let generation = buildGeneration
        do {
            project.settings = settings
            let media = try await MediaBuilder.make(project: project, renderer: renderer, fps: 60, speech: speechRanges)
            // A newer build started meanwhile (settings changed again): keep only the newest.
            guard generation == buildGeneration else { return }
            let time = currentTime
            let wasPlaying = isPlaying
            pause()
            self.media = media
            let item = AVPlayerItem(asset: media.asset)
            item.audioTimePitchAlgorithm = .spectral   // speed changes keep the pitch
            item.audioMix = media.audioMix(settings: settings)
            item.videoComposition = media.videoComposition(renderSize: renderer.outputSize, fps: 60)
            seekInFlight = false
            pendingSeek = nil
            player.replaceCurrentItem(with: item)
            player.actionAtItemEnd = .pause
            if timeObserver == nil {
                timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                    MainActor.assumeIsolated { self?.tick(time.seconds) }
                }
                seek(to: timeMap.source(0))
            } else {
                seek(to: time)
                if wasPlaying { play() }
            }
        } catch {
            guard generation == buildGeneration else { return }
            loadError = "Video konnte nicht geladen werden: \(error.localizedDescription)"
        }
    }

    /// Width/height of the camera video (for the drag overlay of rectangular bubbles).
    @Published var cameraAspect: CGFloat = 16 / 9
    /// Bubble center at the beginning of a drag in the preview.
    var cameraDragOrigin: CGPoint?

    var canRemoveEcho: Bool { project.info.hasMicAudio && project.info.hasSystemAudio }

    /// Computes the echo-free mic track once (in the background) if mic and system audio exist.
    private func prepareEchoRemoval() {
        guard canRemoveEcho else { echoState = .notNeeded; return }
        if FileManager.default.fileExists(atPath: EchoCanceller.cleanURL(for: project).path) {
            echoState = .ready(EchoCanceller.loadStats(for: project))
            return
        }
        echoState = .processing
        let project = self.project
        Task.detached(priority: .userInitiated) {
            do {
                let stats = try await EchoCanceller.process(project: project)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.echoState = .ready(stats)
                    if self.settings.removeEcho {
                        Task { await self.buildPlayerItem() }
                        self.loadMicWaveform()
                    }
                }
            } catch {
                await MainActor.run { [weak self] in self?.echoState = .failed(error.localizedDescription) }
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    // MARK: Playback

    private func tick(_ compTime: Double) {
        // While scrubbing, the player reports the last finished seek; the playhead already shows the newer target.
        if !isPlaying && (seekInFlight || pendingSeek != nil) { return }
        // The composition holds exactly the edited timeline: nothing to skip while it plays.
        let T = compTime - playerOffset
        let t = timeMap.source(T)
        currentTime = t
        if voiceOverState == .recording { anchorNarrationIfNeeded() }
        guard isPlaying else { return }
        followPlayhead()
        if voiceOverState == .recording, T >= timeMap.total - 0.02 {
            stopVoiceOver()
            return
        }
        if T >= displayEnd - 0.02 { finishPlayback() }
        // Playing backwards ends at the beginning.
        if shuttleRate < 0, compTime <= 0.03 { pause() }
    }

    /// Where playback starts: the intro, else the beginning of the first part.
    var playbackStart: Double { settings.introDuration > 0 ? timelineStart : timeMap.source(0) }

    private func finishPlayback() {
        if voiceOverState == .recording { stopVoiceOver() }
        pause()
        seek(to: playbackStart)
    }

    /// Length of the exported video (intro, trim, cuts and outro applied).
    var outputDuration: Double { settings.outputDuration(duration: duration) }

    /// Playhead position in the exported video.
    var outputTime: Double { max(0, display(currentTime) + introLead) }

    // MARK: Transport

    func togglePlay() {
        switch voiceOverState {
        case .recording: stopVoiceOver()
        case .countdown: cancelVoiceOver()
        default: isPlaying ? pause() : play()
        }
    }

    func play() {
        if display(currentTime) >= displayEnd - 0.05 { seek(to: playbackStart) }
        if let pending = pendingSeek {
            // Start from where the playhead is, not from an older scrub position.
            pendingSeek = nil
            player.seek(to: CMTime(seconds: display(pending) + playerOffset, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
        shuttleRate = 0
    }

    /// Moves the playhead. While a seek is still running only the newest target is kept, so
    /// scrubbing follows the mouse without queueing up frames.
    func seek(to t: Double) {
        var clamped = min(max(timelineStart, t), timelineEnd)
        // A moment that was cut away: the playhead goes to where the cut closed up.
        if clamped >= 0, clamped < duration, !timeMap.contains(source: clamped) { clamped = timeMap.source(display(clamped)) }
        currentTime = clamped
        if seekInFlight && !isPlaying {
            pendingSeek = clamped
            return
        }
        seekInFlight = true
        player.seek(to: CMTime(seconds: display(clamped) + playerOffset, preferredTimescale: 48_000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.seekFinished() }
        }
    }

    private func seekFinished() {
        seekInFlight = false
        if let next = pendingSeek {
            pendingSeek = nil
            seek(to: next)
        }
    }

    // MARK: Timeline interaction

    /// Called when a drag in the timeline begins (idempotent). The visible part of the timeline
    /// stays put while dragging, even if the timeline gets longer or shorter meanwhile.
    func beginInteraction() {
        if !isInteracting { frozenViewport = (visibleStart, visibleSpan) }
        isInteracting = true
    }

    /// Called when a drag ends (also on every mouse-up, in case a gesture got lost).
    func endInteraction() {
        maskDragOrigin = nil; cutDragOrigin = nil; zoomDragOrigin = nil
        muteDragOrigin = nil; voiceOverDragOrigin = nil; textDragOrigin = nil
        overlapDragOrigin = nil; dissolveDragOrigin = nil; freezeDragID = nil
        annotationDragOrigin = nil; imageDragOrigin = nil; cameraLayoutDragOrigin = nil; chapterDragOrigin = nil
        videoOverlayDragOrigin = nil; cursorRangeDragOrigin = nil
        finishEdgeDrag()
        groupOrigin = nil
        if snapGuide != nil { snapGuide = nil }
        frozenViewport = nil
        if textCenterGuide { textCenterGuide = false }
        let wasInteracting = isInteracting
        isInteracting = false
        if rebuildPending {
            rebuildPending = false
            Task { await buildPlayerItem() }
        }
        // A drag (or a slider moved with the mouse) is one undo step.
        if wasInteracting || undoBurstStart != nil { commitUndoStep() }
    }

    @Published var clipboard: [(item: ClipboardItem, offset: Double)] = []
    var shuttleRate: Float = 0
    /// A part of the video being dragged to another place.
    @Published var clipDrag: ClipDrag?
    /// Several things selected together (⇧-click); empty: only `selection`.
    @Published var multiSelection: [EditorSelection] = []
    /// The settings when a group drag began.
    var groupOrigin: EditSettings?
    var edgeDrag: EdgeDrag?
    var edgeDragRate = 1.0
    /// Overlap of an intro/outro or dissolve length at the start of a drag.
    var overlapDragOrigin: Double?
    var dissolveDragOrigin: CutRange?
    /// Freeze frame whose duration is being dragged.
    var freezeDragID: UUID?

    // MARK: Settings

    /// Changes that need a new composition (tracks, intro/outro length and overlap, dissolves).
    private struct StructureKey: Equatable {
        var removeEcho: Bool
        var clickSound: Bool
        var voiceOvers: [VoiceOverClip]
        var intro: Double
        var outro: Double
        var introLead: Double
        var outroLead: Double
        var dissolves: [Dissolve]
        /// Where an overlapping intro/outro lies on the recording (start of the first / end of the last kept part).
        var overlayAnchors: [Double]
        var speeds: [SpeedRange]
        var freezes: [FreezeFrame]
        var fades: [Double]
        var inserts: [InsertClip]
        /// The composition holds the kept parts only, in their order.
        var kept: [ClosedRange<Double>]
        var music: [String]
        var voice: String
        var videoOverlays: [String]
        var soundEffects: Bool
        /// Whoosh sounds sit at zoom starts.
        var zoomStarts: [Double]
        init(_ s: EditSettings, duration: Double) {
            soundEffects = s.soundEffects
            zoomStarts = s.soundEffects ? s.zoomSegments.map(\.start) : []
            videoOverlays = s.videoOverlays.map { "\($0.id)|\($0.file)|\($0.start)|\($0.duration)|\($0.fileOffset)|\($0.synced)" }
            speeds = s.speeds
            freezes = s.freezes
            fades = [s.fadeIn, s.fadeOut]
            inserts = s.inserts
            kept = s.keptSegments(duration: duration)
            music = s.music.map { [$0.file, "\($0.fileOffset)", "\($0.loop)", "\($0.clipped ?? false)"] } ?? []
            // The processed files' name is left out: the composition is rebuilt once they are ready.
            voice = (s.voice.enabled ? (s.voice.enhancesMic ? "m" : "") + (s.voice.enhancesVoiceOver ? "v" : "") : "off")
                + "|" + (s.importedVoice?.file ?? "")
            removeEcho = s.removeEcho
            clickSound = s.clickSound
            voiceOvers = s.voiceOvers.map { var c = $0; c.volume = nil; return c }   // clip volume: audio mix only
            intro = s.introDuration
            outro = s.outroDuration
            introLead = s.introLead(duration: duration)
            outroLead = s.outroLead(duration: duration)
            let layout = s.cutLayout(duration: duration)
            dissolves = layout.dissolves
            overlayAnchors = []
            if s.introOverlapLength(duration: duration) > 0 { overlayAnchors.append(layout.segments.first?.lowerBound ?? 0) }
            if s.outroOverlapLength(duration: duration) > 0 { overlayAnchors.append(layout.segments.last?.upperBound ?? 0) }
        }
    }

    /// Changes that only need a new audio mix.
    private struct AudioKey: Equatable {
        var values: [Double]
        var mutes: [AudioMute]
        var music: BackgroundMusic?
        var overlayVolumes: [Double]
        var voiceOverGains: [Double]
        var master: [Double]
        init(_ s: EditSettings) {
            music = s.music
            overlayVolumes = s.videoOverlays.map { $0.muted ? 0 : $0.volume }
            voiceOverGains = s.voiceOvers.map(\.gain)
            master = [s.masterNormalize ? 1 : 0, s.masterTargetLUFS, s.soundEffectVolume, s.voice.strength]
            values = [s.micVolume, s.systemVolume, s.voiceOverVolume, s.clickVolume, s.duckLevel,
                      s.micMuted ? 1 : 0, s.systemMuted ? 1 : 0, s.voiceOverMuted ? 1 : 0, s.duckUnderVoiceOver ? 1 : 0]
            mutes = s.audioMutes
        }
    }

    private func settingsChanged(from old: EditSettings) {
        guard settings != old else { return }
        if !applyingUndo { noteUndoable(old) }
        let newMap = settings.editMap(duration: duration)
        if newMap != timeMap { timeMap = newMap }
        renderer.update(settings: settings)
        project.settings = settings
        if StructureKey(settings, duration: duration) != StructureKey(old, duration: duration) {
            if isInteracting {
                rebuildPending = true
            } else {
                Task { await buildPlayerItem() }
            }
            if settings.removeEcho != old.removeEcho { loadMicWaveform() }
            if settings.music?.file != old.music?.file { loadMusicWaveform() }
        } else {
            if AudioKey(settings) != AudioKey(old) {
                player.currentItem?.audioMix = media?.audioMix(settings: settings)
            }
            var visual = settings
            visual.micVolume = old.micVolume; visual.systemVolume = old.systemVolume
            visual.voiceOverVolume = old.voiceOverVolume; visual.clickVolume = old.clickVolume
            visual.duckLevel = old.duckLevel; visual.micMuted = old.micMuted; visual.systemMuted = old.systemMuted
            visual.voiceOverMuted = old.voiceOverMuted; visual.duckUnderVoiceOver = old.duckUnderVoiceOver
            visual.audioMutes = old.audioMutes
            visual.music = old.music
            visual.masterNormalize = old.masterNormalize; visual.masterTargetLUFS = old.masterTargetLUFS
            visual.soundEffectVolume = old.soundEffectVolume
            for (i, o) in visual.videoOverlays.enumerated() where i < old.videoOverlays.count && old.videoOverlays[i].id == o.id {
                visual.videoOverlays[i].volume = old.videoOverlays[i].volume
                visual.videoOverlays[i].muted = old.videoOverlays[i].muted
            }
            for (i, c) in visual.voiceOvers.enumerated() where i < old.voiceOvers.count && old.voiceOvers[i].id == c.id {
                visual.voiceOvers[i].volume = old.voiceOvers[i].volume
            }
            visual.voice = old.voice
            visual.words = old.words
            if visual != old { scheduleRefresh() }
        }
        // Voice enhancement: process when switched on, a setting that goes into the processed
        // files changes or new voice-overs arrive (strength and breaths act in the mix only).
        if Self.voiceProcessingKey(settings) != Self.voiceProcessingKey(old) {
            if settings.voice.enabled {
                prepareVoice(delay: 0.5)
            } else {
                voiceTask?.cancel()
                voiceState = .idle
            }
            loadMicWaveform()
        }
        scheduleSave()
    }

    /// What goes into the processed voice files.
    static func voiceProcessingKey(_ s: EditSettings) -> String {
        guard s.voice.enabled else { return "off" }
        return [s.voice.key, s.voice.enhancesMic ? "m" : "", s.voice.enhancesVoiceOver ? "v" : "", s.removeEcho ? "e" : "",
                s.importedVoice?.file ?? "", s.voiceOvers.map(\.file).sorted().joined(separator: ",")].joined(separator: "|")
    }

    /// Processes microphone and voice-overs (noise reduction, loudness) in the background.
    /// `delay`: waits for a slider to come to rest. One run at a time: a newer request waits for
    /// the running one and makes the older ones that have not started yet unnecessary.
    func prepareVoice(delay: Double = 0) {
        guard settings.voice.enabled else { return }
        voiceState = .processing
        let previous = voiceTask
        previous?.cancel()
        voiceTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            let project = self.project, snapshot = self.settings
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await VoiceProcessor.process(project: project, settings: snapshot)
                }.value
                guard !Task.isCancelled, Self.voiceProcessingKey(self.settings) == Self.voiceProcessingKey(snapshot) else { return }
                self.voiceState = .ready(result)
                self.loadMicWaveform()
                await self.buildPlayerItem()
                VoiceProcessor.removeUnusedMicFiles(project: project, settings: snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                self.voiceState = .failed(error.localizedDescription)
            }
        }
    }

    /// Re-assigns the composition so a paused frame is re-rendered with new settings. Throttled
    /// (not debounced): while something is dragged in the preview the frame follows ~30 times a
    /// second instead of waiting until the mouse stops.
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }   // the pending refresh picks up this change too
        let wait = max(0.008, 0.033 - (CACurrentMediaTime() - lastRefresh))
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self else { return }
            self.refreshTask = nil
            self.lastRefresh = CACurrentMediaTime()
            guard let media = self.media else { return }
            self.player.currentItem?.videoComposition = media.videoComposition(renderSize: self.renderer.outputSize, fps: 60)
            if !self.isPlaying { self.seek(to: self.currentTime) }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        project.settings = settings
        try? project.saveSettings()
    }

    // MARK: Selection

    var selectedZoomID: UUID? {
        get { if case .zoom(let id) = selection { return id } else { return nil } }
        set { if let newValue { selection = .zoom(newValue) } else if case .zoom = selection { selection = nil } }
    }
    var selectedCutID: UUID? {
        get { if case .cut(let id) = selection { return id } else { return nil } }
        set { if let newValue { selection = .cut(newValue) } else if case .cut = selection { selection = nil } }
    }
    var selectedMaskID: UUID? {
        get { if case .mask(let id) = selection { return id } else { return nil } }
        set { if let newValue { selection = .mask(newValue) } else if case .mask = selection { selection = nil } }
    }
    var selectedMuteID: UUID? {
        get { if case .mute(let id) = selection { return id } else { return nil } }
        set { if let newValue { selection = .mute(newValue) } else if case .mute = selection { selection = nil } }
    }
    var selectedVoiceOverID: UUID? {
        get { if case .voiceOver(let id) = selection { return id } else { return nil } }
        set { if let newValue { selection = .voiceOver(newValue) } else if case .voiceOver = selection { selection = nil } }
    }
    var selectedTextID: UUID? {
        get { if case .text(let id) = selection { return id } else { return nil } }
        set { if let newValue { selection = .text(newValue) } else if case .text = selection { selection = nil } }
    }

    /// Deletes the selected item (Delete key).
    func deleteSelection() {
        commitUndoStep(); defer { commitUndoStep() }   // one undo step of its own
        if selection == nil, let words = transcriptSelection {
            cutWords(words)
            return
        }
        if multiSelection.count > 1 {
            deleteGroup()
            return
        }
        guard let selection else { return }
        if case .audioLane = selection { return }   // lanes and panels can't be deleted
        if case .panel = selection { return }
        removeItem(selection)
        self.selection = nil
    }

    /// Removes one selected thing (without an undo step of its own).
    func removeItem(_ item: EditorSelection) {
        switch item {
        case .join(let key): settings.joinTransitions.removeAll { abs($0.key - key) < 1e-4 }
        case .mask(let id): settings.masks.removeAll { $0.id == id }
        case .cut(let id): settings.cuts.removeAll { $0.id == id }
        case .zoom(let id): settings.zoomSegments.removeAll { $0.id == id }
        case .mute(let id): settings.audioMutes.removeAll { $0.id == id }
        case .voiceOver(let id):
            settings.voiceOvers.removeAll { $0.id == id }
            dropEmptyMusicLane()
        case .text(let id):
            settings.texts.removeAll { $0.id == id }
            forgetUnusedOverlaps()
        case .segment(let start):
            guard let segment = videoSegments.first(where: { abs($0.lowerBound - start) < 1e-6 }) else { return }
            removeSegment(segment)
        case .freeze(let id): settings.freezes.removeAll { $0.id == id }
        case .cameraLayout(let id): settings.cameraLayouts.removeAll { $0.id == id }
        case .annotation(let id): settings.annotations.removeAll { $0.id == id }
        case .image(let id): settings.images.removeAll { $0.id == id }
        case .insert(let id): settings.inserts.removeAll { $0.id == id }
        case .chapter(let id): settings.chapters.removeAll { $0.id == id }
        case .cursorRange(let id): settings.cursorRanges.removeAll { $0.id == id }
        case .audioLane, .panel:
            return   // lanes and panels can't be deleted
        case .videoOverlay(let id):
            if settings.videoOverlays.contains(where: { $0.id == id && $0.synced }),
               settings.videoOverlays.filter(\.synced).count == 1 { settings.dismissedSyncedOverlay = true }
            settings.videoOverlays.removeAll { $0.id == id }
        }
    }

    /// A new intro/outro starts without the overlap of a deleted one.
    func forgetUnusedOverlaps() {
        if settings.intro == nil && settings.introOverlap != 0 { settings.introOverlap = 0 }
        if settings.outro == nil && settings.outroOverlap != 0 { settings.outroOverlap = 0 }
    }

    // MARK: Zoom editing

    func regenerateAutoZoom() {
        commitUndoStep(); defer { commitUndoStep() }   // one undo step of its own
        let manual = settings.zoomSegments.filter { !$0.isAuto }
        let auto = AutoZoom.segments(for: project.cursor.clicks, duration: duration, scale: settings.defaultZoom)
        settings.zoomSegments = (manual + auto).sorted { $0.start < $1.start }
        selectedZoomID = nil
    }

    /// The playhead inside the recording (for adding items).
    private var recordingTime: Double { min(max(0, currentTime), duration) }

    func addZoomAtPlayhead() {
        addZoom(start: max(0, recordingTime - 0.3))
    }

    func addZoom(start: Double, length: Double = 3) {
        commitUndoStep(); defer { commitUndoStep() }   // one undo step of its own
        let end = min(duration, start + length)
        guard end - start > 0.5 else { return }
        var seg = ZoomSegment(start: start, end: end, scale: settings.defaultZoom, isAuto: false)
        // Without a mouse (an iPad, an own video) the zoom goes to a fixed point, at first the middle.
        if !hasCursorData { seg.focusX = 0.5; seg.focusY = 0.5 }
        settings.zoomSegments.append(seg)
        settings.zoomSegments.sort { $0.start < $1.start }
        selectedZoomID = seg.id
    }

    func deleteSelectedZoom() {
        guard let id = selectedZoomID else { return }
        settings.zoomSegments.removeAll { $0.id == id }
        selectedZoomID = nil
    }

    /// The recording has mouse movements a zoom can follow.
    var hasCursorData: Bool { !project.cursor.samples.isEmpty }

    /// Fixed point or following the mouse; a fixed point starts where the mouse was in the middle of the zoom.
    func setZoomFixed(_ id: UUID, _ fixed: Bool) {
        guard let i = settings.zoomSegments.firstIndex(where: { $0.id == id }) else { return }
        commitUndoStep(); defer { commitUndoStep() }
        let seg = settings.zoomSegments[i]
        if fixed {
            let p = renderer.cursorPosition(at: (seg.start + seg.end) / 2) ?? CGPoint(x: 0.5, y: 0.5)
            settings.zoomSegments[i].focusX = min(1, max(0, Double(p.x)))
            settings.zoomSegments[i].focusY = min(1, max(0, Double(p.y)))
            placeZoom(id)
        } else {
            settings.zoomSegments[i].focusX = nil
            settings.zoomSegments[i].focusY = nil
        }
    }

    /// Goes to the start of the zoom, where the picture is not zoomed yet: there the frame of the
    /// zoomed part can be moved in the preview.
    func placeZoom(_ id: UUID) {
        guard let seg = settings.zoomSegments.first(where: { $0.id == id }) else { return }
        if isPlaying { pause() }
        seek(to: seg.start)
    }

    /// Sets the fixed point and the strength of a zoom from the frame drawn in the preview.
    func setZoomArea(_ id: UUID, area: CGRect) {
        guard let i = settings.zoomSegments.firstIndex(where: { $0.id == id }) else { return }
        settings.zoomSegments[i].focusX = min(1, max(0, Double(area.midX)))
        settings.zoomSegments[i].focusY = min(1, max(0, Double(area.midY)))
        settings.zoomSegments[i].scale = min(4, max(1.1, renderer.zoomScale(forWidth: area.width, at: currentTime)))
    }

    var selectedZoomIndex: Int? {
        guard let id = selectedZoomID else { return nil }
        return settings.zoomSegments.firstIndex { $0.id == id }
    }

    func updateZoom(id: UUID, start: Double? = nil, end: Double? = nil, scale: Double? = nil) {
        guard let i = settings.zoomSegments.firstIndex(where: { $0.id == id }) else { return }
        var seg = settings.zoomSegments[i]
        var newStart = max(0, start ?? seg.start)
        var newEnd = min(duration, end ?? seg.end)
        if newEnd - newStart < 0.5 {
            if start != nil && end == nil { newStart = newEnd - 0.5 } else { newEnd = newStart + 0.5 }
        }
        seg.start = max(0, newStart)
        seg.end = min(duration, newEnd)
        if let scale { seg.scale = scale }
        seg.isAuto = false
        settings.zoomSegments[i] = seg
    }

    func setTrim(start: Double? = nil, end: Double? = nil) {
        if let start { settings.trimStart = max(0, min(start, trimEnd - 0.5)) }
        if let end {
            let e = min(duration, max(end, settings.trimStart + 0.5))
            settings.trimEnd = e >= duration - 0.001 ? nil : e
        }
    }

    // MARK: Cuts

    var selectedCut: CutRange? {
        guard let id = selectedCutID else { return nil }
        return settings.cuts.first { $0.id == id }
    }

    func updateCut(id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let i = settings.cuts.firstIndex(where: { $0.id == id }) else { return }
        var cut = settings.cuts[i]
        var s = max(0, start ?? cut.start), e = min(duration, end ?? cut.end)
        if e - s < 0.1 {
            if start != nil && end == nil { s = e - 0.1 } else { e = s + 0.1 }
        }
        cut.start = max(0, s)
        cut.end = min(duration, e)
        settings.cuts[i] = cut
    }

    // MARK: Captions

    func generateCaptions() {
        Task { await generateCaptionsNow() }
    }

    /// Recognizes speech and makes captions and the word list (for cutting via the transcript).
    func generateCaptionsNow() async {
        guard !isGeneratingCaptions else { return }
        isGeneratingCaptions = true
        captionError = nil
        captionStatus = "Audio wird vorbereitet …"
        saveNow()
        let project = self.project
        let language = settings.captionLanguage
        let source = settings.captionSource
        do {
            let (captions, words) = try await Task.detached(priority: .userInitiated) {
                try await CaptionGenerator.generate(project: project, localeID: language, source: source) { message in
                    Task { @MainActor [weak self] in self?.captionStatus = message }
                }
            }.value
            settings.captions = captions
            settings.words = words.map { TranscriptWord(text: $0.text, start: $0.start, end: $0.end) }
            settings.showCaptions = true
            captionStatus = captions.isEmpty ? "Keine Sprache erkannt." : "\(captions.count) Untertitel erzeugt."
        } catch {
            captionError = error.localizedDescription
            captionStatus = nil
        }
        isGeneratingCaptions = false
    }

    func updateCaption(id: UUID, text: String) {
        guard let i = settings.captions.firstIndex(where: { $0.id == id }) else { return }
        settings.captions[i].text = text
    }

    // MARK: Voice edited in another program

    /// Saves the voice of the recording (whole and uncut) as a WAV file.
    func exportVoice() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "wav") ?? .audio]
        panel.nameFieldStringValue = project.name + " – Stimme.wav"
        panel.message = "Die ganze, ungeschnittene Stimme der Aufnahme – beim Bearbeiten die Länge nicht ändern"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExchangingVoice = true
        voiceExchangeStatus = "Stimme wird exportiert …"
        let project = self.project, s = settings
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    let samples = try await VoiceExchange.originalVoice(project: project, settings: s)
                    try VoiceExchange.writeWAV(samples, to: url)
                }.value
                self?.voiceExchangeStatus = "Exportiert: \(url.lastPathComponent). Nach dem Bearbeiten mit „Bearbeitete Stimme importieren …“ zurückholen."
            } catch {
                self?.voiceExchangeStatus = "Export fehlgeschlagen: \(error.localizedDescription)"
            }
            self?.isExchangingVoice = false
        }
    }

    /// Brings an edited voice back: lined up with the recording, it replaces the microphone.
    func importVoice() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Bearbeitete Stimme wählen (WAV, AIFF, FLAC, M4A oder MP3)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExchangingVoice = true
        voiceExchangeStatus = "Stimme wird importiert und ausgerichtet …"
        let project = self.project, s = settings
        Task { [weak self] in
            do {
                let (voice, note) = try await Task.detached(priority: .userInitiated) {
                    try await VoiceExchange.importVoice(from: url, project: project, settings: s)
                }.value
                guard let self else { return }
                self.commitUndoStep()
                self.settings.importedVoice = voice
                self.commitUndoStep()
                self.voiceExchangeStatus = note
            } catch {
                self?.voiceExchangeStatus = "Import fehlgeschlagen: \(error.localizedDescription)"
            }
            self?.isExchangingVoice = false
        }
    }

    /// Back to the recording's own microphone.
    func removeImportedVoice() {
        commitUndoStep()
        settings.importedVoice = nil
        commitUndoStep()
        voiceExchangeStatus = nil
    }

    /// Captions only from the playhead on (e.g. after an intro); at the very start: from the start again.
    func setCaptionsFromPlayhead() {
        commitUndoStep()
        let T = display(currentTime)
        settings.captionsFrom = T > 0.05 ? T : nil
        commitUndoStep()
    }

    /// The picture at the playhead, as it will be exported, into the media library (PNG).
    func snapshotToLibrary() {
        guard let media else { return }
        let renderSize = renderer.outputSize
        let compositionTime = display(currentTime) + playerOffset
        let T = outputTime
        let folder = project.url.appendingPathComponent("media", isDirectory: true)
        Task {
            do {
                let image = try await Self.renderFrame(media: media, renderSize: renderSize, at: compositionTime)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let seconds = Int(T.rounded(.down))
                let name = String(format: "%@-Standbild %d.%02d.png", String(UUID().uuidString.prefix(8)), seconds / 60, seconds % 60)
                let url = folder.appendingPathComponent(name)
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw RecorderError.writerFailed("Standbild")
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw RecorderError.writerFailed("Standbild") }
                libraryVersion &+= 1
            } catch {
                libraryMessage = "Standbild ging nicht: \(error.localizedDescription)"
            }
        }
    }

    /// One frame of the finished video (composition time `t`), in the export's size.
    nonisolated static func renderFrame(media: MediaComposition, renderSize: CGSize, at t: Double) async throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: media.asset)
        gen.videoComposition = media.videoComposition(renderSize: renderSize, fps: 30)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        return try await gen.image(at: CMTime(seconds: max(0, t), preferredTimescale: 600)).image
    }

    /// The captions as SRT in output time.
    func srtText() -> String {
        CaptionGenerator.srt(settings.captions, kept: settings.keptSegments(duration: duration),
                             offset: introLead, map: timeMap, from: settings.captionsFrom)
    }

    func exportSRT() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = project.name + ".srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try srtText().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            captionError = error.localizedDescription
        }
    }

    // MARK: Masks

    var selectedMask: BlurMask? {
        guard let id = selectedMaskID else { return nil }
        return settings.masks.first { $0.id == id }
    }

    func addMaskAtPlayhead() {
        addMask(start: recordingTime)
    }

    func addMask(start: Double, length: Double = 3) {
        commitUndoStep(); defer { commitUndoStep() }   // one undo step of its own
        let end = min(duration, start + length)
        guard end - start > 0.2 else { return }
        let mask = BlurMask(start: start, end: end)
        settings.masks.append(mask)
        selectedMaskID = mask.id
        if isPlaying { pause() }
    }

    func updateMask(id: UUID, _ change: (inout BlurMask) -> Void) {
        guard let i = settings.masks.firstIndex(where: { $0.id == id }) else { return }
        var m = settings.masks[i]
        change(&m)
        m.width = min(1, max(0.01, m.width))
        m.height = min(1, max(0.01, m.height))
        m.x = min(1 - m.width, max(0, m.x))
        m.y = min(1 - m.height, max(0, m.y))
        (m.start, m.end) = clampedRange(m.start, m.end, minLength: 0.1)
        settings.masks[i] = m
    }

    // MARK: Audio lanes

    /// Lanes shown in the timeline.
    var audioLanes: [AudioLane] {
        var lanes: [AudioLane] = []
        if project.info.hasMicAudio { lanes.append(.mic) }
        if project.info.hasSystemAudio { lanes.append(.system) }
        lanes.append(.voiceOver)
        if settings.music != nil { lanes.append(.music) }
        return lanes
    }

    func isMuted(_ lane: AudioLane) -> Bool {
        switch lane {
        case .mic: return settings.micMuted
        case .system: return settings.systemMuted
        case .voiceOver: return settings.voiceOverMuted
        case .music: return settings.music?.muted ?? true
        }
    }

    /// Volume slider of a lane.
    func volume(of lane: AudioLane) -> Double {
        switch lane {
        case .mic: return settings.micVolume
        case .system: return settings.systemVolume
        case .voiceOver: return settings.voiceOverVolume
        case .music: return settings.music?.volume ?? 0
        }
    }

    func setVolume(_ v: Double, of lane: AudioLane) {
        switch lane {
        case .mic: settings.micVolume = v
        case .system: settings.systemVolume = v
        case .voiceOver: settings.voiceOverVolume = v
        case .music: settings.music?.volume = v
        }
    }

    func setMuted(_ m: Bool, _ lane: AudioLane) {
        switch lane {
        case .mic: settings.micMuted = m
        case .system: settings.systemMuted = m
        case .voiceOver: settings.voiceOverMuted = m
        case .music: settings.music?.muted = m
        }
    }

    func toggleMute(_ lane: AudioLane) {
        commitUndoStep(); defer { commitUndoStep() }   // one undo step of its own
        switch lane {
        case .mic: settings.micMuted.toggle()
        case .system: settings.systemMuted.toggle()
        case .voiceOver: settings.voiceOverMuted.toggle()
        case .music: settings.music?.muted.toggle()
        }
    }

    var selectedMute: AudioMute? {
        guard let id = selectedMuteID else { return nil }
        return settings.audioMutes.first { $0.id == id }
    }

    /// Silences `lane` for 2 s from the playhead (adjust the range in the timeline).
    func addMute(lane: AudioLane, gain: Double? = nil) {
        commitUndoStep(); defer { commitUndoStep() }   // one undo step of its own
        let r = sourceRange(from: recordingTime, timelineLength: 2)
        guard display(r.end) - display(r.start) > 0.1 else { return }
        var mute = AudioMute(lane: lane, start: r.start, end: r.end)
        mute.gain = gain
        settings.audioMutes.append(mute)
        selectedMuteID = mute.id
    }

    /// "Cuts" a lane at `t`: a range from there to the end of the current part of the recording
    /// (or up to the next range) that can get its own volume.
    func splitLane(_ lane: AudioLane, at t: Double) {
        if lane == .music {
            splitMusic(atTimeline: display(t))
            return
        }
        guard t > 0.02, t < duration - 0.05 else { return }
        if let inside = settings.audioMutes.first(where: { $0.lane == lane && t > $0.start + 0.05 && t < $0.end - 0.05 }) {
            var second = inside
            second.id = UUID()
            second.start = t
            updateMute(id: inside.id) { $0.end = t }
            settings.audioMutes.append(second)
            selectedMuteID = second.id
            return
        }
        let next = settings.audioMutes.filter { $0.lane == lane && $0.start > t }.map(\.start).min() ?? duration
        let end = min(next, segment(at: t)?.upperBound ?? duration)
        guard end - t > 0.05 else { return }
        var range = AudioMute(lane: lane, start: t, end: end)
        range.gain = 1
        settings.audioMutes.append(range)
        selectedMuteID = range.id
    }

    func updateMute(id: UUID, _ change: (inout AudioMute) -> Void) {
        guard let i = settings.audioMutes.firstIndex(where: { $0.id == id }) else { return }
        var m = settings.audioMutes[i]
        change(&m)
        (m.start, m.end) = clampedRange(m.start, m.end, minLength: 0.05)
        if let g = m.gain { m.gain = min(1, max(0, g)) }
        settings.audioMutes[i] = m
    }

    var selectedVoiceOver: VoiceOverClip? {
        guard let id = selectedVoiceOverID else { return nil }
        return settings.voiceOvers.first { $0.id == id }
    }

    /// Length of a voice-over file (from its waveform), if known.
    func voiceOverFileLength(_ file: String) -> Double? {
        waveforms[file].map { Double($0.count) / Waveform.rate }
    }

    func updateVoiceOver(id: UUID, _ change: (inout VoiceOverClip) -> Void) {
        guard let i = settings.voiceOvers.firstIndex(where: { $0.id == id }) else { return }
        var c = settings.voiceOvers[i]
        change(&c)
        c.fileOffset = max(0, c.fileOffset)
        if let length = voiceOverFileLength(c.file) { c.duration = min(c.duration, length - c.fileOffset) }
        c.duration = max(0.1, c.duration)
        // The clip plays in real time from its start: keep it on the timeline.
        if c.isFree {
            c.start = min(max(0, c.start), max(0, timeMap.total - c.duration))
        } else {
            c.start = sourceTime(min(max(0, display(c.start)), max(0, timeMap.total - c.duration)))
        }
        settings.voiceOvers[i] = c
    }

    // MARK: Waveforms

    private func loadWaveforms() {
        loadMicWaveform()
        let project = self.project
        if project.info.hasSystemAudio {
            Task.detached(priority: .utility) {
                let peaks = try? await Self.recordingPeaks(project: project, role: "system")
                await MainActor.run { [weak self] in self?.waveforms["system"] = peaks }
            }
        }
        for file in Set(settings.voiceOvers.map(\.file)) { loadVoiceOverWaveform(file) }
        loadMusicWaveform()
    }

    func loadMusicWaveform() {
        guard let music = settings.music else { return }
        let url = project.url.appendingPathComponent(music.file)
        Task.detached(priority: .utility) {
            let peaks = try? await Waveform.peaks(url: url)
            await MainActor.run { [weak self] in self?.waveforms["music:" + music.file] = peaks }
        }
    }

    /// The mic waveform shows what plays: the echo-free track when echo removal is on.
    private func loadMicWaveform() {
        guard project.info.hasMicAudio else { return }
        let project = self.project
        let clean = EchoCanceller.cleanURL(for: project)
        let voice = VoiceProcessor.micURL(for: project, settings: settings)
        let file: URL? = VoiceProcessor.importedMicURL(for: project, settings: settings)
            ?? (settings.voice.enhancesMic && FileManager.default.fileExists(atPath: voice.path) ? voice
                : settings.removeEcho && FileManager.default.fileExists(atPath: clean.path) ? clean : nil)
        let duration = self.duration
        Task.detached(priority: .utility) {
            let peaks = file != nil ? try? await Waveform.peaks(url: file!) : try? await Self.recordingPeaks(project: project, role: "mic")
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.waveformPeaks["mic"] = nil
                self.waveforms["mic"] = peaks
                // Speech for ducking the music (only the first time it matters for the composition).
                let speech = PauseDetector.speech(peaks ?? [], duration: duration)
                if speech != self.speechRanges {
                    self.speechRanges = speech
                    if self.settings.music != nil { Task { await self.buildPlayerItem() } }
                }
            }
        }
    }

    nonisolated private static func recordingPeaks(project: Project, role: String) async throws -> [Float] {
        let asset = AVURLAsset(url: project.videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let roles = await AudioRole.roles(of: tracks, fallback: project.info.audioRoles)
        guard let i = roles.firstIndex(of: role) else { return [] }
        return try await Waveform.peaks(track: tracks[i], asset: asset)
    }

    func loadVoiceOverWaveform(_ file: String) {
        let url = project.url.appendingPathComponent(file)
        Task.detached(priority: .utility) {
            let peaks = try? await Waveform.peaks(url: url)
            await MainActor.run { [weak self] in self?.waveforms[file] = peaks }
        }
    }

    // MARK: Voice-over recording

    func toggleVoiceOver() {
        switch voiceOverState {
        case .idle: Task { await startVoiceOver() }
        case .countdown: cancelVoiceOver()
        case .recording: stopVoiceOver()
        case .saving: break
        }
    }

    /// Counts down, then plays the video from the playhead and records the microphone.
    func startVoiceOver() async {
        guard voiceOverState == .idle, !isExporting else { return }
        pause()
        voiceOverError = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            voiceOverError = "Kein Zugriff aufs Mikrofon (Systemeinstellungen › Datenschutz & Sicherheit › Mikrofon)."
            return
        }
        guard let device = VoiceOverRecorder.defaultDevice else {
            voiceOverError = "Kein Mikrofon gefunden."
            return
        }
        if let script = settings.script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if prompter.model.scrollSpeed == 0 { prompter.model.scrollSpeed = 22 }
            prompter.show(text: script, on: nil)
        }
        let file = "voiceover/vo-\(UUID().uuidString.prefix(8)).m4a"
        let recorder = VoiceOverRecorder()
        do {
            try recorder.prepare(device: device, url: project.url.appendingPathComponent(file))
        } catch {
            voiceOverError = error.localizedDescription
            return
        }
        voiceOverRecorder = recorder
        voiceOverFile = file

        // Narration starts at the playhead, inside the kept part of the recording.
        var start = currentTime
        if display(start) >= timeMap.total - 0.5 || start < 0 || start >= duration { start = timeMap.source(0) }
        seek(to: start)

        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let recorder = self.voiceOverRecorder else { return }
                self.voiceOverLevel = recorder.currentLevel
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer

        for n in [3, 2, 1] {
            voiceOverState = .countdown(n)
            try? await Task.sleep(for: .seconds(1))
            guard voiceOverState == .countdown(n) else { return }   // cancelled
        }
        voiceOverState = .recording
        player.isMuted = !monitorWhileNarrating
        let now = CACurrentMediaTime()
        recorder.beginWriting(fromHost: now)
        narrationSpans = [NarrationSpan(hostStart: now)]
        narrationAnchorAllowed = true
        play()
    }

    /// Links the current narration stretch to the video time, once playback runs.
    private func anchorNarrationIfNeeded() {
        guard narrationAnchorAllowed, var span = narrationSpans.last, span.anchorHost == nil,
              let timebase = player.currentItem?.timebase, CMTimebaseGetRate(timebase) > 0 else { return }
        let host = CACurrentMediaTime()
        let itemTime = CMTimebaseGetTime(timebase).seconds
        span.anchorHost = host
        span.anchorSource = itemTime - playerOffset   // timeline time
        narrationSpans[narrationSpans.count - 1] = span
    }

    func cancelVoiceOver() {
        voiceOverRecorder?.cancel()
        if let file = voiceOverFile { try? FileManager.default.removeItem(at: project.url.appendingPathComponent(file)) }
        endVoiceOverSession()
        pause()
    }

    private func endVoiceOverSession() {
        levelTimer?.invalidate()
        levelTimer = nil
        voiceOverRecorder = nil
        voiceOverFile = nil
        voiceOverLevel = 0
        voiceOverState = .idle
        player.isMuted = false
    }

    func stopVoiceOver() {
        guard voiceOverState == .recording, let recorder = voiceOverRecorder, let file = voiceOverFile else { return }
        voiceOverState = .saving
        anchorNarrationIfNeeded()
        let endHost = CACurrentMediaTime()
        let spans = narrationSpans
        pause()
        player.isMuted = false
        Task {
            defer { endVoiceOverSession() }
            guard let result = await recorder.finish() else {
                voiceOverError = "Es wurde nichts aufgenommen."
                return
            }
            let fileEnd = result.firstHost + result.duration
            var clips: [VoiceOverClip] = []
            for (i, span) in spans.enumerated() {
                guard let anchorHost = span.anchorHost, let anchorSource = span.anchorSource else { continue }
                var hostStart = max(span.hostStart, result.firstHost)
                let hostEnd = min(i + 1 < spans.count ? spans[i + 1].hostStart : endHost, fileEnd)
                // Timeline arithmetic (the narration runs in real time, also over freeze frames).
                var start = anchorSource - (anchorHost - hostStart)
                if start < 0 { hostStart -= start; start = 0 }
                guard hostEnd - hostStart > 0.05 else { continue }
                clips.append(VoiceOverClip(file: file, fileOffset: hostStart - result.firstHost,
                                           start: timeMap.source(start), duration: min(hostEnd - hostStart, timeMap.total - start)))
            }
            guard !clips.isEmpty else {
                voiceOverError = "Die Aufnahme war zu kurz."
                return
            }
            commitUndoStep()
            settings.voiceOvers += clips.map(adopted)
            commitUndoStep()
            selectedVoiceOverID = clips.first?.id
            loadVoiceOverWaveform(file)
        }
    }

    // MARK: Texts

    var selectedText: TextOverlay? {
        guard let id = selectedTextID else { return nil }
        return settings.texts.first { $0.id == id }
    }

    func addLowerThird() {
        addLowerThird(start: recordingTime)
    }

    func addLowerThird(start proposed: Double, length: Double = 4) {
        commitUndoStep(); defer { commitUndoStep() }   // one undo step of its own
        let r = sourceRange(from: proposed, timelineLength: length)
        var text = TextOverlay(kind: .lowerThird, start: r.start, end: r.end, title: "Titel", subtitle: "Untertitel")
        text.design = settings.textDesign   // the design used last
        settings.texts.append(adopted(text))
        selectedTextID = text.id
        if isPlaying { pause() }
    }

    func addTitleCard(placement: TextOverlay.Placement) {
        commitUndoStep(); defer { commitUndoStep() }   // one undo step of its own
        if placement != .overlay, let existing = settings.texts.first(where: { $0.kind == .titleCard && $0.placement == placement }) {
            selectedTextID = existing.id
            return
        }
        var card = TextOverlay(kind: .titleCard, placement: placement, start: 0, end: 3,
                               title: placement == .outro ? "Danke fürs Zuschauen" : project.name,
                               subtitle: "", style: .plain, align: .center)
        if placement == .overlay {
            (card.start, card.end) = sourceRange(from: recordingTime, timelineLength: 3)
        }
        // The design used last, without its box (title cards show the text on the background).
        if var d = settings.textDesign { d.box = .clear; card.design = d }
        settings.texts.append(adopted(card))
        selectedTextID = card.id
        if isPlaying { pause() }
        switch placement {
        case .intro: Task { try? await Task.sleep(for: .milliseconds(300)); seek(to: timelineStart + min(1, introLead / 2)) }
        case .outro: Task { try? await Task.sleep(for: .milliseconds(300)); seek(to: duration + 1) }
        case .overlay: break
        }
    }

    func updateText(id: UUID, _ change: (inout TextOverlay) -> Void) {
        guard let i = settings.texts.firstIndex(where: { $0.id == id }) else { return }
        var t = settings.texts[i]
        change(&t)
        t.x = min(1, max(0, t.x))
        t.y = min(1, max(0, t.y))
        t.size = min(2.5, max(0.4, t.size))
        if t.kind == .titleCard && t.placement != .overlay {
            t.start = 0
            t.end = min(20, max(1, t.end))
        } else if t.isFree {
            t.start = min(max(0, t.start), max(0, timeMap.total - 0.2))
            t.end = min(timeMap.total, max(t.end, t.start + 0.2))
        } else {
            (t.start, t.end) = clampedRange(t.start, t.end, minLength: 0.2)
        }
        settings.texts[i] = t
    }

    // MARK: Export

    func export(to url: URL) async {
        guard !isExporting, voiceOverState == .idle else { return }
        pause()
        saveNow()
        isExporting = true
        exportProgress = 0
        exportError = nil
        exportResult = nil
        defer { isExporting = false }

        do {
            let media = try await MediaBuilder.make(project: project, renderer: renderer, fps: settings.exportFPS,
                                                    segments: settings.keptSegments(duration: duration), speech: speechRanges)
            if url.pathExtension.lowercased() == "gif" {
                try await GIFExporter.export(media: media, renderSize: renderer.outputSize, to: url) { [weak self] p in
                    Task { @MainActor in self?.exportProgress = p }
                }
                exportProgress = 1
                exportResult = url
                exportSession = nil
                return
            }
            let preset = settings.exportHEVC ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
            guard let session = AVAssetExportSession(asset: media.asset, presetName: preset) else {
                throw RecorderError.writerFailed("Export wird nicht unterstützt")
            }
            exportSession = session
            session.videoComposition = media.videoComposition
            session.audioMix = media.audioMix(settings: settings)
            session.audioTimePitchAlgorithm = .spectral
            try? FileManager.default.removeItem(at: url)

            let progressTask = Task { [weak self] in
                for await state in session.states(updateInterval: 0.1) {
                    if case .exporting(let progress) = state {
                        await MainActor.run { self?.exportProgress = progress.fractionCompleted }
                    }
                }
            }
            defer { progressTask.cancel() }
            try await session.export(to: url, as: .mp4)
            masterResult = nil
            if settings.masterNormalize {
                exportProgress = 0.99
                masterResult = try await AudioMastering.normalize(file: url, target: settings.masterTargetLUFS)
            }
            exportProgress = 1
            exportResult = url
            rememberExport(url)
            // Chapters for the video description, next to the video.
            if !settings.chapters.isEmpty {
                let text = url.deletingPathExtension().appendingPathExtension("kapitel.txt")
                try? (youTubeChapterText + "\n").write(to: text, atomically: true, encoding: .utf8)
            }
        } catch is CancellationError {
            exportError = "Export abgebrochen."
        } catch {
            exportError = error.localizedDescription
        }
        exportSession = nil
    }

    func cancelExport() {
        exportSession?.cancelExport()
    }

    var suggestedExportName: String {
        project.name + ".mp4"
    }
}

extension EditorModel {
    /// Moves a title card between overlay, intro and outro (only one intro and one outro).
    func setPlacement(id: UUID, _ placement: TextOverlay.Placement) {
        commitUndoStep(); defer { commitUndoStep() }   // one undo step of its own
        guard let i = settings.texts.firstIndex(where: { $0.id == id }) else { return }
        var texts = settings.texts
        if placement != .overlay {
            for j in texts.indices where j != i && texts[j].kind == .titleCard && texts[j].placement == placement {
                texts[j].placement = .overlay
                texts[j].start = 0
                texts[j].end = min(duration, 3)
            }
        }
        let length = max(1, min(10, texts[i].length))
        texts[i].placement = placement
        if placement == .overlay {
            texts[i].start = min(max(0, currentTime), max(0, duration - length))
            texts[i].end = min(duration, texts[i].start + length)
        } else {
            texts[i].start = 0
            texts[i].end = length
        }
        settings.texts = texts
        forgetUnusedOverlaps()
    }
}

// MARK: - Timeline zoom

extension EditorModel {
    var totalSpan: Double { max(0.001, displayEnd - displayStart) }
    /// Shortest visible length (closest zoom).
    var minSpan: Double { min(totalSpan, max(0.05, Double(timelineWidth) / Self.maxPointsPerSecond)) }
    var visibleSpan: Double {
        if let frozen = frozenViewport { return frozen.span }
        return min(totalSpan, max(minSpan, zoomSpan ?? totalSpan))
    }
    var visibleStart: Double {
        if let frozen = frozenViewport { return frozen.start }
        guard zoomSpan != nil else { return displayStart }
        return min(max(displayStart, scrollStart), displayEnd - visibleSpan)
    }
    var isZoomed: Bool { visibleSpan < totalSpan - 1e-6 }

    /// Zoom 0 (everything) … 1 (closest), logarithmic, for the slider.
    var zoomLevel: Double {
        get {
            let range = log(totalSpan / minSpan)
            return range > 1e-6 ? min(1, max(0, log(totalSpan / visibleSpan) / range)) : 0
        }
        set {
            let span = totalSpan * pow(minSpan / totalSpan, min(1, max(0, newValue)))
            zoom(toSpan: span, around: zoomAnchor)
        }
    }

    /// The playhead if it is visible, else the middle of the visible part.
    var zoomAnchor: Double {
        let start = visibleStart, span = visibleSpan, now = display(currentTime)
        return now >= start && now <= start + span ? now : start + span / 2
    }

    /// Zooms in (`factor` > 1) or out, keeping `anchor` at the same place on screen.
    func zoom(by factor: Double, around anchor: Double? = nil) {
        guard factor > 0, factor.isFinite else { return }
        zoom(toSpan: visibleSpan / factor, around: anchor ?? zoomAnchor)
    }

    func zoom(toSpan span: Double, around anchor: Double) {
        let oldStart = visibleStart, oldSpan = visibleSpan
        let newSpan = min(totalSpan, max(minSpan, span))
        if newSpan >= totalSpan - 1e-6 {
            if zoomSpan != nil { zoomSpan = nil }
            return
        }
        let fraction = min(1, max(0, (anchor - oldStart) / oldSpan))
        scrollStart = min(max(displayStart, anchor - fraction * newSpan), displayEnd - newSpan)
        zoomSpan = newSpan
    }

    func zoomToFit() {
        zoomSpan = nil
    }

    /// Scrolls the zoomed timeline by `seconds`.
    func pan(by seconds: Double) {
        guard isZoomed else { return }
        scrollStart = min(max(displayStart, visibleStart + seconds), displayEnd - visibleSpan)
    }

    /// Scrolls so that `start` is the left edge.
    func scroll(to start: Double) {
        guard isZoomed else { return }
        scrollStart = min(max(displayStart, start), displayEnd - visibleSpan)
    }

    /// Keeps the playhead on screen: pages forward when it reaches the right edge.
    func followPlayhead() {
        guard isZoomed else { return }
        let start = visibleStart, span = visibleSpan, now = display(currentTime)
        if now > start + span * 0.97 || now < start {
            scroll(to: now - span * 0.03)
        }
    }

    /// Moves the playhead by `seconds` of timeline time (arrow keys) and keeps it visible.
    func step(by seconds: Double) {
        if isPlaying { pause() }
        seek(to: sourceTime(display(currentTime) + seconds))
        followPlayhead()
    }
}

// MARK: - Cross dissolves (cuts, intro, outro)

extension EditorModel {
    /// Effective dissolve per cut (only cuts between two kept parts can have one).
    var dissolvesByCut: [UUID: Dissolve] {
        Dictionary(settings.dissolves(duration: duration).map { ($0.cutID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Cuts between two kept parts: these can get a cross dissolve.
    func canDissolve(_ cut: CutRange) -> Bool {
        if dissolvesByCut[cut.id] != nil { return true }
        // Only where the parts on both sides of the cut still follow each other.
        let parts = clipParts
        return zip(parts, parts.dropFirst()).contains { abs($0.range.upperBound - cut.start) < 1e-3 && abs($1.range.lowerBound - cut.end) < 1e-3 }
    }

    func setTransition(cutID: UUID, _ style: TransitionStyle) {
        guard let i = settings.cuts.firstIndex(where: { $0.id == cutID }) else { return }
        settings.cuts[i].transition = style
        if settings.cuts[i].dissolve < 0.05 { settings.cuts[i].dissolve = 0.5 }
    }

    func setDissolve(cutID: UUID, _ length: Double) {
        guard let i = settings.cuts.firstIndex(where: { $0.id == cutID }) else { return }
        settings.cuts[i].dissolve = min(EditSettings.maxDissolve, max(0, length < 0.05 ? 0 : length))
    }

    var introOverlapLength: Double { settings.introOverlapLength(duration: duration) }
    var outroOverlapLength: Double { settings.outroOverlapLength(duration: duration) }

    /// Longest possible overlap of the intro/outro with the recording.
    func maxOverlap(intro: Bool) -> Double {
        guard let card = intro ? settings.intro : settings.outro else { return 0 }
        let kept = settings.keptSegments(duration: duration)
        guard let seg = intro ? kept.first : kept.last else { return 0 }
        return max(0, min(card.length - 0.2, timeMap.length(seg) / 2, EditSettings.maxDissolve))
    }

    func setOverlap(intro: Bool, _ length: Double) {
        let value = min(maxOverlap(intro: intro), max(0, length < 0.05 ? 0 : length))
        if intro { settings.introOverlap = value } else { settings.outroOverlap = value }
    }
}

extension EditorModel {
    /// Keyboard commands of the editor (see `EditorKeyHandler`).
    func perform(_ command: EditorKeyCommand) {
        guard voiceOverState == .idle else { return }
        switch command {
        case .step(let frames): step(by: Double(frames) / 30)
        case .stepSeconds(let seconds): step(by: seconds)
        case .home: step(by: display(playbackStart) - display(currentTime))
        case .end: step(by: displayEnd - display(currentTime))
        case .zoomIn: zoom(by: 2)
        case .zoomOut: zoom(by: 0.5)
        case .zoomFit: zoomToFit()
        case .split: splitAtPlayhead()
        case .undo: undo()
        case .redo: redo()
        case .toggleSnapping: snapping.toggle()
        case .deselect: selection = nil
        case .freeze: insertFreeze()
        case .chapter: addChapter()
        case .copy: copySelection()
        case .paste: pasteClipboard()
        case .shuttle(let direction): shuttle(direction)
        case .trimStart: trimToPlayhead(start: true)
        case .trimEnd: trimToPlayhead(start: false)
        case .addZoom: addZoomAtPlayhead()
        case .addText: addLowerThird()
        case .addMask: addMaskAtPlayhead()
        case .addArrow: addAnnotation(.arrow)
        case .addFrame: addAnnotation(.frame)
        case .addSpotlight: addAnnotation(.spotlight)
        case .addFinger: addAnnotation(.touch)
        case .addStep: addAnnotation(.step)
        case .selectRight: selectRightOfPlayhead()
        case .cycleTrimMode: cycleTrimMode()
        case .memeBoard: showMemeBoard.toggle()
        case .meme(let index): pressMeme(index)
        case .addCursor: addCursorRangeAtPlayhead()
        case .addImage: addImage()
        case .addVideo: addVideoOverlay()
        case .voiceOver: toggleVoiceOver()
        case .toggleMagnet: magnet.toggle()
        case .transition: addTransitionHere()
        case .join: joinClips()
        case .speed(let direction): changeSpeed(direction)
        }
    }
}

// MARK: - Undo / redo

extension EditorModel {
    /// Remembers the state before a burst of changes; the burst becomes one undo step.
    fileprivate func noteUndoable(_ old: EditSettings) {
        if undoBurstStart == nil { undoBurstStart = old }
        undoBurstTask?.cancel()
        guard !isInteracting else { return }   // committed when the drag ends
        undoBurstTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.commitUndoStep()
        }
    }

    /// Ends the current undo step (discrete actions such as split or delete call it before and
    /// after their change, so each is a step of its own).
    func commitUndoStep() {
        undoBurstTask?.cancel()
        undoBurstTask = nil
        guard let start = undoBurstStart else { return }
        undoBurstStart = nil
        guard start != settings else { return }
        undoStack.append(start)
        if undoStack.count > 200 { undoStack.removeFirst(undoStack.count - 200) }
        redoStack.removeAll()
        updateUndoState()
    }

    func undo() {
        commitUndoStep()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(settings)
        applyUndoState(previous)
    }

    func redo() {
        commitUndoStep()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(settings)
        applyUndoState(next)
    }

    private func applyUndoState(_ state: EditSettings) {
        applyingUndo = true
        settings = state
        applyingUndo = false
        dropStaleSelection()
        updateUndoState()
    }

    private func updateUndoState() {
        if canUndo != !undoStack.isEmpty { canUndo = !undoStack.isEmpty }
        if canRedo != !redoStack.isEmpty { canRedo = !redoStack.isEmpty }
    }

    /// Clears the selection if the selected item no longer exists (after undo/redo).
    func dropStaleSelection() {
        let exists: Bool
        switch selection {
        case .zoom(let id): exists = settings.zoomSegments.contains { $0.id == id }
        case .cut(let id): exists = settings.cuts.contains { $0.id == id }
        case .join(let key): exists = clipParts.contains { abs($0.key - key) < 1e-4 }
        case .mask(let id): exists = settings.masks.contains { $0.id == id }
        case .mute(let id): exists = settings.audioMutes.contains { $0.id == id }
        case .voiceOver(let id): exists = settings.voiceOvers.contains { $0.id == id }
        case .text(let id): exists = settings.texts.contains { $0.id == id }
        case .segment: exists = selectedSegment != nil
        case .freeze(let id): exists = settings.freezes.contains { $0.id == id }
        case .cameraLayout(let id): exists = settings.cameraLayouts.contains { $0.id == id }
        case .annotation(let id): exists = settings.annotations.contains { $0.id == id }
        case .image(let id): exists = settings.images.contains { $0.id == id }
        case .insert(let id): exists = settings.inserts.contains { $0.id == id }
        case .chapter(let id): exists = settings.chapters.contains { $0.id == id }
        case .videoOverlay(let id): exists = settings.videoOverlays.contains { $0.id == id }
        case .cursorRange(let id): exists = settings.cursorRanges.contains { $0.id == id }
        case .audioLane(let lane): exists = audioLanes.contains(lane)
        case .panel: exists = true
        case nil: return
        }
        if !exists { selection = nil }
    }
}

// MARK: - Split points and parts of the recording

extension EditorModel {
    /// Parts of the recording between split points (source time).
    var videoSegments: [ClosedRange<Double>] { settings.clipParts(duration: duration).map(\.range) }

    func segment(at t: Double) -> ClosedRange<Double>? {
        videoSegments.first { t >= $0.lowerBound && t < $0.upperBound } ?? videoSegments.last.flatMap { t >= $0.upperBound ? $0 : nil }
    }

    var selectedSegment: ClosedRange<Double>? {
        guard case .segment(let start) = selection else { return nil }
        return videoSegments.first { abs($0.lowerBound - start) < 1e-6 }
    }

    /// True if cuts remove the whole part.
    func isRemoved(_ segment: ClosedRange<Double>) -> Bool {
        settings.cuts.contains { $0.start <= segment.lowerBound + 1e-3 && $0.end >= segment.upperBound - 1e-3 }
    }

    /// Splits at the playhead: a selected voice-over clip under the playhead, else the recording.
    func splitAtPlayhead() {
        commitUndoStep(); defer { commitUndoStep() }   // one undo step of its own
        let t = currentTime
        let T = display(t)
        if let o = selectedVideoOverlay, case let range = displayRange(o), T > range.lowerBound + 0.1, T < range.upperBound - 0.1 {
            let first = T - range.lowerBound
            var second = o
            second.id = UUID()
            second.start = o.isFree ? T : t
            second.duration = o.duration - first
            if !o.synced { second.fileOffset = o.fileOffset + first }
            // Each half keeps its own movement (the second one's keyframes from its own start).
            let keys = Motion.split(o.keys, at: first)
            second.keys = keys.second
            updateVideoOverlay(id: o.id) { $0.duration = first; $0.keys = keys.first }
            settings.videoOverlays.append(second)
            selection = .videoOverlay(second.id)
            return
        }
        if let m = selectedMute, T > display(m.start) + 0.05, T < display(m.end) - 0.05 {
            var second = m
            second.id = UUID()
            second.start = t
            updateMute(id: m.id) { $0.end = t }
            settings.audioMutes.append(second)
            selectedMuteID = second.id
            return
        }
        if case .audioLane(let lane) = selection {
            splitLane(lane, at: t)
            return
        }
        if let clip = selectedVoiceOver, case let range = displayRange(clip),
           display(t) > range.lowerBound + 0.05, display(t) < range.upperBound - 0.05 {
            let firstLength = display(t) - range.lowerBound
            var second = VoiceOverClip(file: clip.file, fileOffset: clip.fileOffset + firstLength, start: clip.isFree ? display(t) : t,
                                       duration: clip.duration - firstLength)
            second.free = clip.free
            second.id = UUID()
            updateVoiceOver(id: clip.id) { $0.duration = firstLength }
            settings.voiceOvers.append(second)
            selectedVoiceOverID = second.id
            return
        }
        guard t > 0.05, t < duration - 0.05, !settings.splits.contains(where: { abs($0 - t) < 0.02 }) else { return }
        settings.splits = (settings.splits + [t]).sorted()
        if case .segment = selection { selection = segment(at: t).map { .segment($0.lowerBound) } }
    }

    /// Removes a part of the recording (it becomes a cut).
    func removeSegment(_ segment: ClosedRange<Double>) {
        commitUndoStep(); defer { commitUndoStep() }   // one undo step of its own
        guard !isRemoved(segment) else { return }
        // Never remove the last kept part (nothing would be left to export).
        var probe = settings
        probe.cuts.append(CutRange(start: segment.lowerBound, end: segment.upperBound))
        guard !probe.keptSegments(duration: duration).isEmpty else { return }
        settings.cuts.append(CutRange(start: segment.lowerBound, end: segment.upperBound))
        settings.cuts.sort { $0.start < $1.start }
        selection = nil
    }

}

// MARK: - Snapping

extension EditorModel {
    enum SnapEdge { case move, start, end }

    /// Timeline times edges snap to: recording start/end, trim points, split points, freeze frames,
    /// the playhead and the edges of all items except `id`.
    func snapTargets(excluding id: UUID?, includePlayhead: Bool = true) -> [Double] {
        var targets: [Double] = [0, timeMap.total, display(settings.trimStart), display(trimEnd)] + settings.splits.map(display)
        if includePlayhead { targets.append(display(currentTime)) }
        var source: [Double] = []
        for c in settings.cuts where c.id != id { source += [c.start, c.end] }
        for z in settings.zoomSegments where z.id != id { source += [z.start, z.end] }
        for m in settings.masks where m.id != id { source += [m.start, m.end] }
        for t in settings.overlayTexts where t.id != id {
            if t.isFree { targets += [t.start, t.end] } else { source += [t.start, t.end] }
        }
        for m in settings.audioMutes where m.id != id { source += [m.start, m.end] }
        for c in settings.cameraLayouts where c.id != id { source += [c.start, c.end] }
        for c in settings.cursorRanges where c.id != id { source += [c.start, c.end] }
        for a in settings.annotations where a.id != id { source += [a.start, a.end] }
        for i in settings.images where i.id != id {
            if i.isFree { targets += [i.start, i.end] } else { source += [i.start, i.end] }
        }
        for o in settings.videoOverlays where o.id != id { let r = displayRange(o); targets += [r.lowerBound, r.upperBound] }
        for c in settings.chapters where c.id != id { source.append(c.time) }
        targets += source.map(display)
        for f in settings.freezes where f.id != id {
            targets += [display(f.sourceRange.lowerBound), display(f.at)]
        }
        for v in settings.voiceOvers where v.id != id {
            let r = displayRange(v)
            targets += [r.lowerBound, r.upperBound]
        }
        return targets
    }

    /// `dt` adjusted so the dragged edge (or, when moving, the nearer of both edges) lands on a
    /// snap target within `tolerance` seconds. Shows the guide line.
    func snapDelta(_ edge: SnapEdge, dt: Double, start: Double, end: Double, tolerance: Double,
                   excluding id: UUID?) -> Double {
        guard snapping else { return dt }
        let targets = snapTargets(excluding: id)
        func nearest(_ t: Double) -> (delta: Double, target: Double)? {
            targets.lazy.map { ($0 - t, $0) }.filter { abs($0.0) <= tolerance }.min { abs($0.0) < abs($1.0) }
        }
        let candidates: [(delta: Double, target: Double)]
        switch edge {
        case .move: candidates = [nearest(start + dt), nearest(end + dt)].compactMap { $0 }
        case .start: candidates = [nearest(start + dt)].compactMap { $0 }
        case .end: candidates = [nearest(end + dt)].compactMap { $0 }
        }
        let best = candidates.min { abs($0.delta) < abs($1.delta) }
        if snapGuide != best?.target { snapGuide = best?.target }
        return dt + (best?.delta ?? 0)
    }

    /// A single time (playhead, trim point) snapped to the targets. A dragged trim point does not
    /// snap to the trim points themselves (it would stick to where it was).
    func snapTime(_ t: Double, tolerance: Double, excluding id: UUID? = nil, includePlayhead: Bool = true,
                  excludingTrim: Bool = false) -> Double {
        guard snapping else { return t }
        var targets = snapTargets(excluding: id, includePlayhead: includePlayhead)
        if excludingTrim {
            let trim = [display(settings.trimStart), display(trimEnd)]
            targets.removeAll { t in trim.contains { abs($0 - t) < 1e-9 } }
            targets += [0, timeMap.total]
        }
        let best = targets.filter { abs($0 - t) <= tolerance }.min { abs($0 - t) < abs($1 - t) }
        if snapGuide != best { snapGuide = best }
        return best ?? t
    }
}

// MARK: - Lower third placement

extension EditorModel {
    /// Fixed spots of the 3 × 3 position grid (anchor x/y and alignment per column).
    static let anchorColumns: [(x: Double, align: TextAlign)] = [(0.06, .left), (0.5, .center), (0.94, .right)]
    static let anchorRows: [Double] = [0.14, 0.5, 0.8]

    /// Cell of the position grid a lower third is in (nil if placed freely).
    func anchorCell(_ text: TextOverlay) -> (column: Int, row: Int)? {
        guard let column = Self.anchorColumns.firstIndex(where: { abs($0.x - text.x) < 0.015 && $0.align == text.align }),
              let row = Self.anchorRows.firstIndex(where: { abs($0 - text.y) < 0.025 }) else { return nil }
        return (column, row)
    }

    func placeLowerThird(id: UUID, column: Int, row: Int) {
        commitUndoStep(); defer { commitUndoStep() }   // one undo step of its own
        let c = Self.anchorColumns[column]
        updateText(id: id) { $0.x = c.x; $0.align = c.align; $0.y = Self.anchorRows[row] }
    }

    /// Anchor (x, y) of a box at `rect` (Core Image coordinates) for `align`.
    private func anchor(of rect: CGRect, align: TextAlign) -> (x: Double, y: Double) {
        let out = renderer.outputSize
        let ax = align == .left ? rect.minX : align == .center ? rect.midX : rect.maxX
        return (Double(ax / out.width), Double((out.height - rect.midY) / out.height))
    }

    /// Changes the text alignment of a lower third; its box stays where it is.
    func setTextAlign(id: UUID, _ align: TextAlign) {
        commitUndoStep(); defer { commitUndoStep() }   // one undo step of its own
        guard let text = settings.texts.first(where: { $0.id == id }), text.align != align else { return }
        let a = anchor(of: renderer.lowerThirdFrame(text), align: align)
        updateText(id: id) { $0.align = align; $0.x = a.x; $0.y = a.y }
    }

    /// Moves a lower third by a fraction of the output (from where the drag started). The box stays
    /// fully visible and snaps to the horizontal center.
    func moveLowerThird(id: UUID, from origin: TextOverlay, dx: Double, dy: Double) {
        let out = renderer.outputSize
        var proposed = origin
        proposed.x = origin.x + dx
        proposed.y = origin.y + dy
        var rect = FrameRenderer.lowerThirdRect(size: renderer.lowerThirdFrame(origin).size, proposed, out: out)
        let centered = abs(rect.midX - out.width / 2) < out.width * 0.012
        if centered { rect.origin.x = (out.width - rect.width) / 2 }
        if textCenterGuide != centered { textCenterGuide = centered }
        let a = anchor(of: rect, align: origin.align)
        updateText(id: id) { $0.x = a.x; $0.y = a.y }
    }
}

// MARK: - Adding in empty lanes

extension EditorModel {
    /// Default length of a new item in a lane.
    static func defaultLength(_ lane: TimelineHover.Lane) -> Double {
        lane == .text ? 4 : 3
    }

    /// Where a new item would go when clicking at timeline time `t` in an empty part of the lane
    /// (nil: no room). Timeline time.
    func freeRange(_ lane: TimelineHover.Lane, at t: Double) -> ClosedRange<Double>? {
        let total = timeMap.total
        guard t >= 0, t < total - 0.3 else { return nil }
        let items: [ClosedRange<Double>]
        switch lane {
        case .zoom: items = settings.zoomSegments.map { display($0.start)...display($0.end) }
        case .mask: items = settings.masks.map { display($0.start)...display($0.end) }
        case .text: items = settings.overlayTexts.map { display($0.start)...display($0.end) }
        case .cursor: items = settings.cursorRanges.map { display($0.start)...display($0.end) }
        case .media: items = settings.images.map { display($0.start)...display($0.end) }
            + settings.videoOverlays.map { display($0.start)...(display($0.start) + $0.duration) }
        case .annotation: items = settings.annotations.map { display($0.start)...display($0.end) }
        case .camera: items = settings.cameraLayouts.map { display($0.start)...display($0.end) }
        }
        guard !items.contains(where: { $0.contains(t) }) else { return nil }
        let next = items.map(\.lowerBound).filter { $0 > t }.min() ?? total
        let end = min(t + Self.defaultLength(lane), next, total)
        return end - t >= 0.5 ? t...end : nil
    }

    /// Adds an item over a timeline range.
    func add(_ lane: TimelineHover.Lane, range: ClosedRange<Double>) {
        let start = sourceTime(range.lowerBound), end = sourceTime(range.upperBound)
        switch lane {
        case .zoom: addZoom(start: start, length: end - start)
        case .mask: addMask(start: start, length: end - start)
        case .text: addLowerThird(start: start, length: end - start)
        case .annotation: addAnnotation(.frame, start: start, length: end - start)
        case .camera: addCameraLayout(start: start, length: end - start)
        case .cursor: addCursorRange(start: start, end: end)
        case .media:
            if let url = chooseFile([.image, .movie], message: "Bild oder Video zum Einblenden wählen") {
                drop([url], target: .overlay, at: start)
            }
        }
    }
}

// MARK: - Speed and freeze frames

extension EditorModel {
    /// Timeline range of a voice-over clip: it starts at its source moment and plays in real time.
    /// Voice-over clips with their start in timeline time (for layers and crossfades).
    func displayVoiceOvers(music: Bool) -> [VoiceOverClip] {
        settings.voiceOvers.filter { $0.isMusic == music }.map { clip in
            var c = clip
            let range = displayRange(clip)
            c.start = range.lowerBound
            c.duration = range.upperBound - range.lowerBound
            return c
        }
    }

    var selectedFreeze: FreezeFrame? {
        guard case .freeze(let id) = selection else { return nil }
        return settings.freezes.first { $0.id == id }
    }

    static let speedPresets: [Double] = [0.25, 0.5, 1, 1.5, 2, 4, 8]

    /// Speed of a part (nil if it has several).
    func speed(of segment: ClosedRange<Double>) -> Double? {
        // Source seconds per timeline second = playback speed.
        let rates = timeMap.pieces(in: segment).filter { !$0.isFreeze && $0.source.upperBound - $0.source.lowerBound > 0.01 }
            .map(\.rate)
        guard let first = rates.first else { return 1 }
        return rates.allSatisfy { abs($0 - first) < 1e-6 } ? first : nil
    }

    /// Plays a part faster (rate > 1) or slower.
    func setSpeed(_ rate: Double, for segment: ClosedRange<Double>) {
        var result: [SpeedRange] = []
        for r in settings.speeds {
            if r.end <= segment.lowerBound || r.start >= segment.upperBound {
                result.append(r)
            } else {
                if r.start < segment.lowerBound { result.append(SpeedRange(start: r.start, end: segment.lowerBound, rate: r.rate)) }
                if r.end > segment.upperBound { result.append(SpeedRange(start: segment.upperBound, end: r.end, rate: r.rate)) }
            }
        }
        let rate = min(16, max(0.1, rate))
        if abs(rate - 1) > 1e-3 { result.append(SpeedRange(start: segment.lowerBound, end: segment.upperBound, rate: rate)) }
        settings.speeds = result.sorted { $0.start < $1.start }
    }

    /// Inserts a freeze frame: at the end of the selected part, else at the playhead (2 s, ⌥F).
    func insertFreeze(duration: Double = 2) {
        commitUndoStep(); defer { commitUndoStep() }
        let at = selectedSegment?.upperBound ?? min(max(currentTime, 0), duration)
        insertFreeze(at: at, duration: duration)
    }

    func insertFreeze(at t: Double, duration length: Double) {
        let at = min(duration, max(FreezeFrame.span, t))
        if let existing = settings.freezes.first(where: { abs($0.at - at) < 1e-4 }) {
            selection = .freeze(existing.id)
            return
        }
        let freeze = FreezeFrame(at: at, duration: length)
        settings.freezes.append(freeze)
        settings.freezes.sort { $0.at < $1.at }
        selection = .freeze(freeze.id)
        if isPlaying { pause() }
        seek(to: freeze.sourceRange.lowerBound)
    }

    func setFreezeDuration(id: UUID, _ length: Double) {
        guard let i = settings.freezes.firstIndex(where: { $0.id == id }) else { return }
        settings.freezes[i].duration = min(60, max(0.2, length))
    }
}
