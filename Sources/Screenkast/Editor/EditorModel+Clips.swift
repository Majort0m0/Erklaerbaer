import UniformTypeIdentifiers
import AppKit
import AVFoundation

/// Editing the video's parts on the timeline: moving them, and ripple trimming at their edges.
extension EditorModel {
    /// The parts of the video in playing order.
    var clipParts: [EditSettings.ClipPart] { settings.clipParts(duration: duration) }

    /// A part being dragged to another place on the timeline.
    struct ClipDrag: Equatable {
        var key: Double
        /// Timeline offset of the mouse since the drag began.
        var dt: Double
    }

    /// Timeline stretch of a part.
    func clipRun(_ part: EditSettings.ClipPart) -> ClosedRange<Double>? { displayRun(part.range.lowerBound, part.range.upperBound) }

    /// Position among the other parts where a dragged part would land.
    func clipDropIndex(_ drag: ClipDrag) -> Int? {
        let parts = clipParts
        guard let part = parts.first(where: { $0.key == drag.key }), let run = clipRun(part) else { return nil }
        let center = (run.lowerBound + run.upperBound) / 2 + drag.dt
        let moving = clipDragKeys(drag.key)
        let others = parts.filter { !moving.contains($0.key) }
        return others.filter { other in
            guard let r = clipRun(other) else { return false }
            return (r.lowerBound + r.upperBound) / 2 < center
        }.count
    }

    /// Timeline position of the gap a dragged part would land in (for the marker).
    func clipDropPosition(_ drag: ClipDrag) -> Double? {
        guard let index = clipDropIndex(drag) else { return nil }
        let moving = clipDragKeys(drag.key)
        let others = clipParts.filter { !moving.contains($0.key) }
        if index < others.count { return clipRun(others[index])?.lowerBound }
        return others.last.flatMap { clipRun($0)?.upperBound }
    }

    /// The parts that move with the dragged one (all selected parts if it is among them).
    func clipDragKeys(_ key: Double) -> [Double] {
        let parts = clipParts
        guard let part = parts.first(where: { $0.key == key }), multiSelection.contains(.segment(part.range.lowerBound)) else { return [key] }
        return parts.filter { multiSelection.contains(.segment($0.range.lowerBound)) }.map(\.key)
    }

    /// Moves a part to position `index` among the other parts. Everything anchored to it comes along.
    func moveClip(key: Double, to index: Int) {
        var parts = clipParts
        guard let from = parts.firstIndex(where: { $0.key == key }) else { return }
        let keys = clipDragKeys(key)
        if keys.count > 1 {
            moveClips(keys: keys, to: index)
            return
        }
        let part = parts.remove(at: from)
        let target = min(max(0, index), parts.count)
        guard target != from else { return }
        commitUndoStep(); defer { commitUndoStep() }
        // What runs across the border of the moved part stays on both sides.
        splitItems(at: part.range.lowerBound)
        splitItems(at: part.range.upperBound)
        parts.insert(part, at: target)
        let natural = zip(parts, parts.dropFirst()).allSatisfy { $0.range.lowerBound < $1.range.lowerBound }
        settings.clipOrder = natural ? nil : parts.map(\.key)
        if let clip = settings.inserts.first(where: { abs($0.sourceRange.lowerBound - part.range.lowerBound) < 1e-6 }) {
            selection = .insert(clip.id)
        } else {
            selection = .segment(part.range.lowerBound)
        }
        seek(to: part.range.lowerBound + 1e-4)
    }

    /// Moves several parts together, in their current order, to position `index` among the others.
    func moveClips(keys: [Double], to index: Int) {
        let parts = clipParts
        let group = parts.filter { keys.contains($0.key) }
        var others = parts.filter { !keys.contains($0.key) }
        commitUndoStep(); defer { commitUndoStep() }
        for part in group {
            splitItems(at: part.range.lowerBound)
            splitItems(at: part.range.upperBound)
        }
        others.insert(contentsOf: group, at: min(max(0, index), others.count))
        let natural = zip(others, others.dropFirst()).allSatisfy { $0.range.lowerBound < $1.range.lowerBound }
        settings.clipOrder = natural ? nil : others.map(\.key)
    }

    /// Splits the items that run across source time `t`, so that each side can go its own way.
    private func splitItems(at t: Double) {
        func split<T>(_ items: inout [T], _ start: WritableKeyPath<T, Double>, _ end: WritableKeyPath<T, Double>,
                      _ id: WritableKeyPath<T, UUID>, skip: (T) -> Bool = { _ in false }) {
            for i in items.indices where !skip(items[i]) && items[i][keyPath: start] < t - 1e-3 && items[i][keyPath: end] > t + 1e-3 {
                var second = items[i]
                second[keyPath: id] = UUID()
                second[keyPath: start] = t
                items[i][keyPath: end] = t
                items.append(second)
            }
        }
        split(&settings.masks, \.start, \.end, \.id)
        split(&settings.zoomSegments, \.start, \.end, \.id)
        split(&settings.annotations, \.start, \.end, \.id)
        split(&settings.cameraLayouts, \.start, \.end, \.id)
        split(&settings.cursorRanges, \.start, \.end, \.id)
        split(&settings.audioMutes, \.start, \.end, \.id)
        split(&settings.texts, \.start, \.end, \.id, skip: { $0.isFree || $0.placement != .overlay && $0.kind != .lowerThird })
        split(&settings.images, \.start, \.end, \.id, skip: { $0.isFree })
        // Clips that play in real time: the second half continues later in the file.
        let base = settings.timeMap(duration: duration)
        func cut(_ start: Double, _ seconds: Double) -> Double? {
            let a = base.timeline(start), b = base.timeline(t)
            return b > a + 0.05 && b < a + seconds - 0.05 ? b - a : nil
        }
        for i in settings.voiceOvers.indices where !settings.voiceOvers[i].isFree {
            guard let first = cut(settings.voiceOvers[i].start, settings.voiceOvers[i].duration) else { continue }
            var second = settings.voiceOvers[i]
            second.id = UUID()
            second.start = t
            second.fileOffset += first
            second.duration -= first
            settings.voiceOvers[i].duration = first
            settings.voiceOvers.append(second)
        }
        for i in settings.videoOverlays.indices where !settings.videoOverlays[i].isFree && !settings.videoOverlays[i].synced {
            guard let first = cut(settings.videoOverlays[i].start, settings.videoOverlays[i].duration) else { continue }
            var second = settings.videoOverlays[i]
            second.id = UUID()
            second.start = t
            second.fileOffset += first
            second.duration -= first
            settings.videoOverlays[i].duration = first
            settings.videoOverlays.append(second)
        }
    }

