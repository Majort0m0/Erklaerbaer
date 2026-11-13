import Foundation

/// Joining clips that were split: neighbors that run on seamlessly become one clip again
/// (the main track, the media lanes, voice-over and music clips).
extension EditorModel {
    /// Two neighboring clips that would become one.
    enum JoinPair: Equatable {
        /// Main track: the split point (source time) between two parts.
        case parts(at: Double)
        /// Media lane or voice-over/music lane: the second clip goes into the first.
        case videoOverlays(UUID, UUID)
        case voiceOvers(UUID, UUID)
    }

    // MARK: What can be joined

    /// The split point between two parts that follow each other in playing order, if the
    /// recording runs on seamlessly from `a` into `b` (only a split separates them).
    func splitPoint(after a: EditSettings.ClipPart, before b: EditSettings.ClipPart) -> Double? {
        let t = a.range.upperBound
        guard abs(b.key - t) < 1e-4, settings.splits.contains(where: { abs($0 - t) < 1e-4 }),
              // The border of an inserted clip stays a border.
              !settings.inserts.contains(where: { abs($0.sourceRange.lowerBound - t) < 1e-6 || abs($0.sourceRange.upperBound - t) < 1e-6 })
        else { return nil }
        return t
    }

    /// True if video `b` continues `a` without a jump: the same file in the same lane, right
    /// after it on the timeline and in the file.
    func continues(_ a: VideoOverlay, _ b: VideoOverlay) -> Bool {
        guard a.id != b.id, a.file == b.file, (a.lane ?? 0) == (b.lane ?? 0), a.synced == b.synced, a.isFree == b.isFree,
              a.rotation == b.rotation, abs(displayRange(a).upperBound - displayRange(b).lowerBound) < 0.02 else { return false }
        // A synced window plays at the recording's clock: its file offset does not move with a split.
        return a.synced ? abs(a.fileOffset - b.fileOffset) < 0.02 : abs(a.fileOffset + a.duration - b.fileOffset) < 0.02
    }

    /// True if voice-over or music clip `b` continues `a` without a jump.
    func continues(_ a: VoiceOverClip, _ b: VoiceOverClip) -> Bool {
        a.id != b.id && a.file == b.file && a.isMusic == b.isMusic && a.isFree == b.isFree
            && abs(a.fileOffset + a.duration - b.fileOffset) < 0.02
            && abs(displayRange(a).upperBound - displayRange(b).lowerBound) < 0.02
    }

    /// The selected clip's neighbors it can be joined with (with nothing selected: the part of
    /// the video under the playhead).
    var joinNeighbors: (previous: JoinPair?, next: JoinPair?) {
        switch selection {
        case .segment(let start):
            return partNeighbors { abs($0.range.lowerBound - start) < 1e-6 }
        case .insert(let id):
            guard let clip = settings.inserts.first(where: { $0.id == id }) else { return (nil, nil) }
            return partNeighbors { abs($0.range.lowerBound - clip.sourceRange.lowerBound) < 1e-6 }
        case .join(let key):
            let parts = clipParts
            guard let i = parts.firstIndex(where: { abs($0.key - key) < 1e-4 }), i > 0,
                  let t = splitPoint(after: parts[i - 1], before: parts[i]) else { return (nil, nil) }
            return (nil, .parts(at: t))
        case .videoOverlay(let id):
            guard let o = settings.videoOverlays.first(where: { $0.id == id }) else { return (nil, nil) }
            let all = settings.videoOverlays
            return (all.first { continues($0, o) }.map { .videoOverlays($0.id, o.id) },
                    all.first { continues(o, $0) }.map { .videoOverlays(o.id, $0.id) })
        case .voiceOver(let id):
            guard let c = settings.voiceOvers.first(where: { $0.id == id }) else { return (nil, nil) }
            let all = settings.voiceOvers
            return (all.first { continues($0, c) }.map { .voiceOvers($0.id, c.id) },
                    all.first { continues(c, $0) }.map { .voiceOvers(c.id, $0.id) })
        case nil:
            let T = display(currentTime)
            return partNeighbors { clipRun($0).map { T >= $0.lowerBound && T < $0.upperBound } ?? false }
        default:
            return (nil, nil)
        }
    }

