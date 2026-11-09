import Foundation
import AppKit

/// A picture or video on the media lanes, as far as moving it over time is concerned.
enum MotionTarget: Equatable {
    case image(UUID), video(UUID)
}

/// Keyframes and lanes of media clips.
extension EditorModel {
    func keys(_ target: MotionTarget) -> [MotionKey] {
        switch target {
        case .image(let id): return settings.images.first { $0.id == id }?.keys ?? []
        case .video(let id): return settings.videoOverlays.first { $0.id == id }?.keys ?? []
        }
    }

    private func clipStart(_ target: MotionTarget) -> Double {
        switch target {
        case .image(let id):
            guard let o = settings.images.first(where: { $0.id == id }) else { return 0 }
            return displayRange(start: o.start, end: o.end, free: o.isFree)?.lowerBound ?? 0
        case .video(let id):
            guard let o = settings.videoOverlays.first(where: { $0.id == id }) else { return 0 }
            return displayRange(o).lowerBound
        }
    }

    /// Seconds from the start of the clip to the playhead.
    func clipTime(_ target: MotionTarget) -> Double { max(0, display(currentTime) - clipStart(target)) }

    func keyedImage(_ o: ImageOverlay) -> ImageOverlay { o.moved(at: clipTime(.image(o.id))) }
    func keyedVideo(_ o: VideoOverlay) -> VideoOverlay { o.moved(at: clipTime(.video(o.id))) }

    /// What the clip shows at the playhead.
    private func currentKey(_ target: MotionTarget) -> MotionKey? {
        let t = clipTime(target)
        switch target {
        case .image(let id):
            guard let o = settings.images.first(where: { $0.id == id }) else { return nil }
            let m = keyedImage(o)
            return MotionKey(t: t, x: m.x, y: m.y, width: m.width, opacity: m.opacity, volume: 1)
        case .video(let id):
            guard let o = settings.videoOverlays.first(where: { $0.id == id }) else { return nil }
            let m = keyedVideo(o)
            return MotionKey(t: t, x: m.x, y: m.y, width: m.width, opacity: m.opacity, volume: Motion.value(o.keys ?? [], at: t)?.volume ?? min(1, o.volume))
        }
    }

    private func setKeys(_ target: MotionTarget, _ keys: [MotionKey]) {
        let sorted = keys.isEmpty ? nil : keys.sorted { $0.t < $1.t }
        switch target {
        case .image(let id): updateImage(id: id) { $0.keys = sorted }
        case .video(let id): updateVideoOverlay(id: id) { $0.keys = sorted }
        }
    }

    /// A keyframe at the playhead, holding what is shown there.
    func addKey(_ target: MotionTarget) {
        guard let key = currentKey(target) else { return }
        commitUndoStep(); defer { commitUndoStep() }
        setKeys(target, keys(target).filter { abs($0.t - key.t) > 0.05 } + [key])
    }

    func removeKey(_ target: MotionTarget, _ id: UUID) {
        commitUndoStep(); defer { commitUndoStep() }
        setKeys(target, keys(target).filter { $0.id != id })
    }

    func clearKeys(_ target: MotionTarget) {
        guard let key = currentKey(target) else { return }
        commitUndoStep(); defer { commitUndoStep() }
        // The clip stays the way it looks right now.
        setKeys(target, [])
        apply(target) { $0.x = key.x; $0.y = key.y; $0.width = key.width; $0.opacity = key.opacity }
    }

    private func apply(_ target: MotionTarget, _ change: @escaping (inout any MotionPlaced) -> Void) {
        switch target {
        case .image(let id):
            updateImage(id: id) { o in
                var placed: any MotionPlaced = o
                change(&placed)
                if let done = placed as? ImageOverlay { o = done }
            }
        case .video(let id):
            updateVideoOverlay(id: id) { o in
                var placed: any MotionPlaced = o
                change(&placed)
                if let done = placed as? VideoOverlay { o = done }
            }
        }
    }