    // MARK: Ripple trim

    /// What an edge drag changes.
    enum EdgeDrag: Equatable {
        case trimStart(origin: Double)
        case trimEnd(origin: Double)
        /// `isStart`: the start of the cut moves (the part before it gets longer or shorter).
        case cut(id: UUID, isStart: Bool, origin: Double, created: Bool)
    }

    /// Source seconds per timeline second inside a part.
    func partRate(_ part: EditSettings.ClipPart) -> Double { rate(of: part) }

    private func rate(of part: EditSettings.ClipPart) -> Double {
        guard let run = clipRun(part), run.upperBound > run.lowerBound else { return 1 }
        return (part.range.upperBound - part.range.lowerBound) / (run.upperBound - run.lowerBound)
    }

    /// Drags the left or right edge of a part: shortening removes material, the gap closes;
    /// lengthening brings back what was removed there.
    func dragEdge(of part: EditSettings.ClipPart, isStart: Bool, dt: Double) {
        if edgeDrag == nil {
            beginInteraction()
            edgeDragRate = rate(of: part)
            let edge = isStart ? part.range.lowerBound : part.range.upperBound
            if isStart, abs(edge - settings.trimStart) < 1e-3 {
                edgeDrag = .trimStart(origin: edge)
            } else if !isStart, abs(edge - trimEnd) < 1e-3 {
                edgeDrag = .trimEnd(origin: edge)
            } else if let cut = settings.cuts.first(where: { abs((isStart ? $0.end : $0.start) - edge) < 1e-3 }) {
                edgeDrag = .cut(id: cut.id, isStart: !isStart, origin: edge, created: false)
            } else if let dissolved = settings.dissolves(duration: duration).first(where: { isStart && abs($0.resume - edge) < 1e-3 }),
                      let cut = settings.cuts.first(where: { $0.id == dissolved.cutID }) {
                edgeDrag = .cut(id: cut.id, isStart: false, origin: cut.end, created: false)
            } else if isStart, settings.joinTransitions.contains(where: { abs($0.key - part.key) < 1e-4 }) {
                return   // the transition uses these seconds: change it in the inspector
            } else {
                // Between two parts that simply follow each other: shortening creates a cut.
                let shortens = isStart ? dt > 0 : dt < 0
                guard shortens else { return }
                let new = CutRange(start: edge - (isStart ? 0 : 0.1), end: edge + (isStart ? 0.1 : 0))
                settings.cuts.append(new)
                settings.cuts.sort { $0.start < $1.start }
                edgeDrag = .cut(id: new.id, isStart: !isStart, origin: edge, created: true)
            }
        }
        let delta = dt * edgeDragRate
        switch edgeDrag {
        case .trimStart(let origin): setTrim(start: origin + delta)
        case .trimEnd(let origin): setTrim(end: origin + delta)
        case .cut(let id, let cutStart, let origin, _):
            if cutStart { updateCut(id: id, start: origin + delta) } else { updateCut(id: id, end: origin + delta) }
        case nil: break
        }
    }

    /// A cut that shrank to nothing while its edge was dragged is gone.
    func finishEdgeDrag() {
        guard let drag = edgeDrag else { return }
        edgeDrag = nil
        if case .cut(let id, _, _, _) = drag, let cut = settings.cuts.first(where: { $0.id == id }), cut.end - cut.start <= 0.1 + 1e-6 {
            settings.cuts.removeAll { $0.id == id }
        }
    }

    // MARK: Tied to the video, or free

    enum LinkableLane: String { case texts, media, voiceOver }

    func isFree(_ lane: LinkableLane) -> Bool { settings.freeLanes.contains(lane.rawValue) }

    /// Timeline stretch of a voice-over clip.
    func displayRange(_ clip: VoiceOverClip) -> ClosedRange<Double> {
        if clip.isFree { return clip.start...(clip.start + clip.duration) }
        let pieces = settings.linkedPieces(start: clip.start, duration: clip.duration, map: settings.timeMap(duration: duration),
                                           kept: settings.keptSegments(duration: duration))
        guard let first = pieces.first, let last = pieces.last else { let t = display(clip.start); return t...t }
        return first.timeline.lowerBound...last.timeline.upperBound
    }

    /// Timeline stretch of a video overlay.
    func displayRange(_ o: VideoOverlay) -> ClosedRange<Double> {
        if o.isFree { return o.start...(o.start + o.duration) }
        let pieces = settings.linkedPieces(start: o.start, duration: o.duration, map: settings.timeMap(duration: duration),
                                           kept: settings.keptSegments(duration: duration))
        guard let first = pieces.first, let last = pieces.last else { let t = display(o.start); return t...t }
        return first.timeline.lowerBound...last.timeline.upperBound
    }

    /// Timeline stretch of a text or picture.
    func displayRange(start: Double, end: Double, free: Bool) -> ClosedRange<Double>? {
        free ? start...max(start, end) : displayRun(start, end)
    }

    func isVisibleNow(text t: TextOverlay) -> Bool { displayRange(start: t.start, end: t.end, free: t.isFree)?.contains(display(currentTime)) ?? false }
    func isVisibleNow(image o: ImageOverlay) -> Bool { displayRange(start: o.start, end: o.end, free: o.isFree)?.contains(display(currentTime)) ?? false }

