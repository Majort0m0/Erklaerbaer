import Foundation
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
        let others = parts.filter { $0.key != drag.key }
        return others.filter { other in
            guard let r = clipRun(other) else { return false }
            return (r.lowerBound + r.upperBound) / 2 < center
        }.count
    }

    /// Timeline position of the gap a dragged part would land in (for the marker).
    func clipDropPosition(_ drag: ClipDrag) -> Double? {
        guard let index = clipDropIndex(drag) else { return nil }
        let others = clipParts.filter { $0.key != drag.key }
        if index < others.count { return clipRun(others[index])?.lowerBound }
        return others.last.flatMap { clipRun($0)?.upperBound }
    }

    /// Moves a part to position `index` among the other parts. Everything anchored to it comes along.
    func moveClip(key: Double, to index: Int) {
        var parts = clipParts
        guard let from = parts.firstIndex(where: { $0.key == key }) else { return }
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

    func copySelection() {
        switch selection {
        case .text(let id): if let t = settings.texts.first(where: { $0.id == id }), t.placement == .overlay || t.kind == .lowerThird { clipboard = .text(t) }
        case .image(let id): clipboard = settings.images.first { $0.id == id }.map { .image($0) }
        case .mask(let id): clipboard = settings.masks.first { $0.id == id }.map { .mask($0) }
        case .annotation(let id): clipboard = settings.annotations.first { $0.id == id }.map { .annotation($0) }
        case .zoom(let id): clipboard = settings.zoomSegments.first { $0.id == id }.map { .zoom($0) }
        case .videoOverlay(let id): clipboard = settings.videoOverlays.first { $0.id == id && !$0.synced }.map { .overlay($0) }
        case .voiceOver(let id): clipboard = settings.voiceOvers.first { $0.id == id }.map { .voice($0) }
        default: break
        }
    }

    /// Source range of a copy that begins at the playhead and is as long as the original.
    private func pasted(start: Double, end: Double) -> (start: Double, end: Double) {
        let run = displayRun(start, end)
        let length = (run?.upperBound ?? display(end)) - (run?.lowerBound ?? display(start))
        let T = min(display(currentTime), max(0, timeMap.total - length))
        return (sourceTime(T), timeMap.sourceEnd(min(timeMap.total, T + max(0.1, length))))
    }

    /// Puts a copy of what was copied at the playhead.
    func pasteClipboard() {
        guard let clipboard, currentTime >= 0, currentTime <= duration else { return }
        commitUndoStep(); defer { commitUndoStep() }
        let T = display(currentTime)
        switch clipboard {
        case .text(var t):
            t.id = UUID()
            if t.isFree { let l = t.end - t.start; t.start = T; t.end = min(timeMap.total, T + l) } else { (t.start, t.end) = pasted(start: t.start, end: t.end) }
            settings.texts.append(t)
            selection = .text(t.id)
        case .image(var o):
            o.id = UUID()
            if o.isFree { let l = o.end - o.start; o.start = T; o.end = min(timeMap.total, T + l) } else { (o.start, o.end) = pasted(start: o.start, end: o.end) }
            settings.images.append(o)
            selection = .image(o.id)
        case .mask(var m):
            m.id = UUID()
            (m.start, m.end) = pasted(start: m.start, end: m.end)
            settings.masks.append(m)
            selection = .mask(m.id)
        case .annotation(var a):
            a.id = UUID()
            (a.start, a.end) = pasted(start: a.start, end: a.end)
            settings.annotations.append(a)
            selection = .annotation(a.id)
        case .zoom(var z):
            z.id = UUID()
            z.isAuto = false
            (z.start, z.end) = pasted(start: z.start, end: z.end)
            settings.zoomSegments.append(z)
            selection = .zoom(z.id)
        case .overlay(var o):
            o.id = UUID()
            o.start = o.isFree ? T : currentTime
            settings.videoOverlays.append(o)
            selection = .videoOverlay(o.id)
        case .voice(var c):
            c.id = UUID()
            c.start = c.isFree ? T : currentTime
            settings.voiceOvers.append(c)
            selection = .voiceOver(c.id)
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
}