    /// Changes the place, size, opacity or volume at the playhead: on a clip with keyframes this
    /// edits or adds the keyframe there, otherwise the clip as a whole.
    func place(_ target: MotionTarget, x: Double? = nil, y: Double? = nil, width: Double? = nil, opacity: Double? = nil, volume: Double? = nil) {
        guard !keys(target).isEmpty, var key = currentKey(target) else {
            apply(target) { o in
                if let x { o.x = x }
                if let y { o.y = y }
                if let width { o.width = width }
                if let opacity { o.opacity = opacity }
            }
            if let volume, case .video(let id) = target { updateVideoOverlay(id: id) { $0.volume = volume } }
            return
        }
        var list = keys(target)
        if let i = list.firstIndex(where: { abs($0.t - key.t) <= 0.05 }) { key = list.remove(at: i) }
        if let x { key.x = min(1, max(0, x)) }
        if let y { key.y = min(1, max(0, y)) }
        if let width { key.width = min(1, max(0.03, width)) }
        if let opacity { key.opacity = min(1, max(0.05, opacity)) }
        if let volume { key.volume = min(1, max(0, volume)) }
        setKeys(target, list + [key])
    }

    // MARK: Lanes

    var mediaRows: Int {
        let used = (settings.images.map { $0.lane ?? 0 } + settings.videoOverlays.map { $0.lane ?? 0 }).max()
        guard let used else { return 1 }
        return min(EditSettings.maxMediaLanes, used + 2)   // one free lane to drag something to
    }

    func lane(_ target: MotionTarget) -> Int {
        switch target {
        case .image(let id): return settings.images.first { $0.id == id }?.lane ?? 0
        case .video(let id): return settings.videoOverlays.first { $0.id == id }?.lane ?? 0
        }
    }

    func setLane(_ target: MotionTarget, _ lane: Int) {
        let new = min(EditSettings.maxMediaLanes - 1, max(0, lane))
        guard new != self.lane(target) else { return }
        switch target {
        case .image(let id): updateImage(id: id) { $0.lane = new == 0 ? nil : new }
        case .video(let id): updateVideoOverlay(id: id) { $0.lane = new == 0 ? nil : new }
        }
    }

    // MARK: Following a mask

    /// Lets a mask follow what it covers, from its start to its end.
    func trackMask(_ id: UUID) {
        guard let mask = settings.masks.first(where: { $0.id == id }), trackingMask == nil else { return }
        trackingMask = id
        maskMessage = nil
        let url = project.url.appendingPathComponent(project.info.videoFile)
        Task {
            defer { trackingMask = nil }
            do {
                let points = try await Task.detached(priority: .userInitiated) { try await MaskTracker.track(url: url, mask: mask) }.value
                commitUndoStep(); defer { commitUndoStep() }
                updateMask(id: id) { $0.track = points.count > 1 ? points : nil }
                if points.count < 2 { maskMessage = "Der Inhalt ließ sich nicht verfolgen. Eine größere Maske um etwas Markantes hilft." }
            } catch {
                maskMessage = "Der Inhalt ließ sich nicht verfolgen: \(error.localizedDescription)"
            }
        }
    }

    /// Moves a mask from where it is shown at the moment; a followed path moves along.
    func moveMask(_ id: UUID, shownAt shown: CGPoint, to rect: CGRect) {
        updateMask(id: id) { m in
            let dx = Double(rect.minX - shown.x), dy = Double(rect.minY - shown.y)
            m.track = m.track?.map { MaskPoint(t: $0.t, x: min(1 - m.width, max(0, $0.x + dx)), y: min(1 - m.height, max(0, $0.y + dy))) }
            if m.track == nil {
                m.x = Double(rect.minX)
                m.y = Double(rect.minY)
            }
            m.width = Double(rect.width)
            m.height = Double(rect.height)
        }
    }

    // MARK: Rolling and slipping

    private func rename(_ old: Double, to new: Double, in s: inout EditSettings) {
        s.clipOrder = s.clipOrder?.map { abs($0 - old) < 1e-4 ? new : $0 }
        for i in s.joinTransitions.indices where abs(s.joinTransitions[i].key - old) < 1e-4 { s.joinTransitions[i].key = new }
    }

