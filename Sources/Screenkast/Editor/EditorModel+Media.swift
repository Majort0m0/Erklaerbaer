import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Time ranges in timeline time

extension EditorModel {
    /// True if the playhead lies in the source range `start…end` (compared in timeline time, so
    /// items inside an inserted clip or freeze frame work too).
    func isVisibleNow(start: Double, end: Double) -> Bool {
        let T = display(currentTime)
        return T >= display(start) - 1e-6 && T <= display(end) + 1e-6
    }

    func isVisibleNow(videoOverlay o: VideoOverlay) -> Bool {
        let T = display(currentTime), r = displayRange(o)
        return T >= r.lowerBound - 1e-6 && T <= r.upperBound + 1e-6
    }

    /// Source range that starts at `start` and lasts `length` timeline seconds (kept on the recording).
    func sourceRange(from start: Double, timelineLength length: Double) -> (start: Double, end: Double) {
        let a = min(max(0, display(start)), max(0, timeMap.total - 0.2))
        return (sourceTime(a), timeMap.sourceEnd(min(timeMap.total, a + length)))
    }

    /// `start…end` kept on the recording and at least `minLength` timeline seconds long. Ranges that
    /// already fit stay exactly as they are.
    func clampedRange(_ start: Double, _ end: Double, minLength: Double) -> (start: Double, end: Double) {
        let total = timeMap.total
        let run = displayRun(start, end)
        var a = run?.lowerBound ?? display(start), b = run?.upperBound ?? display(end)
        if a >= 0, b <= total + 1e-9, b - a >= minLength - 1e-9 { return (start, end) }
        a = min(max(0, a), max(0, total - minLength))
        b = min(total, max(b, a + minLength))
        return (sourceTime(a), timeMap.sourceEnd(b))
    }

    /// Brings the playhead into the selected item, so its handles show on the right frame.
    func revealSelection() {
        guard !isPlaying, voiceOverState == .idle, !isInteracting else { return }
        var range: (Double, Double)?
        switch selection {
        case .mask(let id): range = settings.masks.first { $0.id == id }.map { ($0.start, $0.end) }
        case .annotation(let id): range = settings.annotations.first { $0.id == id }.map { ($0.start, $0.end) }
        case .image(let id):
            if let o = settings.images.first(where: { $0.id == id }) {
                range = o.isFree ? (sourceTime(o.start), timeMap.sourceEnd(o.end)) : (o.start, o.end)
            }
        case .text(let id):
            if let t = settings.texts.first(where: { $0.id == id }), t.kind == .lowerThird || t.placement == .overlay {
                range = t.isFree ? (sourceTime(t.start), timeMap.sourceEnd(t.end)) : (t.start, t.end)
            }
        case .videoOverlay(let id):
            if let o = settings.videoOverlays.first(where: { $0.id == id }) {
                let r = displayRange(o)
                range = (sourceTime(r.lowerBound), timeMap.sourceEnd(r.upperBound))
            }
        default: break
        }
        guard let (a, b) = range, !isVisibleNow(start: a, end: b) else { return }
        let A = display(a), B = display(b)
        seek(to: sourceTime(A + min(0.4, (B - A) / 2)))
    }
}

// MARK: - Video overlays (picture in picture)

extension EditorModel {
    var selectedVideoOverlay: VideoOverlay? {
        guard case .videoOverlay(let id) = selection else { return nil }
        return settings.videoOverlays.first { $0.id == id }
    }

    /// Asks for a video and shows it on top of the recording at the playhead.
    func addVideoOverlay() {
        guard let url = chooseFile([.movie], message: "Video zum Einblenden wählen") else { return }
        addVideoOverlay(url: url, at: currentTime)
    }

