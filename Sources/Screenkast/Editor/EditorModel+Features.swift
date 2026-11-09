import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Pauses

extension EditorModel {
    /// Peaks of the speech track (microphone, else system audio).
    private var speechPeaks: [Float]? { waveforms["mic"] ?? waveforms["system"] }

    /// Pauses that "Pausen entfernen" would cut: inside the kept part, not under a voice-over,
    /// not already removed (source time).
    var detectedPauses: [ClosedRange<Double>] {
        guard let peaks = speechPeaks else { return [] }
        let kept = settings.keptSegments(duration: duration)
        let narration = settings.voiceOvers.compactMap { clip -> ClosedRange<Double>? in
            let r = displayRange(clip)
            let a = sourceTime(r.lowerBound), b = timeMap.sourceEnd(r.upperBound)
            return b > a ? a...b : nil
        }
        return PauseDetector.pauses(peaks, options: pauseOptions).filter { p in
            kept.contains { $0.lowerBound <= p.lowerBound && $0.upperBound >= p.upperBound }
                && !narration.contains { $0.overlaps(p) }
        }
    }

    /// Cuts all detected pauses (one undo step).
    func removePauses() {
        let pauses = detectedPauses
        guard !pauses.isEmpty else { return }
        commitUndoStep(); defer { commitUndoStep() }
        settings.cuts += pauses.map {
            CutRange(start: $0.lowerBound, end: $0.upperBound, dissolve: CutRange.speechCrossfade, origin: .pause)
        }
        settings.cuts.sort { $0.start < $1.start }
    }
}

// MARK: - Transcript

extension EditorModel {
    /// Filler sounds per language. Only sounds that are never real words: in German "er" (he) and
    /// "um" (at) are words, so they are not on the German list.
    static func fillerWords(language: String) -> Set<String> {
        switch language.prefix(2) {
        case "de": return ["äh", "ähm", "äähm", "ähh", "öhm", "öh", "hm", "hmm", "mhm", "ehm", "ähem", "äh,", "ähm,"]
        case "en": return ["uh", "uhm", "um", "umm", "erm", "er", "ah", "hmm", "mm", "mhm"]
        case "fr": return ["euh", "heu", "bah", "hum", "hmm"]
        case "es": return ["eh", "em", "este", "mmm", "hmm"]
        case "it": return ["ehm", "eh", "mmm", "hmm"]
        default: return ["hmm", "mhm"]
        }
    }

    static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// True if cuts remove the word (its middle).
    func isWordRemoved(_ i: Int) -> Bool {
        guard settings.words.indices.contains(i) else { return false }
        let w = settings.words[i]
        let mid = (w.start + w.end) / 2
        return settings.cuts.contains { mid >= $0.start && mid <= $0.end }
            || mid < settings.trimStart || mid > trimEnd
    }

    /// Index of the word being spoken at the playhead.
    var currentWordIndex: Int? {
        let t = currentTime
        return settings.words.lastIndex { $0.start <= t + 0.02 }.flatMap { i in t <= settings.words[i].end + 0.25 ? i : nil }
    }

    /// Source range a run of words takes, including the gap up to the next word.
    func wordRange(_ r: ClosedRange<Int>) -> ClosedRange<Double> {
        let words = settings.words
        let first = words[r.lowerBound], last = words[r.upperBound]
        let before = r.lowerBound > 0 ? words[r.lowerBound - 1].end : 0
        let after = r.upperBound + 1 < words.count ? words[r.upperBound + 1].start : duration
        let start = max(before, first.start - 0.03)
        let end = max(last.end, min(after - 0.03, last.end + 0.6))
        return start...end
    }

    /// Cuts the words (one undo step).
    func cutWords(_ r: ClosedRange<Int>) {
        guard r.lowerBound >= 0, r.upperBound < settings.words.count else { return }
        commitUndoStep(); defer { commitUndoStep() }
        let range = wordRange(r)
        settings.cuts.append(CutRange(start: range.lowerBound, end: range.upperBound, dissolve: CutRange.speechCrossfade, origin: .transcript))
        settings.cuts.sort { $0.start < $1.start }
        transcriptSelection = nil
    }