    private func freeing(_ start: inout Double, _ end: inout Double, to free: Bool) {
        if free {
            let run = displayRun(start, end)
            let a = run?.lowerBound ?? display(start), b = run?.upperBound ?? display(end)
            start = a; end = b
        } else {
            let a = sourceTime(start), b = timeMap.sourceEnd(end)
            start = a; end = max(a + 0.05, b)
        }
    }

    func setFree(text id: UUID, _ free: Bool) {
        guard let i = settings.texts.firstIndex(where: { $0.id == id }), settings.texts[i].isFree != free else { return }
        commitUndoStep(); defer { commitUndoStep() }
        var item = settings.texts[i]
        freeing(&item.start, &item.end, to: free)
        item.free = free ? true : nil
        settings.texts[i] = item
    }

    func setFree(image id: UUID, _ free: Bool) {
        guard let i = settings.images.firstIndex(where: { $0.id == id }), settings.images[i].isFree != free else { return }
        commitUndoStep(); defer { commitUndoStep() }
        var item = settings.images[i]
        freeing(&item.start, &item.end, to: free)
        item.free = free ? true : nil
        settings.images[i] = item
    }

    func setFree(videoOverlay id: UUID, _ free: Bool) {
        guard let i = settings.videoOverlays.firstIndex(where: { $0.id == id }), !settings.videoOverlays[i].synced,
              settings.videoOverlays[i].isFree != free else { return }
        commitUndoStep(); defer { commitUndoStep() }
        settings.videoOverlays[i].start = free ? displayRange(settings.videoOverlays[i]).lowerBound : sourceTime(settings.videoOverlays[i].start)
        settings.videoOverlays[i].free = free ? true : nil
    }

    func setFree(voiceOver id: UUID, _ free: Bool) {
        guard let i = settings.voiceOvers.firstIndex(where: { $0.id == id }), settings.voiceOvers[i].isFree != free else { return }
        commitUndoStep(); defer { commitUndoStep() }
        settings.voiceOvers[i].start = free ? displayRange(settings.voiceOvers[i]).lowerBound : sourceTime(settings.voiceOvers[i].start)
        settings.voiceOvers[i].free = free ? true : nil
    }

    /// A whole lane: everything on it, and what is added later.
    func setLane(_ lane: LinkableLane, free: Bool) {
        commitUndoStep(); defer { commitUndoStep() }
        if free { if !isFree(lane) { settings.freeLanes.append(lane.rawValue) } } else { settings.freeLanes.removeAll { $0 == lane.rawValue } }
        switch lane {
        case .texts: for t in settings.overlayTexts { setFree(text: t.id, free) }
        case .media:
            for o in settings.images { setFree(image: o.id, free) }
            for o in settings.videoOverlays where !o.synced { setFree(videoOverlay: o.id, free) }
        case .voiceOver: for c in settings.voiceOvers { setFree(voiceOver: c.id, free) }
        }
    }

    /// New items on a free lane are free from the start.
    func adopted(_ t: TextOverlay) -> TextOverlay {
        guard isFree(.texts), t.placement == .overlay || t.kind == .lowerThird else { return t }
        var c = t
        freeing(&c.start, &c.end, to: true)
        c.free = true
        return c
    }

    func adopted(_ o: ImageOverlay) -> ImageOverlay {
        guard isFree(.media) else { return o }
        var c = o
        freeing(&c.start, &c.end, to: true)
        c.free = true
        return c
    }

    func adopted(_ o: VideoOverlay) -> VideoOverlay {
        guard isFree(.media), !o.synced else { return o }
        var c = o
        c.start = display(o.start)
        c.free = true
        return c
    }

    func adopted(_ clip: VoiceOverClip) -> VoiceOverClip {
        guard isFree(.voiceOver) else { return clip }
        var c = clip
        c.start = display(clip.start)
        c.free = true
        return c
    }

    // MARK: Music as clips

    /// Turns the music running through the video into clips that can be cut and moved.
    func convertMusicToClips() {
        guard var music = settings.music, music.clipped != true, let length = musicLength, length > 0.1 else { return }
        var clips: [VoiceOverClip] = []
        var t = 0.0, offset = min(music.fileOffset, length - 0.1)
        while t < timeMap.total - 0.01 {
            let chunk = min(timeMap.total - t, length - offset)
            var clip = VoiceOverClip(file: music.file, fileOffset: offset, start: t, duration: chunk)
            clip.free = true
            clip.music = true
            clips.append(clip)
            t += chunk
            offset = 0
            if !music.loop { break }
        }
        waveforms[music.file] = waveforms["music:" + music.file]
        waveformPeaks[music.file] = waveformPeaks["music:" + music.file]
        music.clipped = true
        settings.voiceOvers += clips
        settings.music = music
    }

    /// Cuts the music at timeline time `T`. The second half is selected.
    func splitMusic(atTimeline T: Double) {
        commitUndoStep(); defer { commitUndoStep() }
        convertMusicToClips()
        guard let i = settings.voiceOvers.firstIndex(where: { $0.isMusic && $0.isFree && T > $0.start + 0.05 && T < $0.end - 0.05 }) else { return }
        var second = settings.voiceOvers[i]
        let first = T - second.start
        second.id = UUID()
        second.start = T
        second.fileOffset += first
        second.duration -= first
        settings.voiceOvers[i].duration = first
        settings.voiceOvers.append(second)
        selectedVoiceOverID = second.id
    }

    /// Adds an audio file as a clip on the music lane at timeline time `T`.
    func addMusicClip(url: URL, atTimeline T: Double) {
        Task {
            guard let length = try? await AVURLAsset(url: url).load(.duration).seconds, length > 0.1, let file = importMedia(url) else { return }
            commitUndoStep(); defer { commitUndoStep() }
            if settings.music == nil {
                settings.music = BackgroundMusic(file: file, name: url.deletingPathExtension().lastPathComponent, clipped: true)
            } else {
                convertMusicToClips()
                settings.music?.clipped = true
            }
            var clip = VoiceOverClip(file: file, fileOffset: 0, start: min(max(0, T), max(0, timeMap.total - 0.2)), duration: length)
            clip.duration = min(length, max(0.2, timeMap.total - clip.start))
            clip.free = true
            clip.music = true
            settings.voiceOvers.append(clip)
            loadVoiceOverWaveform(file)
            selectedVoiceOverID = clip.id
        }
    }