    /// The neighbors of a part of the video it can be joined with.
    func joinNeighbors(of part: EditSettings.ClipPart) -> (previous: JoinPair?, next: JoinPair?) {
        partNeighbors { abs($0.key - part.key) < 1e-4 }
    }

    private func partNeighbors(_ isPart: (EditSettings.ClipPart) -> Bool) -> (previous: JoinPair?, next: JoinPair?) {
        let parts = clipParts
        guard let i = parts.firstIndex(where: isPart) else { return (nil, nil) }
        let previous = i > 0 ? splitPoint(after: parts[i - 1], before: parts[i]) : nil
        let next = i + 1 < parts.count ? splitPoint(after: parts[i], before: parts[i + 1]) : nil
        return (previous.map { .parts(at: $0) }, next.map { .parts(at: $0) })
    }

    /// What "Verbinden" (⇧S) joins: several selected clips that follow each other seamlessly;
    /// else the selected clip with the next one (or, at the end, the one before); with nothing
    /// selected the part under the playhead with the neighbor whose join is nearer.
    var joinPlan: [JoinPair] {
        if multiSelection.count > 1 { return groupJoins }
        let n = joinNeighbors
        if selection == nil, let previous = n.previous, let next = n.next {
            // The nearer join: right after a split (S) the playhead stands on it.
            let T = display(currentTime)
            guard case .parts(let a) = previous, case .parts(let b) = next else { return [next] }
            return [abs(display(a) - T) <= abs(display(b) - T) ? previous : next]
        }
        return [n.next ?? n.previous].compactMap { $0 }
    }

    /// Joins among the selected clips.
    private var groupJoins: [JoinPair] {
        var pairs: [JoinPair] = []
        let parts = clipParts
        func selected(_ p: EditSettings.ClipPart) -> Bool {
            isInGroup(.segment(p.range.lowerBound))
                || settings.inserts.contains { abs($0.sourceRange.lowerBound - p.range.lowerBound) < 1e-6 && isInGroup(.insert($0.id)) }
        }
        for (a, b) in zip(parts, parts.dropFirst()) where selected(a) && selected(b) {
            if let t = splitPoint(after: a, before: b) { pairs.append(.parts(at: t)) }
        }
        let overlays = settings.videoOverlays.filter { isInGroup(.videoOverlay($0.id)) }.sorted { displayRange($0).lowerBound < displayRange($1).lowerBound }
        for a in overlays {
            if let b = overlays.first(where: { continues(a, $0) }) { pairs.append(.videoOverlays(a.id, b.id)) }
        }
        let voices = settings.voiceOvers.filter { isInGroup(.voiceOver($0.id)) }.sorted { displayRange($0).lowerBound < displayRange($1).lowerBound }
        for a in voices {
            if let b = voices.first(where: { continues(a, $0) }) { pairs.append(.voiceOvers(a.id, b.id)) }
        }
        return pairs
    }

    // MARK: Joining

    /// Joins what `joinPlan` names (one undo step).
    func joinClips() { join(joinPlan) }

    /// Makes each pair one clip; the joined clip is selected afterwards.
    func join(_ pairs: [JoinPair]) {
        guard !pairs.isEmpty else { return }
        commitUndoStep(); defer { commitUndoStep() }   // one undo step of its own
        var points: [Double] = []
        // Clips already joined into another one (a chain of three becomes one).
        var into: [UUID: UUID] = [:]
        func target(_ id: UUID) -> UUID {
            var id = id
            while let next = into[id] { id = next }
            return id
        }
        var joined: EditorSelection?
        for pair in pairs {
            switch pair {
            case .parts(let t):
                points.append(t)
            case .videoOverlays(let first, let second):
                let a = target(first)
                guard let o = settings.videoOverlays.first(where: { $0.id == a }),
                      let next = settings.videoOverlays.first(where: { $0.id == second }) else { continue }
                updateVideoOverlay(id: a) {
                    $0.duration = o.duration + next.duration
                    $0.keys = Motion.joined(o.keys, next.keys, offset: o.duration)
                }
                settings.videoOverlays.removeAll { $0.id == second }
                into[second] = a
                joined = joined ?? .videoOverlay(a)
            case .voiceOvers(let first, let second):
                let a = target(first)
                guard let c = settings.voiceOvers.first(where: { $0.id == a }),
                      let next = settings.voiceOvers.first(where: { $0.id == second }) else { continue }
                updateVoiceOver(id: a) {
                    $0.duration = c.duration + next.duration
                    $0.fadeOut = next.fadeOut
                }
                settings.voiceOvers.removeAll { $0.id == second }
                into[second] = a
                joined = joined ?? .voiceOver(a)
            }
        }
        if !points.isEmpty {
            let first = clipParts.first { p in points.contains { abs(p.range.upperBound - $0) < 1e-4 } }
            joinParts(at: points)
            if joined == nil, let first {
                let clip = settings.inserts.first { abs($0.sourceRange.lowerBound - first.range.lowerBound) < 1e-6 }
                joined = clip.map { .insert($0.id) } ?? .segment(first.range.lowerBound)
            }
        }
        multiSelection = []   // the group became one clip
        selection = joined
    }