    /// Brings removed words back (removes the cuts over them).
    func restoreWords(_ r: ClosedRange<Int>) {
        guard r.lowerBound >= 0, r.upperBound < settings.words.count else { return }
        commitUndoStep(); defer { commitUndoStep() }
        let range = wordRange(r)
        var result: [CutRange] = []
        for cut in settings.cuts {
            if cut.end <= range.lowerBound || cut.start >= range.upperBound {
                result.append(cut)
            } else {
                if cut.start < range.lowerBound - 0.05 { result.append(CutRange(start: cut.start, end: range.lowerBound)) }
                if cut.end > range.upperBound + 0.05 { result.append(CutRange(start: range.upperBound, end: cut.end)) }
            }
        }
        settings.cuts = result
        transcriptSelection = nil
    }

    /// Filler words ("äh", "ähm" …) and repeated words ("die die") that are still in the video.
    var fillerWordIndices: [Int] {
        let words = settings.words
        let fillers = Self.fillerWords(language: settings.captionLanguage)
        return words.indices.filter { i in
            guard !isWordRemoved(i) else { return false }
            let w = Self.normalized(words[i].text)
            if fillers.contains(w) { return true }
            // A repeated word: the first of two equal neighbours.
            return i + 1 < words.count && w.count > 1 && w == Self.normalized(words[i + 1].text)
                && words[i + 1].start - words[i].end < 0.6
        }
    }

    /// Cuts every filler word (one undo step).
    func removeFillerWords() {
        let indices = fillerWordIndices
        guard !indices.isEmpty else { return }
        commitUndoStep(); defer { commitUndoStep() }
        for i in indices {
            let w = settings.words[i]
            settings.cuts.append(CutRange(start: max(0, w.start - 0.03), end: w.end + 0.03, dissolve: CutRange.speechCrossfade, origin: .filler))
        }
        settings.cuts.sort { $0.start < $1.start }
    }
}

// MARK: - Media import

extension EditorModel {
    /// Copies a file into the project ("media/…") and returns its relative path.
    func importMedia(_ url: URL) -> String? {
        let folder = project.url.appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Already in this project (library): used as it is.
        if url.standardizedFileURL.deletingLastPathComponent() == folder.standardizedFileURL { return "media/\(url.lastPathComponent)" }
        let name = "media/\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)"
        do {
            try FileManager.default.copyItem(at: url, to: project.url.appendingPathComponent(name))
            return name
        } catch {
            loadError = nil
            voiceOverError = "Datei konnte nicht übernommen werden: \(error.localizedDescription)"
            return nil
        }
    }