    /// Video overlay from a file (copied into the project), starting at source time `at`.
    func addVideoOverlay(url: URL, at: Double, center: CGPoint? = nil) {
        Task {
            let asset = AVURLAsset(url: url)
            guard let length = try? await asset.load(.duration).seconds, length > 0.1,
                  let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize), size.height > 0,
                  let file = importMedia(url) else { return }
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let shown = size.applying(transform)
            commitUndoStep(); defer { commitUndoStep() }
            let start = min(max(0, at), max(0, duration - 0.2))
            let available = max(0.2, timeMap.total - display(start))
            var o = VideoOverlay(file: file, name: url.deletingPathExtension().lastPathComponent, start: start,
                                 duration: min(length, available), fileDuration: length)
            o.aspect = abs(shown.width) / max(1, abs(shown.height))
            o.rotation = VideoRotation.degrees(transform)
            if let center { o.x = center.x; o.y = center.y }
            settings.videoOverlays.append(adopted(o))
            selection = .videoOverlay(o.id)
            if isPlaying { pause() }
        }
    }

    func updateVideoOverlay(id: UUID, _ change: (inout VideoOverlay) -> Void) {
        guard let i = settings.videoOverlays.firstIndex(where: { $0.id == id }) else { return }
        var o = settings.videoOverlays[i]
        change(&o)
        o.width = min(1, max(0.05, o.width))
        o.x = min(1, max(0, o.x))
        o.y = min(1, max(0, o.y))
        o.opacity = min(1, max(0.05, o.opacity))
        o.volume = min(2, max(0, o.volume))
        o.start = min(max(0, o.start), max(0, (o.isFree ? timeMap.total : duration) - 0.2))
        if !o.synced {
            o.fileOffset = min(max(0, o.fileOffset), max(0, o.fileDuration - 0.2))
            o.duration = min(max(0.2, o.duration), o.fileDuration - o.fileOffset)
        }
        o.duration = min(max(0.2, o.duration), max(0.2, timeMap.total - (o.isFree ? o.start : display(o.start))))
        settings.videoOverlays[i] = o
    }

    /// The second window recorded with the screen becomes an overlay over the whole recording.
    func addSyncedOverlayIfNeeded() {
        guard let file = project.info.overlayVideoFile,
              !settings.videoOverlays.contains(where: { $0.synced && $0.file == file }),
              !settings.dismissedSyncedOverlay,
              FileManager.default.fileExists(atPath: project.url.appendingPathComponent(file).path) else { return }
        var o = VideoOverlay(file: file, name: project.info.overlaySourceName ?? "Zweites Fenster", start: 0,
                             duration: timeMap.total, fileDuration: duration, synced: true)
        o.aspect = project.info.overlayAspect ?? 16.0 / 9.0
        o.x = 0.74; o.y = 0.3; o.width = 0.4
        settings.videoOverlays.append(o)
    }
}

// MARK: - Drag and drop of media

extension EditorModel {
    enum DropTarget { case mainTrack, overlay, audio, music, narration, preview(CGPoint) }

    static let droppableTypes: [UTType] = [.fileURL]

    /// Kind of a dropped file.
    enum MediaKind { case image, movie, audio }

    static func mediaKind(_ url: URL) -> MediaKind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .movie }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }

    /// Adds dropped files at source time `at`: on the video lane a movie becomes an inserted clip,
    /// on the overlay lanes and the preview pictures and movies are shown on top, audio becomes
    /// the background music. Returns false if nothing could be used.
    @discardableResult
    func drop(_ urls: [URL], target: DropTarget, at: Double) -> Bool {
        var used = false
        var time = min(max(0, at), max(0, duration - 0.2))
        for url in urls {
            guard let kind = Self.mediaKind(url) else { continue }
            switch (kind, target) {
            case (.movie, .mainTrack):
                insertClip(url: url, at: time)
            case (.movie, .preview(let p)):
                addVideoOverlay(url: url, at: time, center: p)
            case (.movie, _):
                addVideoOverlay(url: url, at: time)
            case (.image, .preview(let p)):
                addImage(url: url, at: time, center: p)
            case (.image, _):
                addImage(url: url, at: time)
            case (.audio, .narration):
                addNarrationFile(url: url, at: time)
            case (.audio, .music):
                addMusicClip(url: url, atTimeline: display(time))
            case (.audio, _):
                setMusic(url: url)
            }
            used = true
            time = min(duration - 0.2, sourceTime(display(time) + 0.5))
        }
        return used
    }

    /// Picture from a file at source time `at` (4 timeline seconds).
    func addImage(url: URL, at: Double, center: CGPoint? = nil) {
        guard let file = importMedia(url) else { return }
        commitUndoStep(); defer { commitUndoStep() }
        let r = sourceRange(from: at, timelineLength: 4)
        var image = ImageOverlay(file: file, start: r.start, end: r.end)
        if let center { image.x = center.x; image.y = center.y }
        settings.images.append(adopted(image))
        selection = .image(image.id)
        if isPlaying { pause() }
    }
}

// MARK: - Text designs

/// Text designs saved by the user (shared by all projects).
enum TextDesignLibrary {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Screenkast")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("text-designs.json")
    }

    static func load() -> [TextDesign] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([TextDesign].self, from: $0) } ?? []
    }

    static func save(_ designs: [TextDesign]) {
        if let data = try? JSONEncoder().encode(designs) { try? data.write(to: url, options: .atomic) }
    }

    /// Built-in designs followed by the saved ones.
    static var all: [TextDesign] { TextDesign.presets + load() }

    static func add(_ d: TextDesign) { save(load() + [d]) }
    static func remove(_ id: UUID) { save(load().filter { $0.id != id }) }
}