    /// When the last music clip is gone, so is the lane.
    func dropEmptyMusicLane() {
        if settings.music?.clipped == true, !settings.voiceOvers.contains(where: \.isMusic) { settings.music = nil }
    }

    // MARK: Sound of the video as a clip

    /// True if the video's own sound can be separated (exactly one sound track in the file).
    func canDetachSound(_ lane: AudioLane) -> Bool {
        project.info.audioRoles == [lane.role] && !settings.voiceOvers.contains { $0.file == project.info.videoFile }
    }

    /// Makes the video's sound independent: one free clip per part on the voice-over lane, which
    /// can be moved, cut and faded without the picture. The lane of the original sound is muted.
    func detachSound(_ lane: AudioLane) {
        guard canDetachSound(lane) else { return }
        commitUndoStep(); defer { commitUndoStep() }
        for part in clipParts where !settings.inserts.contains(where: { abs($0.sourceRange.lowerBound - part.range.lowerBound) < 1e-6 }) {
            guard let run = clipRun(part) else { continue }
            var clip = VoiceOverClip(file: project.info.videoFile, fileOffset: part.range.lowerBound, start: run.lowerBound,
                                     duration: run.upperBound - run.lowerBound)
            clip.free = true
            settings.voiceOvers.append(clip)
        }
        setMuted(true, lane)
        loadVoiceOverWaveform(project.info.videoFile)
    }

    // MARK: Copy and paste

    enum ClipboardItem {
        case text(TextOverlay), image(ImageOverlay), mask(BlurMask), annotation(Annotation), zoom(ZoomSegment)
        case overlay(VideoOverlay), voice(VoiceOverClip)
    }

    /// Where a clipboard item begins on the timeline.
    private func timelineStart(_ item: ClipboardItem) -> Double {
        switch item {
        case .text(let t): return displayRange(start: t.start, end: t.end, free: t.isFree)?.lowerBound ?? 0
        case .image(let o): return displayRange(start: o.start, end: o.end, free: o.isFree)?.lowerBound ?? 0
        case .mask(let m): return displayRun(m.start, m.end)?.lowerBound ?? 0
        case .annotation(let a): return displayRun(a.start, a.end)?.lowerBound ?? 0
        case .zoom(let z): return displayRun(z.start, z.end)?.lowerBound ?? 0
        case .overlay(let o): return displayRange(o).lowerBound
        case .voice(let c): return displayRange(c).lowerBound
        }
    }

    private func clipboardItem(_ selection: EditorSelection) -> ClipboardItem? {
        switch selection {
        case .text(let id): return settings.texts.first { $0.id == id && ($0.placement == .overlay || $0.kind == .lowerThird) }.map { .text($0) }
        case .image(let id): return settings.images.first { $0.id == id }.map { .image($0) }
        case .mask(let id): return settings.masks.first { $0.id == id }.map { .mask($0) }
        case .annotation(let id): return settings.annotations.first { $0.id == id }.map { .annotation($0) }
        case .zoom(let id): return settings.zoomSegments.first { $0.id == id }.map { .zoom($0) }
        case .videoOverlay(let id): return settings.videoOverlays.first { $0.id == id && !$0.synced }.map { .overlay($0) }
        case .voiceOver(let id): return settings.voiceOvers.first { $0.id == id }.map { .voice($0) }
        default: return nil
        }
    }

    /// Copies the selection (several things keep their distance to each other).
    func copySelection() {
        let selected = multiSelection.count > 1 ? multiSelection : selection.map { [$0] } ?? []
        let items = selected.compactMap(clipboardItem)
        guard !items.isEmpty else { return }
        let first = items.map(timelineStart).min() ?? 0
        clipboard = items.map { ($0, timelineStart($0) - first) }
    }

    /// Source range of a copy that begins at timeline time `T` and is as long as the original.
    private func pasted(start: Double, end: Double, at T: Double) -> (start: Double, end: Double) {
        let run = displayRun(start, end)
        let length = (run?.upperBound ?? display(end)) - (run?.lowerBound ?? display(start))
        let a = min(T, max(0, timeMap.total - length))
        return (sourceTime(a), timeMap.sourceEnd(min(timeMap.total, a + max(0.1, length))))
    }

    /// Puts copies of what was copied at the playhead.
    func pasteClipboard() {
        guard !clipboard.isEmpty, currentTime >= 0, currentTime <= duration else { return }
        commitUndoStep(); defer { commitUndoStep() }
        let playhead = display(currentTime)
        var added: [EditorSelection] = []
        for (item, offset) in clipboard {
            let T = playhead + offset
            switch item {
            case .text(var t):
                t.id = UUID()
                if t.isFree { let l = t.end - t.start; t.start = T; t.end = min(timeMap.total, T + l) } else { (t.start, t.end) = pasted(start: t.start, end: t.end, at: T) }
                settings.texts.append(t)
                added.append(.text(t.id))
            case .image(var o):
                o.id = UUID()
                if o.isFree { let l = o.end - o.start; o.start = T; o.end = min(timeMap.total, T + l) } else { (o.start, o.end) = pasted(start: o.start, end: o.end, at: T) }
                settings.images.append(o)
                added.append(.image(o.id))
            case .mask(var m):
                m.id = UUID()
                (m.start, m.end) = pasted(start: m.start, end: m.end, at: T)
                settings.masks.append(m)
                added.append(.mask(m.id))
            case .annotation(var a):
                a.id = UUID()
                (a.start, a.end) = pasted(start: a.start, end: a.end, at: T)
                settings.annotations.append(a)
                added.append(.annotation(a.id))
            case .zoom(var z):
                z.id = UUID()
                z.isAuto = false
                (z.start, z.end) = pasted(start: z.start, end: z.end, at: T)
                settings.zoomSegments.append(z)
                added.append(.zoom(z.id))
            case .overlay(var o):
                o.id = UUID()
                o.start = o.isFree ? T : sourceTime(T)
                settings.videoOverlays.append(o)
                added.append(.videoOverlay(o.id))
            case .voice(var c):
                c.id = UUID()
                c.start = c.isFree ? T : sourceTime(T)
                settings.voiceOvers.append(c)
                added.append(.voiceOver(c.id))
            }
        }
        if added.count > 1 {
            multiSelection = added
            selection = added.last
        } else {
            selection = added.first
        }
    }