    func chooseFile(_ types: [UTType], message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    // Music

    func chooseMusic() {
        guard let url = chooseFile([.audio], message: "Musik für den Hintergrund wählen") else { return }
        setMusic(url: url)
    }

    func chooseMusicClip() {
        guard let url = chooseFile([.audio], message: "Audiodatei für die Musikspur wählen") else { return }
        addMusicClip(url: url, atTimeline: display(currentTime))
    }

    func setMusic(url: URL) {
        guard let file = importMedia(url) else { return }
        commitUndoStep(); defer { commitUndoStep() }
        var music = settings.music ?? BackgroundMusic(file: file, name: url.deletingPathExtension().lastPathComponent)
        music.file = file
        music.name = url.deletingPathExtension().lastPathComponent
        music.fileOffset = 0
        settings.music = music
        loadMusicWaveform()
    }

    func removeMusic() {
        commitUndoStep(); defer { commitUndoStep() }
        settings.music = nil
    }

    /// Length of the music file (from its waveform).
    var musicLength: Double? {
        settings.music.flatMap { waveforms["music:" + $0.file] }.map { Double($0.count) / Waveform.rate }
    }

    // Logo

    func chooseCameraBackground() {
        guard let url = chooseFile([.image], message: "Bild für den Hintergrund der Kamera wählen"), let file = importMedia(url) else { return }
        commitUndoStep(); defer { commitUndoStep() }
        settings.cameraBackground = file
    }

    func chooseWatermark() {
        guard let url = chooseFile([.image], message: "Logo wählen (PNG mit transparentem Hintergrund eignet sich am besten)"),
              let file = importMedia(url) else { return }
        commitUndoStep(); defer { commitUndoStep() }
        var w = settings.watermark ?? Watermark(file: file)
        w.file = file
        settings.watermark = w
    }

    // Pictures

    var selectedImage: ImageOverlay? {
        guard case .image(let id) = selection else { return nil }
        return settings.images.first { $0.id == id }
    }

    func addImage() {
        guard let url = chooseFile([.image], message: "Bild zum Einblenden wählen") else { return }
        addImage(url: url, at: currentTime)
    }

    func updateImage(id: UUID, _ change: (inout ImageOverlay) -> Void) {
        guard let i = settings.images.firstIndex(where: { $0.id == id }) else { return }
        var o = settings.images[i]
        change(&o)
        o.width = min(1, max(0.03, o.width))
        o.x = min(1, max(0, o.x))
        o.y = min(1, max(0, o.y))
        o.opacity = min(1, max(0.05, o.opacity))
        if o.isFree {
            o.start = min(max(0, o.start), max(0, timeMap.total - 0.2))
            o.end = min(timeMap.total, max(o.end, o.start + 0.2))
        } else {
            (o.start, o.end) = clampedRange(o.start, o.end, minLength: 0.2)
        }
        settings.images[i] = o
    }

    // Inserted clips

    var selectedInsert: InsertClip? {
        guard case .insert(let id) = selection else { return nil }
        return settings.inserts.first { $0.id == id }
    }

    /// Inserts a video file at the end of the selected part, else at the playhead.
    func addInsertClip() {
        guard let url = chooseFile([.movie], message: "Videoclip zum Einfügen wählen") else { return }
        insertClip(url: url, at: selectedSegment?.upperBound ?? min(max(currentTime, 0), duration))
    }

    /// Inserts a video file at source time `at` (the recording waits while it plays).
    func insertClip(url: URL, at: Double) {
        Task {
            let asset = AVURLAsset(url: url)
            guard let length = try? await asset.load(.duration).seconds, length > 0.1,
                  let file = importMedia(url) else { return }
            let transform = (try? await asset.loadTracks(withMediaType: .video).first?.load(.preferredTransform)) ?? .identity
            var clip = InsertClip(file: file, name: url.deletingPathExtension().lastPathComponent, at: at,
                                  duration: length, fileDuration: length)
            let rotation = VideoRotation.degrees(transform)
            if rotation != 0 { clip.rotation = rotation }
            placeInsert(clip)
        }
    }

    /// Adds an inserted clip at its `at`. In an empty project the clips line up one after the
    /// other (dropped onto a clip: behind it), and the black canvas around the row is cut off
    /// as long as nothing else lies on it (the trim handles pull it back for titles on black).
    func placeInsert(_ new: InsertClip) {
        commitUndoStep(); defer { commitUndoStep() }
        var clip = new
        let blank = project.info.blank == true
        // Clips in an empty project touch (no black between them); elsewhere they keep a little
        // distance from freeze frames.
        let gap = blank ? FreezeFrame.span : 3 * FreezeFrame.span
        let before = settings.inserts.sorted { $0.at < $1.at }
        let autoTrim = blank && blankTrimIsAutomatic(row: before)
        if blank {
            if before.isEmpty {
                clip.at = min(1, duration / 2)
            } else if let next = before.first(where: { clip.at < $0.at - FreezeFrame.span }) {
                if next.id == before.first?.id, next.at - gap >= FreezeFrame.span {
                    clip.at = next.at - gap                       // in front of the row
                } else {
                    clip.at = next.at                             // between two clips: make room
                    shiftSourceTimes(from: next.sourceRange.lowerBound - 1e-9, clipsFrom: next.at - 1e-9, by: gap)
                }
            } else {
                clip.at = (before.last?.at ?? 0) + gap            // at the end of the row
            }
        } else {
            // Not on top of a freeze frame at the same moment.
            clip.at = max(FreezeFrame.span, clip.at)
            if settings.freezes.contains(where: { abs($0.at - clip.at) < gap }) { clip.at -= gap }
        }
        settings.inserts.append(clip)
        if autoTrim { applyBlankTrim() }
        selection = .insert(clip.id)
    }

    /// Trim of an empty project exactly around its row of clips (nil: no clips).
    private func blankTrim(row: [InsertClip]) -> (start: Double, end: Double)? {
        guard let first = row.map(\.sourceRange.lowerBound).min(), let last = row.map(\.sourceRange.upperBound).max() else { return nil }
        return (first, min(duration, last))
    }

    /// The trim still is the automatic one and nothing (texts, pictures, sound) lies on the black.
    private func blankTrimIsAutomatic(row: [InsertClip]) -> Bool {
        let inClip: (Double) -> Bool = { t in row.contains { $0.sourceRange.contains(t) } }
        let s = settings
        let starts = s.texts.map(\.start) + s.images.map(\.start) + s.videoOverlays.map(\.start) + s.voiceOvers.map(\.start)
            + s.annotations.map(\.start) + s.captions.map(\.start)
        guard starts.allSatisfy(inClip) else { return false }
        guard let auto = blankTrim(row: row) else { return s.trimStart == 0 && s.trimEnd == nil }
        return abs(s.trimStart - auto.start) < 1e-6 && abs((s.trimEnd ?? duration) - auto.end) < 1e-6
    }

    private func applyBlankTrim() {
        guard let t = blankTrim(row: settings.inserts) else { return }
        settings.trimStart = t.start
        settings.trimEnd = t.end >= duration - 0.001 ? nil : t.end
    }

    /// Moves everything at or after source time `from` later by `delta` (room for a clip in an
    /// empty project; items inside the moved clips move with them). Clips are moved from
    /// `clipsFrom` on (the clip before ends where the next one begins).
    private func shiftSourceTimes(from: Double, clipsFrom: Double, by delta: Double) {
        func move(_ t: inout Double) { if t >= from { t += delta } }
        func range<T>(_ items: inout [T], _ a: WritableKeyPath<T, Double>, _ b: WritableKeyPath<T, Double>? = nil) {
            for i in items.indices {
                move(&items[i][keyPath: a])
                if let b { move(&items[i][keyPath: b]) }
            }
        }
        for i in settings.inserts.indices where settings.inserts[i].at >= clipsFrom { settings.inserts[i].at += delta }
        range(&settings.texts, \.start, \.end)
        range(&settings.images, \.start, \.end)
        range(&settings.videoOverlays, \.start)
        range(&settings.voiceOvers, \.start)
        range(&settings.annotations, \.start, \.end)
        range(&settings.masks, \.start, \.end)
        range(&settings.captions, \.start, \.end)
        range(&settings.words, \.start, \.end)
        range(&settings.audioMutes, \.start, \.end)
        range(&settings.cuts, \.start, \.end)
        range(&settings.zoomSegments, \.start, \.end)
        range(&settings.speeds, \.start, \.end)
        range(&settings.cameraLayouts, \.start, \.end)
        range(&settings.cursorRanges, \.start, \.end)
        range(&settings.freezes, \.at)
        range(&settings.chapters, \.time)
        for i in settings.splits.indices { move(&settings.splits[i]) }
    }

    func updateInsert(id: UUID, _ change: (inout InsertClip) -> Void) {
        guard let i = settings.inserts.firstIndex(where: { $0.id == id }) else { return }
        var c = settings.inserts[i]
        change(&c)
        c.fileOffset = min(max(0, c.fileOffset), max(0, c.fileDuration - 0.2))
        c.duration = min(max(0.2, c.duration), c.fileDuration - c.fileOffset)
        c.volume = min(1, max(0, c.volume))
        settings.inserts[i] = c
    }
}

// MARK: - Camera layouts and annotations

extension EditorModel {
    var selectedCameraLayout: CameraLayoutRange? {
        guard case .cameraLayout(let id) = selection else { return nil }
        return settings.cameraLayouts.first { $0.id == id }
    }