extension EditorModel {
    /// Gives one text a design (a copy, so editing it later changes only this text).
    func setTextDesign(id: UUID, _ design: TextDesign) {
        commitUndoStep(); defer { commitUndoStep() }
        updateText(id: id) { $0.design = design }
        settings.textDesign = design
    }

    /// Edits the design of one text (from the design editor).
    func editTextDesign(id: UUID, _ change: (inout TextDesign) -> Void) {
        guard let text = settings.texts.first(where: { $0.id == id }) else { return }
        var d = text.look
        change(&d)
        updateText(id: id) { $0.design = d }
        settings.textDesign = d
    }

    /// One look for all lower thirds and title cards.
    func applyDesignToAllTexts(_ design: TextDesign) {
        commitUndoStep(); defer { commitUndoStep() }
        for i in settings.texts.indices { settings.texts[i].design = design }
        settings.textDesign = design
    }

    func saveTextDesign(_ design: TextDesign) {
        let alert = NSAlert()
        alert.messageText = "Design sichern"
        alert.informativeText = "Unter welchem Namen? Gesicherte Designs stehen in allen Projekten zur Verfügung."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = design.name == "Eigenes Design" || TextDesign.presets.contains(where: { $0.id == design.id })
            ? "Mein Design" : design.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Sichern")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        TextDesignLibrary.add(design.copy(named: name.isEmpty ? "Mein Design" : name))
        objectWillChange.send()
    }

    /// Picture (logo) inside a lower third or above a title card's text.
    func chooseTextImage(id: UUID) {
        guard let url = chooseFile([.image], message: "Bild oder Logo für den Text wählen"), let file = importMedia(url) else { return }
        commitUndoStep(); defer { commitUndoStep() }
        updateText(id: id) { $0.image = file }
    }

    // Pictures

    func applyFrameToAllImages(_ frame: PictureFrame, shadow: Bool) {
        commitUndoStep(); defer { commitUndoStep() }
        for i in settings.images.indices { settings.images[i].frame = frame; settings.images[i].shadow = shadow }
        for i in settings.videoOverlays.indices { settings.videoOverlays[i].frame = frame; settings.videoOverlays[i].shadow = shadow }
    }
}

// MARK: - Levels

extension EditorModel {
    enum LevelState: Equatable { case idle, measuring, done(String) }

    /// Measures every lane and sets the volume sliders (speech in front, system sound and music below).
    func autoLevel() async {
        levelState = .measuring
        let levels = await AudioMastering.measure(project: project, settings: settings)
        let v = AudioMastering.suggestedVolumes(levels)
        commitUndoStep(); defer { commitUndoStep() }
        if let m = v.mic { settings.micVolume = m; settings.micMuted = false }
        if let s = v.system { settings.systemVolume = s }
        if let o = v.voiceOver { settings.voiceOverVolume = o; settings.voiceOverMuted = false }
        if let m = v.music { settings.music?.volume = m }
        func lufs(_ x: Double?) -> String? { x.flatMap { $0.isFinite ? String(format: "%.0f", $0) : nil } }
        var parts: [String] = []
        if let m = lufs(levels.mic) { parts.append("Mikrofon \(m)" + (levels.micHasSpeech ? "" : " (keine Sprache, unverändert)")) }
        if let s = lufs(levels.system) { parts.append("Systemton \(s)") }
        if let o = lufs(levels.voiceOver) { parts.append("Voice-over \(o)") }
        if let m = lufs(levels.music) { parts.append("Musik \(m)") }
        var note = parts.isEmpty ? "Keine Tonspur zum Messen." : "Gemessen (LUFS): " + parts.joined(separator: ", ") + ". Regler gesetzt."
        if v.quietBy > 3 {
            note += String(format: " Insgesamt %.0f dB zu leise – „Stimme verbessern“ oder die Gesamtlautstärke beim Export gleicht das aus.", v.quietBy)
        }
        levelState = .done(note)
    }
}

// MARK: - Formats, preview clicks

extension EditorModel {
    /// Switches the output format; each format keeps its own layout (portrait: recording at the
    /// top, camera large at the bottom, captions in between).
    func setAspect(_ aspect: OutputAspect) {
        guard aspect != settings.aspect else { return }
        commitUndoStep(); defer { commitUndoStep() }
        settings.switchAspect(to: aspect)
    }

    func resetLayout() {
        commitUndoStep(); defer { commitUndoStep() }
        settings.apply(FormatLayout.standard(for: settings.aspect))
    }