    // MARK: Several things selected

    func isInGroup(_ item: EditorSelection) -> Bool { multiSelection.contains(item) }

    /// A click on `item`; with ⇧ it joins the selection or leaves it again.
    func click(_ item: EditorSelection, adding: Bool = NSEvent.modifierFlags.contains(.shift)) {
        guard adding else {
            selection = item
            return
        }
        if multiSelection.isEmpty {
            guard let current = selection, current != item else {
                selection = item
                return
            }
            multiSelection = [current, item]
            selection = item
            return
        }
        if multiSelection.contains(item) {
            multiSelection.removeAll { $0 == item }
            if multiSelection.count == 1 {
                let last = multiSelection[0]
                multiSelection = []
                selection = last
            } else {
                selection = multiSelection.last
            }
        } else {
            multiSelection.append(item)
            selection = item
        }
    }

    /// Removes everything selected as one undo step.
    func deleteGroup() {
        let items = multiSelection
        multiSelection = []
        selection = nil
        for item in items {
            if case .segment(let start) = item {
                // Directly: `removeSegment` would make an undo step of each.
                guard let part = videoSegments.first(where: { abs($0.lowerBound - start) < 1e-6 }) else { continue }
                var probe = settings
                probe.cuts.append(CutRange(start: part.lowerBound, end: part.upperBound))
                guard !probe.keptSegments(duration: duration).isEmpty else { continue }
                settings.cuts.append(CutRange(start: part.lowerBound, end: part.upperBound))
                settings.cuts.sort { $0.start < $1.start }
            } else {
                removeItem(item)
            }
        }
    }

    /// Timeline range of a selected item in the given settings (nil: not movable with the group).
    private func groupRange(_ item: EditorSelection, in s: EditSettings) -> ClosedRange<Double>? {
        switch item {
        case .zoom(let id): return s.zoomSegments.first { $0.id == id }.flatMap { displayRun($0.start, $0.end) }
        case .mask(let id): return s.masks.first { $0.id == id }.flatMap { displayRun($0.start, $0.end) }
        case .annotation(let id): return s.annotations.first { $0.id == id }.flatMap { displayRun($0.start, $0.end) }
        case .cameraLayout(let id): return s.cameraLayouts.first { $0.id == id }.flatMap { displayRun($0.start, $0.end) }
        case .cursorRange(let id): return s.cursorRanges.first { $0.id == id }.flatMap { displayRun($0.start, $0.end) }
        case .mute(let id): return s.audioMutes.first { $0.id == id }.flatMap { displayRun($0.start, $0.end) }
        case .text(let id): return s.texts.first { $0.id == id }.flatMap { displayRange(start: $0.start, end: $0.end, free: $0.isFree) }
        case .image(let id): return s.images.first { $0.id == id }.flatMap { displayRange(start: $0.start, end: $0.end, free: $0.isFree) }
        case .videoOverlay(let id): return s.videoOverlays.first { $0.id == id }.map { displayRange($0) }
        case .voiceOver(let id): return s.voiceOvers.first { $0.id == id }.map { displayRange($0) }
        default: return nil
        }
    }

    /// Moves the whole selected group by `dt` timeline seconds, if `item` belongs to it.
    /// Returns false if this drag concerns only the item itself.
    func dragGroup(_ kind: RangeBlock.DragKind, dt: Double, item: EditorSelection) -> Bool {
        guard kind == .move, multiSelection.count > 1, multiSelection.contains(item) else { return false }
        if groupOrigin == nil {
            groupOrigin = settings
            beginInteraction()
        }
        guard let origin = groupOrigin else { return true }
        // The group stays together at the ends of the timeline.
        var low = -Double.infinity, high = Double.infinity
        for member in multiSelection {
            guard let r = groupRange(member, in: origin) else { continue }
            low = max(low, -r.lowerBound)
            high = min(high, timeMap.total - r.upperBound)
        }
        let d = min(max(dt, low), max(low, high))
        func moved(_ start: Double, _ end: Double) -> (Double, Double) {
            guard let r = displayRun(start, end) else { return (start, end) }
            return (sourceTime(r.lowerBound + d), timeMap.sourceEnd(r.upperBound + d))
        }
        var s = settings
        for member in multiSelection {
            switch member {
            case .zoom(let id):
                if let i = origin.zoomSegments.firstIndex(where: { $0.id == id }), let n = s.zoomSegments.firstIndex(where: { $0.id == id }) {
                    (s.zoomSegments[n].start, s.zoomSegments[n].end) = moved(origin.zoomSegments[i].start, origin.zoomSegments[i].end)
                }
            case .mask(let id):
                if let i = origin.masks.firstIndex(where: { $0.id == id }), let n = s.masks.firstIndex(where: { $0.id == id }) {
                    (s.masks[n].start, s.masks[n].end) = moved(origin.masks[i].start, origin.masks[i].end)
                }
            case .annotation(let id):
                if let i = origin.annotations.firstIndex(where: { $0.id == id }), let n = s.annotations.firstIndex(where: { $0.id == id }) {
                    (s.annotations[n].start, s.annotations[n].end) = moved(origin.annotations[i].start, origin.annotations[i].end)
                }
            case .cameraLayout(let id):
                if let i = origin.cameraLayouts.firstIndex(where: { $0.id == id }), let n = s.cameraLayouts.firstIndex(where: { $0.id == id }) {
                    (s.cameraLayouts[n].start, s.cameraLayouts[n].end) = moved(origin.cameraLayouts[i].start, origin.cameraLayouts[i].end)
                }
            case .cursorRange(let id):
                if let i = origin.cursorRanges.firstIndex(where: { $0.id == id }), let n = s.cursorRanges.firstIndex(where: { $0.id == id }) {
                    (s.cursorRanges[n].start, s.cursorRanges[n].end) = moved(origin.cursorRanges[i].start, origin.cursorRanges[i].end)
                }
            case .mute(let id):
                if let i = origin.audioMutes.firstIndex(where: { $0.id == id }), let n = s.audioMutes.firstIndex(where: { $0.id == id }) {
                    (s.audioMutes[n].start, s.audioMutes[n].end) = moved(origin.audioMutes[i].start, origin.audioMutes[i].end)
                }
            case .text(let id):
                if let i = origin.texts.firstIndex(where: { $0.id == id }), let n = s.texts.firstIndex(where: { $0.id == id }) {
                    let o = origin.texts[i]
                    (s.texts[n].start, s.texts[n].end) = o.isFree ? (o.start + d, o.end + d) : moved(o.start, o.end)
                }
            case .image(let id):
                if let i = origin.images.firstIndex(where: { $0.id == id }), let n = s.images.firstIndex(where: { $0.id == id }) {
                    let o = origin.images[i]
                    (s.images[n].start, s.images[n].end) = o.isFree ? (o.start + d, o.end + d) : moved(o.start, o.end)
                }
            case .videoOverlay(let id):
                if let i = origin.videoOverlays.firstIndex(where: { $0.id == id }), let n = s.videoOverlays.firstIndex(where: { $0.id == id }) {
                    let o = origin.videoOverlays[i]
                    s.videoOverlays[n].start = o.isFree ? o.start + d : sourceTime(display(o.start) + d)
                }
            case .voiceOver(let id):
                if let i = origin.voiceOvers.firstIndex(where: { $0.id == id }), let n = s.voiceOvers.firstIndex(where: { $0.id == id }) {
                    let o = origin.voiceOvers[i]
                    s.voiceOvers[n].start = o.isFree ? o.start + d : sourceTime(display(o.start) + d)
                }
            default: break
            }
        }
        settings = s
        return true
    }