    func addCameraLayout(start: Double, length: Double = 3, layout: CameraLayout = .large) {
        commitUndoStep(); defer { commitUndoStep() }
        let end = min(duration, start + length)
        guard end - start > 0.3 else { return }
        let range = CameraLayoutRange(start: start, end: end, layout: layout)
        settings.cameraLayouts.append(range)
        settings.cameraLayouts.sort { $0.start < $1.start }
        selection = .cameraLayout(range.id)
    }

    func updateCameraLayout(id: UUID, _ change: (inout CameraLayoutRange) -> Void) {
        guard let i = settings.cameraLayouts.firstIndex(where: { $0.id == id }) else { return }
        var r = settings.cameraLayouts[i]
        change(&r)
        (r.start, r.end) = clampedRange(r.start, r.end, minLength: 0.3)
        settings.cameraLayouts[i] = r
    }

    var selectedAnnotation: Annotation? {
        guard case .annotation(let id) = selection else { return nil }
        return settings.annotations.first { $0.id == id }
    }

    func addAnnotation(_ kind: AnnotationKind, start: Double? = nil, length: Double = 3) {
        commitUndoStep(); defer { commitUndoStep() }
        let r = sourceRange(from: start ?? currentTime, timelineLength: kind == .touch ? min(length, 1.5) : length)
        let from = r.start
        var a = Annotation(kind: kind, start: r.start, end: r.end)
        // Near the cursor if it is on screen at that moment.
        if let p = renderer.cursorPosition(at: from), p.x > 0.05, p.x < 0.95, p.y > 0.05, p.y < 0.95 {
            switch kind {
            case .arrow:
                a.x = min(0.95, p.x + 0.12); a.y = min(0.95, p.y + 0.12); a.width = p.x - a.x; a.height = p.y - a.y
            case .frame, .spotlight:
                a.width = 0.22; a.height = 0.14
                a.x = min(1 - a.width, max(0, p.x - a.width / 2)); a.y = min(1 - a.height, max(0, p.y - a.height / 2))
            case .touch:
                a.x = p.x; a.y = p.y; a.width = 0.14; a.height = 0
            case .step:
                a.x = p.x; a.y = p.y; a.width = 0; a.height = 0
            }
        } else if kind == .arrow {
            a.x = 0.62; a.y = 0.62; a.width = -0.14; a.height = -0.14
        } else if kind == .touch {
            a.x = 0.5; a.y = 0.5; a.width = 0.14; a.height = 0
        } else if kind == .step {
            a.x = 0.5; a.y = 0.5; a.width = 0; a.height = 0
        }
        if kind == .touch { a.color = .blue }
        if kind == .spotlight { a.color = .white }
        settings.annotations.append(a)
        selection = .annotation(a.id)
        if isPlaying { pause() }
    }