    /// Removes split points; their transitions go with them and the saved order forgets them.
    private func joinParts(at points: [Double]) {
        func isJoined(_ t: Double) -> Bool { points.contains { abs($0 - t) < 1e-4 } }
        settings.splits.removeAll(where: isJoined)
        settings.joinTransitions.removeAll { isJoined($0.key) }
        if let order = settings.clipOrder {
            settings.clipOrder = order.filter { !isJoined($0) }
            let parts = clipParts
            if zip(parts, parts.dropFirst()).allSatisfy({ $0.range.lowerBound < $1.range.lowerBound }) { settings.clipOrder = nil }
        }
    }
}

extension Motion {
    /// Keyframes of a clip split `t` seconds after its start. Each half keeps its own keys (the
    /// second half's counted from its own start). Where the movement goes on across the cut, or a
    /// half has no key of its own, the half gets a key at the cut with what is shown there.
    static func split(_ keys: [MotionKey]?, at t: Double) -> (first: [MotionKey]?, second: [MotionKey]?) {
        guard let keys, !keys.isEmpty, let here = value(keys, at: t) else { return (keys, keys) }
        func key(at time: Double) -> MotionKey {
            var k = here
            k.id = UUID()
            k.t = time
            return k
        }
        let before = keys.filter { $0.t < t - 1e-3 }
        let after = keys.filter { $0.t > t + 1e-3 }.map { k -> MotionKey in
            var k = k
            k.t -= t
            return k
        }
        let atCut = keys.count > before.count + after.count
        var first = before
        if !after.isEmpty || atCut || first.isEmpty { first.append(key(at: t)) }
        var second = after
        if !before.isEmpty || atCut || second.isEmpty { second.insert(key(at: 0), at: 0) }
        return (first.sorted { $0.t < $1.t }, second)
    }

    /// Keyframes of two clips joined into one (`b`'s keys start `offset` seconds later). The key
    /// a split put at the cut goes again when the movement runs through it anyway, so split and
    /// joined again moves exactly as before. (Halves split by older versions carry identical keys:
    /// those stay as they were.)
    static func joined(_ a: [MotionKey]?, _ b: [MotionKey]?, offset: Double) -> [MotionKey]? {
        let first = a ?? [], second = b ?? []
        guard !second.isEmpty, second != first else { return a }
        var list = first.filter { $0.t <= offset + 1e-3 }
        for var key in second where key.t >= -1e-3 {
            key.t += offset
            if !list.contains(where: { abs($0.t - key.t) < 0.05 }) { list.append(key) }
        }
        list.sort { $0.t < $1.t }
        if let i = list.firstIndex(where: { abs($0.t - offset) < 0.05 }) {
            var without = list
            let cut = without.remove(at: i)
            if !without.isEmpty, let v = value(without, at: cut.t), v.matches(cut) { list = without }
        }
        return list.isEmpty ? nil : list
    }
}

extension MotionKey {
    /// Same place, size, opacity and volume (time and id aside).
    func matches(_ other: MotionKey) -> Bool {
        abs(x - other.x) < 1e-6 && abs(y - other.y) < 1e-6 && abs(width - other.width) < 1e-6
            && abs(opacity - other.opacity) < 1e-6 && abs(volume - other.volume) < 1e-6
    }
}