    // MARK: Transitions where parts meet

    /// Which part the selected join leads into.
    var selectedJoinKey: Double? {
        if case .join(let key) = selection { return key }
        return nil
    }

    func joinTransition(key: Double) -> JoinTransition? { settings.joinTransitions.first { abs($0.key - key) < 1e-4 } }

    /// True if a cut between these two parts already offers the transition.
    func joinHasCut(after a: EditSettings.ClipPart, before b: EditSettings.ClipPart) -> Bool { joinCut(after: a, before: b) != nil }

    private func joinCut(after a: EditSettings.ClipPart, before b: EditSettings.ClipPart) -> CutRange? {
        settings.cuts.first { abs($0.start - a.range.upperBound) < 1e-3 && (abs($0.end - b.range.lowerBound) < 1e-3 || abs($0.end - b.key) < 1e-3) }
    }

    func setJoinTransition(key: Double, length: Double) {
        let length = min(EditSettings.maxDissolve, max(0, length))
        if length < 0.05 {
            settings.joinTransitions.removeAll { abs($0.key - key) < 1e-4 }
        } else if let i = settings.joinTransitions.firstIndex(where: { abs($0.key - key) < 1e-4 }) {
            settings.joinTransitions[i].length = length
        } else {
            settings.joinTransitions.append(JoinTransition(key: key, length: length))
        }
    }

    func setJoinStyle(key: Double, _ style: TransitionStyle) {
        if let i = settings.joinTransitions.firstIndex(where: { abs($0.key - key) < 1e-4 }) {
            settings.joinTransitions[i].style = style
        } else {
            settings.joinTransitions.append(JoinTransition(key: key, length: 0.5, style: style))
        }
    }

    // MARK: Locked lanes

    func isLocked(_ lane: String) -> Bool { settings.lockedLanes.contains(lane) }

    func toggleLock(_ lane: String) {
        if isLocked(lane) { settings.lockedLanes.removeAll { $0 == lane } } else { settings.lockedLanes.append(lane) }
    }

    // MARK: J K L

    /// J: backwards, K: stop, L: forwards; pressing again gets faster.
    func shuttle(_ direction: Int) {
        guard let item = player.currentItem else { return }
        if direction == 0 {
            shuttleRate = 0
            pause()
            return
        }
        if direction < 0, !item.canPlayReverse {
            // This video can't be played backwards: jump back instead.
            step(by: -1)
            return
        }
        if (shuttleRate > 0) != (direction > 0) || shuttleRate == 0 {
            shuttleRate = Float(direction)
        } else if abs(shuttleRate) < 4 {
            shuttleRate *= 2
        }
        if !isPlaying { play() }
        player.rate = shuttleRate
    }

    // MARK: Scene

    func updateMockupPlacement(_ change: (inout MockupPlacement) -> Void) {
        guard let key = settings.mockupPlacementKey else { return }
        var p = settings.mockupPlacement
        change(&p)
        settings.mockupPlacements[key] = p == MockupPlacement() ? nil : p
    }

    // MARK: Toolbar and keyboard

    /// Cuts the part before (or after) the playhead away, like the end handles.
    func trimToPlayhead(start: Bool) {
        commitUndoStep(); defer { commitUndoStep() }
        guard currentTime >= 0, currentTime <= duration else { return }
        if start { setTrim(start: currentTime) } else { setTrim(end: currentTime) }
    }