    func updateAnnotation(id: UUID, _ change: (inout Annotation) -> Void) {
        guard let i = settings.annotations.firstIndex(where: { $0.id == id }) else { return }
        var a = settings.annotations[i]
        change(&a)
        a.thickness = min(3, max(0.4, a.thickness))
        (a.start, a.end) = clampedRange(a.start, a.end, minLength: 0.2)
        if a.kind != .arrow {
            a.width = min(1, max(0.02, a.width))
            a.height = min(1, max(0.02, a.height))
            a.x = min(1 - a.width, max(0, a.x))
            a.y = min(1 - a.height, max(0, a.y))
        } else {
            a.x = min(1, max(0, a.x)); a.y = min(1, max(0, a.y))
            a.width = min(1 - a.x, max(-a.x, a.width)); a.height = min(1 - a.y, max(-a.y, a.height))
        }
        settings.annotations[i] = a
    }
}

// MARK: - Chapters

extension EditorModel {
    var selectedChapter: Chapter? {
        guard case .chapter(let id) = selection else { return nil }
        return settings.chapters.first { $0.id == id }
    }

    /// Chapter mark at the playhead (M).
    func addChapter() {
        commitUndoStep(); defer { commitUndoStep() }
        let t = min(max(0, currentTime), duration)
        if let existing = settings.chapters.first(where: { abs(display($0.time) - display(t)) < 0.2 }) {
            selection = .chapter(existing.id)
            return
        }
        let chapter = Chapter(time: t, title: "Kapitel \(settings.chapters.count + 1)")
        settings.chapters.append(chapter)
        settings.chapters.sort { $0.time < $1.time }
        selection = .chapter(chapter.id)
    }