    /// What is under a point of the preview (view coordinates, origin top-left), topmost first:
    /// captions, logo, pictures, texts, camera, video overlays, annotations, masks.
    func previewElement(at p: CGPoint, viewSize: CGSize) -> EditorSelection? {
        let out = renderer.outputSize
        guard viewSize.width > 0 else { return nil }
        let k = out.width / viewSize.width
        let q = CGPoint(x: p.x * k, y: p.y * k)                 // output pixels, top-left origin
        let ci = CGPoint(x: q.x, y: out.height - q.y)           // Core Image: bottom-left origin
        let t = currentTime
        let slack = 6 * k
        func hit(_ r: CGRect?) -> Bool { r.map { $0.insetBy(dx: -slack, dy: -slack).contains(ci) } ?? false }

        if hit(renderer.captionFrame(at: t)) { return .panel(.captions) }
        if let w = settings.watermark, hit(renderer.watermarkFrame(w, out: out)) { return .panel(.logo) }
        for o in settings.images.reversed() where isVisibleNow(image: o) {
            if hit(renderer.imageFrame(o, out: out)) { return .image(o.id) }
        }
        for text in settings.overlayTexts.reversed() where isVisibleNow(text: text) {
            if text.kind == .titleCard { return .text(text.id) }
            if hit(renderer.lowerThirdFrame(text)) { return .text(text.id) }
        }
        if hasCamera {
            let cam = FrameRenderer.cameraState(at: t, settings: settings)
            if cam.full > 0.5 { return .panel(.camera) }
            if cam.alpha > 0.3,
               hit(FrameRenderer.cameraRect(settings: settings, out: out, cameraAspect: cameraAspect, scale: cam.scale).rect) {
                return .panel(.camera)
            }
        }
        for o in settings.videoOverlays.reversed() where isVisibleNow(videoOverlay: o) {
            if hit(FrameRenderer.videoOverlayFrame(o, out: out)) { return .videoOverlay(o.id) }
        }
        // Annotations and masks live on the recording (normalized, zoomed with it).
        let n = renderer.normalizedPoint(fromOutput: q, at: t)
        let tolerance = 14 * k / max(1, out.width)
        for a in settings.annotations.reversed() where isVisibleNow(start: a.start, end: a.end) {
            if a.kind == .arrow {
                let d = ShotDocument.distance(n, segment: CGPoint(x: a.x, y: a.y), CGPoint(x: a.x + a.width, y: a.y + a.height))
                if d < tolerance * 2 { return .annotation(a.id) }
            } else if CGRect(x: min(a.x, a.x + a.width), y: min(a.y, a.y + a.height), width: abs(a.width), height: abs(a.height))
                        .insetBy(dx: -tolerance, dy: -tolerance).contains(n) {
                return .annotation(a.id)
            }
        }
        for m in settings.masks.reversed() where isVisibleNow(start: m.start, end: m.end) {
            if CGRect(x: m.x, y: m.y, width: m.width, height: m.height).contains(n) { return .mask(m.id) }
        }
        return nil
    }

    /// A click in the preview selects what is there (its settings open); a click on nothing ends
    /// the selection, or plays/pauses when nothing was selected.
    func previewClicked(at p: CGPoint, viewSize: CGSize) {
        if let element = previewElement(at: p, viewSize: viewSize) {
            if isPlaying { pause() }
            selection = element
        } else if selection != nil || transcriptSelection != nil {
            selection = nil
            transcriptSelection = nil
        } else {
            togglePlay()
        }
    }
}

// MARK: - Own audio as narration

extension EditorModel {
    func addNarrationFile() {
        guard let url = chooseFile([.audio, .movie], message: "Sprachaufnahme (Audiodatei) für die Voice-over-Spur wählen") else { return }
        addNarrationFile(url: url, at: currentTime)
    }

    /// An audio file recorded elsewhere becomes a voice-over clip at source time `at` (from its
    /// start, as long as the video allows); captions can be made from it.
    func addNarrationFile(url: URL, at: Double) {
        Task {
            let asset = AVURLAsset(url: url)
            guard let length = try? await asset.load(.duration).seconds, length > 0.1,
                  (try? await asset.loadTracks(withMediaType: .audio).first) != nil,
                  let file = importMedia(url) else { return }
            commitUndoStep(); defer { commitUndoStep() }
            let start = min(max(0, at), max(0, duration - 0.2))
            let available = max(0.2, timeMap.total + outroLead - display(start))
            let clip = VoiceOverClip(file: file, fileOffset: 0, start: start, duration: min(length, available))
            settings.voiceOvers.append(adopted(clip))
            selectedVoiceOverID = clip.id
            loadVoiceOverWaveform(file)
            if isPlaying { pause() }
        }
    }
}