    static let tempoSteps = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 4, 8]

    /// The part the tempo applies to: the selected one, else the one at the playhead.
    var partForTempo: ClosedRange<Double>? { selectedSegment ?? segment(at: currentTime) }

    func setTempo(_ rate: Double) {
        guard let part = partForTempo else { return }
        commitUndoStep(); defer { commitUndoStep() }
        setSpeed(rate, for: part)
    }

    /// One step faster (or slower) for the selected part.
    func changeSpeed(_ direction: Int) {
        guard let part = partForTempo else { return }
        let steps = Self.tempoSteps
        let now = settings.speeds.first { $0.start <= part.lowerBound + 1e-3 && $0.end >= part.upperBound - 1e-3 }?.rate ?? 1
        let i = steps.firstIndex { abs($0 - now) < 0.01 } ?? (steps.firstIndex { $0 > now } ?? 3)
        setTempo(steps[min(steps.count - 1, max(0, i + direction))])
    }

    /// A transition at the selected join or cut, else at the join nearest to the playhead.
    func addTransitionHere() {
        commitUndoStep(); defer { commitUndoStep() }
        if let cut = selectedCut, canDissolve(cut) {
            if cut.dissolve < 0.05 { setDissolve(cutID: cut.id, 0.5) }
            return
        }
        if let key = selectedJoinKey {
            if joinTransition(key: key) == nil { setJoinTransition(key: key, length: 0.5) }
            return
        }
        let parts = clipParts
        guard parts.count > 1 else { return }
        let T0 = display(currentTime)
        let joins = parts.indices.dropFirst().compactMap { i -> (a: EditSettings.ClipPart, b: EditSettings.ClipPart, t: Double)? in
            clipRun(parts[i]).map { (parts[i - 1], parts[i], $0.lowerBound) }
        }
        guard let near = joins.min(by: { abs($0.t - T0) < abs($1.t - T0) }) else { return }
        setTransition(after: near.a, before: near.b, length: 0.5)
    }

    /// Sets the transition where part `a` meets part `b`, at a cut if there is one between them.
    func setTransition(after a: EditSettings.ClipPart, before b: EditSettings.ClipPart, length: Double) {
        if let cut = joinCut(after: a, before: b) {
            setDissolve(cutID: cut.id, length)
            selectedCutID = cut.id
        } else {
            setJoinTransition(key: b.key, length: length)
            selection = .join(b.key)
        }
    }

    // MARK: Pushing parts over each other

    /// A part pushed onto its neighbor but not past its middle: how long they would dissolve.
    func clipDragOverlap(_ drag: ClipDrag, minimum: Double) -> (after: EditSettings.ClipPart, before: EditSettings.ClipPart, length: Double, at: Double)? {
        let parts = clipParts
        guard clipDragKeys(drag.key).count == 1, abs(drag.dt) >= minimum, let i = parts.firstIndex(where: { $0.key == drag.key }),
              clipDropIndex(drag) == i else { return nil }
        let j = drag.dt < 0 ? i : i + 1
        guard j > 0, j < parts.count, let left = clipRun(parts[j - 1]), let right = clipRun(parts[j]) else { return nil }
        let room = min(left.upperBound - left.lowerBound, right.upperBound - right.lowerBound) / 2
        return (parts[j - 1], parts[j], min(EditSettings.maxDissolve, room, abs(drag.dt)), right.lowerBound)
    }

    /// Ends the drag of a part: over its neighbor it dissolves, further away it moves there.
    func finishClipDrag(_ drag: ClipDrag, minimum: Double) {
        let overlap = clipDragOverlap(drag, minimum: minimum)
        let index = clipDropIndex(drag)
        clipDrag = nil
        if let overlap {
            commitUndoStep(); defer { commitUndoStep() }
            setTransition(after: overlap.after, before: overlap.before, length: overlap.length)
        } else if let index {
            moveClip(key: drag.key, to: index)
        }
    }

    // MARK: Gluing clips

    /// Time ranges of the other clips on the lane of `id` (nothing for items that are not clips of a media file).
    private func mediaLane(of id: UUID) -> Int {
        (settings.images.first { $0.id == id }?.lane ?? settings.videoOverlays.first { $0.id == id }?.lane) ?? 0
    }

    func laneNeighbours(of id: UUID) -> [ClosedRange<Double>] {
        if let clip = settings.voiceOvers.first(where: { $0.id == id }) {
            return settings.voiceOvers.filter { $0.id != id && $0.isMusic == clip.isMusic }.map { displayRange($0) }
        }
        guard settings.videoOverlays.contains(where: { $0.id == id && !$0.synced }) || settings.images.contains(where: { $0.id == id }) else { return [] }
        let lane = mediaLane(of: id)
        return settings.videoOverlays.filter { $0.id != id && !$0.synced && ($0.lane ?? 0) == lane }.map { displayRange($0) }
            + settings.images.filter { $0.id != id && ($0.lane ?? 0) == lane }.compactMap { displayRange(start: $0.start, end: $0.end, free: $0.isFree) }
    }

    /// `dt` of a dragged clip adjusted so that it sticks to the end of a neighbor when it comes close.
    /// Pushed further it overlaps, and the two dissolve.
    func magnetDelta(_ edge: SnapEdge, dt: Double, start: Double, end: Double, id: UUID, tolerance: Double) -> Double? {
        guard magnet else { return nil }
        var pairs: [(edge: Double, target: Double)] = []
        for n in laneNeighbours(of: id) {
            if edge != .end { pairs.append((start + dt, n.upperBound)) }
            if edge != .start { pairs.append((end + dt, n.lowerBound)) }
        }
        guard let best = pairs.filter({ abs($0.target - $0.edge) <= tolerance }).min(by: { abs($0.target - $0.edge) < abs($1.target - $1.edge) }) else {
            if !snapping, snapGuide != nil { snapGuide = nil }
            return nil
        }
        if snapGuide != best.target { snapGuide = best.target }
        return dt + best.target - best.edge
    }

    // MARK: Memes

    /// Puts the meme of a place in the picture at the playhead (an empty place asks what to put there).
    func pressMeme(_ index: Int) {
        guard let slot = MemeBoard.shared.slots[index] else {
            MemeSearchWindow.shared.open(slot: index)
            return
        }
        addMeme(slot)
    }

    func addMeme(_ slot: MemeSlot) {
        addVideoOverlay(url: MemeBoard.shared.url(of: slot), at: currentTime, center: CGPoint(x: 0.5, y: 0.5), name: slot.title, transparent: slot.transparent == true)
    }

    // MARK: Numbered steps and clicks

    func stepNumber(_ a: Annotation) -> Int {
        (settings.annotations.filter { $0.kind == .step }.sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }.firstIndex { $0.id == a.id } ?? 0) + 1
    }

    /// Turns the recorded clicks into markings at the right place. Clicks close together count once;
    /// a click that already has such a marking gets no second one.
    @discardableResult
    func highlightClicks(with kind: AnnotationKind) -> Int {
        commitUndoStep(); defer { commitUndoStep() }
        var added = 0
        var last: ClickEvent?
        for click in project.cursor.clicks.sorted(by: { $0.t < $1.t }) where timeMap.contains(source: click.t) {
            if let last, click.t - last.t < 0.7, hypot(click.x - last.x, click.y - last.y) < 0.04 { continue }
            last = click
            func anchor(_ a: Annotation) -> CGPoint {
                switch a.kind {
                case .frame, .spotlight: return CGPoint(x: a.x + a.width / 2, y: a.y + a.height / 2)
                case .arrow: return CGPoint(x: a.x + a.width, y: a.y + a.height)
                case .touch, .step: return CGPoint(x: a.x, y: a.y)
                }
            }
            guard !settings.annotations.contains(where: {
                $0.kind == kind && $0.start <= click.t && $0.end >= click.t && hypot(anchor($0).x - click.x, anchor($0).y - click.y) < 0.05
            }) else { continue }
            var a = Annotation(kind: kind, start: max(0, click.t - 0.15), end: min(duration, click.t + (kind == .touch ? 1.1 : 1.8)))
            switch kind {
            case .frame, .spotlight:
                a.width = 0.16; a.height = 0.1
                a.x = min(1 - a.width, max(0, click.x - a.width / 2)); a.y = min(1 - a.height, max(0, click.y - a.height / 2))
            case .arrow:
                a.x = min(0.95, max(0.05, click.x + (click.x > 0.8 ? -0.12 : 0.12))); a.y = min(0.95, max(0.05, click.y + (click.y > 0.8 ? -0.12 : 0.12)))
                a.width = click.x - a.x; a.height = click.y - a.y
            case .touch:
                a.x = click.x; a.y = click.y; a.width = 0.14; a.height = 0; a.color = .blue
            case .step:
                a.x = click.x; a.y = click.y; a.width = 0; a.height = 0
            }
            settings.annotations.append(a)
            added += 1
        }
        return added
    }

    // MARK: Selecting several things

    /// Everything on the lanes with its place on the timeline; `row` names the lane.
    func timelineItems() -> [(item: EditorSelection, range: ClosedRange<Double>, row: String)] {
        var items: [(item: EditorSelection, range: ClosedRange<Double>, row: String)] = []
        func add(_ item: EditorSelection, _ range: ClosedRange<Double>?, _ row: String) {
            if let range { items.append((item, range, row)) }
        }
        for part in clipParts { add(.segment(part.range.lowerBound), clipRun(part), "clip") }
        for z in settings.zoomSegments { add(.zoom(z.id), displayRun(z.start, z.end), "zoom") }
        for c in settings.cursorRanges { add(.cursorRange(c.id), displayRun(c.start, c.end), "cursor") }
        for m in settings.masks { add(.mask(m.id), displayRun(m.start, m.end), "mask") }
        for a in settings.annotations { add(.annotation(a.id), displayRun(a.start, a.end), "annotation") }
        for t in settings.overlayTexts { add(.text(t.id), displayRange(start: t.start, end: t.end, free: t.isFree), "text") }
        for o in settings.images { add(.image(o.id), displayRange(start: o.start, end: o.end, free: o.isFree), "media") }
        for o in settings.videoOverlays { add(.videoOverlay(o.id), displayRange(o), "media") }
        for v in settings.voiceOvers { add(.voiceOver(v.id), displayRange(v), v.isMusic ? AudioLane.music.rawValue : AudioLane.voiceOver.rawValue) }
        return items
    }

    func selectGroup(_ items: [EditorSelection]) {
        guard let first = items.first else {
            multiSelection = []
            selection = nil
            return
        }
        if items.count == 1 { multiSelection = [] } else { multiSelection = items }
        selection = first
    }

    /// Selects everything that starts at or after the playhead.
    func selectRightOfPlayhead() {
        let here = display(currentTime) - 0.001
        selectGroup(timelineItems().filter { $0.range.lowerBound >= here }.map(\.item))
    }

    // MARK: Library

    private var libraryFolder: URL { project.url.appendingPathComponent("media", isDirectory: true) }

    /// The files of this project, ready to be used again.
    var mediaLibrary: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: libraryFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { Self.libraryKind($0) != nil }
            .sorted { Self.libraryName($0).localizedStandardCompare(Self.libraryName($1)) == .orderedAscending }
    }

    private static func libraryKind(_ url: URL) -> UTType? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        return [UTType.image, .movie, .audio].first { type.conforms(to: $0) }
    }

    static func libraryIcon(_ url: URL) -> String {
        switch libraryKind(url) {
        case UTType.image: return "photo"
        case UTType.movie: return "film"
        default: return "waveform"
        }
    }

    /// Without the number that keeps file names apart in the project.
    static func libraryName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count > 9, name[name.index(name.startIndex, offsetBy: 8)] == "-" else { return name }
        return String(name.dropFirst(9))
    }

    func importToLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .audio]
        panel.allowsMultipleSelection = true
        panel.message = "Dateien in die Bibliothek dieses Projekts übernehmen"
        guard panel.runModal() == .OK else { return }
        addToLibrary(panel.urls)
    }

    func addToLibrary(_ urls: [URL]) {
        for url in urls { _ = importMedia(url) }
        libraryVersion &+= 1
    }

    func useLibraryItem(_ url: URL) {
        switch Self.libraryKind(url) {
        case UTType.image: addImage(url: url, at: currentTime)
        case UTType.movie: addVideoOverlay(url: url, at: currentTime, name: Self.libraryName(url))
        case UTType.audio: addNarrationFile(url: url, at: currentTime)
        default: break
        }
    }
}