    /// Rolling: the join between two parts moves, the video keeps its length.
    func rollEdge(of part: EditSettings.ClipPart, isStart: Bool, dt: Double) {
        if rollOrigin == nil {
            let parts = clipParts
            guard let i = parts.firstIndex(where: { $0.key == part.key }) else { return }
            let j = isStart ? i : i + 1
            guard j > 0, j < parts.count else { return }
            beginInteraction()
            rollOrigin = RollOrigin(settings: settings, left: parts[j - 1], right: parts[j], rate: partRate(part))
        }
        guard let o = rollOrigin else { return }
        var s = o.settings
        let edge = o.left.range.upperBound, resume = o.right.range.lowerBound
        let delta = min(max(dt * o.rate, o.left.range.lowerBound + 0.1 - edge), o.right.range.upperBound - 0.1 - resume)
        // With a transition on the join the right part begins later; its key is still the place of the join.
        if abs(edge - o.right.key) < 1e-3, let k = s.splits.firstIndex(where: { abs($0 - edge) < 1e-3 }) {
            s.splits[k] = edge + delta
        } else if let c = s.cuts.firstIndex(where: { abs($0.start - edge) < 1e-3 && (abs($0.end - resume) < 1e-3 || abs($0.end - o.right.key) < 1e-3) }) {
            s.cuts[c].start += delta
            s.cuts[c].end += delta
        } else {
            return
        }
        rename(o.right.key, to: o.right.key + delta, in: &s)
        settings = s
    }

    /// Slipping: the part stays where it is and shows an earlier or later piece of the recording.
    func slipPart(_ part: EditSettings.ClipPart, dt: Double) {
        if let index = settings.inserts.firstIndex(where: { abs($0.sourceRange.lowerBound - part.range.lowerBound) < 1e-4 }) {
            if slipOrigin == nil {
                beginInteraction()
                slipOrigin = RollOrigin(settings: settings, left: part, right: part, rate: 1)
            }
            guard let o = slipOrigin else { return }
            let clip = o.settings.inserts[index]
            settings.inserts[index].fileOffset = min(max(0, clip.fileDuration - clip.duration), max(0, clip.fileOffset - dt))
            return
        }
        if slipOrigin == nil {
            beginInteraction()
            slipOrigin = RollOrigin(settings: settings, left: part, right: part, rate: partRate(part))
        }
        guard let o = slipOrigin else { return }
        let start = o.left.range.lowerBound, end = o.left.range.upperBound
        let origin = o.settings
        let oldEnd = min(origin.trimEnd ?? duration, duration)
        let leftCut = origin.cuts.firstIndex { abs($0.end - start) < 1e-3 || abs($0.end - o.left.key) < 1e-3 }
        let rightCut = origin.cuts.firstIndex { abs($0.start - end) < 1e-3 }
        let atStart = abs(start - origin.trimStart) < 1e-3, atEnd = abs(end - oldEnd) < 1e-3
        guard leftCut != nil || atStart, rightCut != nil || atEnd else { return }
        var low = -Double.infinity, high = Double.infinity
        if let l = leftCut { low = origin.cuts[l].start + 0.1 - origin.cuts[l].end } else { low = -origin.trimStart }
        if let r = rightCut { high = origin.cuts[r].end - 0.1 - origin.cuts[r].start } else { high = duration - oldEnd }
        guard low <= high else { return }
        let d = min(max(-dt * o.rate, low), high)   // dragged to the right, an earlier piece comes into view
        var s = origin
        if let l = leftCut { s.cuts[l].end += d } else { s.trimStart += d }
        if let r = rightCut {
            s.cuts[r].start += d
        } else {
            let e = oldEnd + d
            s.trimEnd = e >= duration - 0.001 ? nil : e
        }
        rename(o.left.key, to: o.left.key + d, in: &s)
        settings = s
    }

    func finishTrimDrag() {
        rollOrigin = nil
        slipOrigin = nil
        endInteraction()
    }

    func cycleTrimMode() {
        switch trimMode {
        case .normal: trimMode = .roll
        case .roll: trimMode = .slip
        case .slip: trimMode = .normal
        }
    }
}

/// Where a roll or slip began.
struct RollOrigin {
    var settings: EditSettings
    var left: EditSettings.ClipPart
    var right: EditSettings.ClipPart
    var rate: Double
}

enum TrimMode: String { case normal, roll, slip }