    func updateChapter(id: UUID, _ change: (inout Chapter) -> Void) {
        guard let i = settings.chapters.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.chapters[i])
        settings.chapters[i].time = min(max(0, settings.chapters[i].time), duration)
    }

    /// Position of a source moment in the exported video (nil if it is cut out).
    func outputTime(ofSource t: Double) -> Double? {
        timeMap.contains(source: t) ? introLead + display(t) : nil
    }

    /// Chapters in output time, sorted; a first chapter at 0:00 is added if needed (YouTube).
    var outputChapters: [(time: Double, title: String)] {
        var list = settings.chapters.compactMap { c in outputTime(ofSource: c.time).map { ($0, c.title) } }.sorted { $0.0 < $1.0 }
        if let first = list.first, first.0 > 0.5 { list.insert((0, settings.intro?.title.isEmpty == false ? settings.intro!.title : "Start"), at: 0) }
        if let first = list.first, first.0 <= 0.5 { list[0].0 = 0 }
        return list
    }

    /// "0:00 Start" lines for a YouTube description.
    var youTubeChapterText: String {
        outputChapters.map { "\(formatTime($0.time, fractional: false)) \($0.title)" }.joined(separator: "\n")
    }

    /// YouTube shows chapters only with at least three, each at least 10 s long.
    var youTubeChapterProblem: String? {
        let list = outputChapters
        guard !list.isEmpty else { return nil }
        if list.count < 3 { return "YouTube zeigt Kapitel erst ab drei Marken." }
        let ends = list.dropFirst().map(\.time) + [outputDuration]
        if zip(list.map(\.time), ends).contains(where: { $1 - $0 < 10 }) { return "Jedes Kapitel muss für YouTube mindestens 10 s lang sein." }
        return nil
    }

    func copyChapters() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(youTubeChapterText, forType: .string)
    }
}

// MARK: - Style presets

extension EditorModel {
    /// Takes over the look of a preset (one undo step).
    func applyStyle(_ preset: StylePreset) {
        commitUndoStep(); defer { commitUndoStep() }
        var s = settings
        StyleLibrary.apply(preset, to: &s, projectURL: project.url)
        settings = s
    }

    /// Asks for a name and saves the current look.
    func saveStyle() {
        let alert = NSAlert()
        alert.messageText = "Stil sichern"
        alert.informativeText = "Hintergrund, Rahmen, Cursor, Kamera, Blenden, Logo und Export-Einstellungen werden als Vorlage gespeichert."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name der Vorlage"
        field.stringValue = project.name
        let hasPack = settings.intro != nil || settings.outro != nil || settings.textDesign != nil
        let pack = NSButton(checkboxWithTitle: "Vorspann, Abspann und Bauchbinden-Design mitsichern", target: nil, action: nil)
        pack.state = hasPack ? .on : .off
        pack.isEnabled = hasPack
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 320, height: 52))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.addArrangedSubview(field)
        stack.addArrangedSubview(pack)
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        alert.accessoryView = stack
        alert.addButton(withTitle: "Sichern")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        _ = StyleLibrary.add(name: name.isEmpty ? "Mein Stil" : name, settings: settings, projectURL: project.url, pack: pack.state == .on && hasPack)
        objectWillChange.send()
    }
}
