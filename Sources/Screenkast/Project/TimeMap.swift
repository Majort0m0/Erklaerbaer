import Foundation

/// A part of the recording played faster or slower (source time; rate 2 = twice as fast).
struct SpeedRange: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var rate: Double
}

/// Freeze frame: the picture at `at` (source time, usually the end of a part) stands still for
/// `duration` seconds, e.g. to explain something.
///
/// It is made from a tiny source range before `at` stretched over the duration. So every moment
/// of the freeze still has its own source time, and texts or voice-overs can start inside it.
struct FreezeFrame: Codable, Identifiable, Equatable {
    var id = UUID()
    var at: Double
    var duration: Double

    static let span = 0.001
    var sourceRange: ClosedRange<Double> { max(0, at - Self.span)...max(at, Self.span) }
}

/// How the two parts at a cut blend when they are pushed over each other.
enum TransitionStyle: String, Codable, CaseIterable, Identifiable {
    case dissolve, dipToBlack, push
    var id: String { rawValue }

    var label: String {
        switch self {
        case .dissolve: return "Überblenden"
        case .dipToBlack: return "Über Schwarz"
        case .push: return "Schieben"
        }
    }
}

/// Source time ↔ timeline time. Speed ranges compress or stretch the recording, freeze frames
/// stretch a tiny range over their duration. Outside the recording (intro < 0, outro > duration)
/// both run at the same rate.
struct TimeMap: Equatable {
    struct Piece: Equatable {
        let source: ClosedRange<Double>
        let timeline: ClosedRange<Double>
        /// Freeze frame or inserted clip: no recording sound, the picture stands still.
        let isFreeze: Bool
        /// Inserted clip shown instead of the recording.
        var insertID: UUID? = nil

        /// Source seconds per timeline second.
        var rate: Double {
            let t = timeline.upperBound - timeline.lowerBound
            return t > 0 ? (source.upperBound - source.lowerBound) / t : 1
        }
        func timeline(_ s: Double) -> Double { timeline.lowerBound + (s - source.lowerBound) / rate }
        func source(_ t: Double) -> Double { source.lowerBound + (t - timeline.lowerBound) * rate }
    }

    let duration: Double
    let pieces: [Piece]

    /// Length of the recording on the timeline.
    var total: Double { pieces.last?.timeline.upperBound ?? duration }
    var isIdentity: Bool { pieces.allSatisfy { !$0.isFreeze && abs($0.rate - 1) < 1e-12 } }

    init(duration: Double, speeds: [SpeedRange] = [], freezes: [FreezeFrame] = [], inserts: [InsertClip] = []) {
        self.duration = duration
        let d = max(0, duration)
        let speeds = speeds.compactMap { s -> (ClosedRange<Double>, Double)? in
            let lo = max(0, s.start), hi = min(d, s.end)
            return hi > lo && s.rate > 0.01 ? (lo...hi, s.rate) : nil
        }
        // Freeze frames and inserted clips both stretch a tiny range (inserts carry their id).
        let freezes = freezes.compactMap { f -> (ClosedRange<Double>, Double, UUID?)? in
            let r = f.sourceRange.clamped(to: 0...d)
            return r.upperBound > r.lowerBound && f.duration > 0.01 ? (r, f.duration, nil) : nil
        } + inserts.compactMap { c -> (ClosedRange<Double>, Double, UUID?)? in
            let r = c.sourceRange.clamped(to: 0...d)
            return r.upperBound > r.lowerBound && c.duration > 0.05 ? (r, c.duration, c.id) : nil
        }
        var points: Set<Double> = [0, d]
        for (r, _) in speeds { points.insert(r.lowerBound); points.insert(r.upperBound) }
        for (r, _, _) in freezes { points.insert(r.lowerBound); points.insert(r.upperBound) }
        var pieces: [Piece] = []
        var t = 0.0
        let sorted = points.sorted()
        for (a, b) in zip(sorted, sorted.dropFirst()) where b - a > 1e-9 {
            let mid = (a + b) / 2
            var length = b - a
            var freeze = false
            var insertID: UUID?
            if let f = freezes.last(where: { $0.0.contains(mid) }) {
                length = f.1 * (b - a) / (f.0.upperBound - f.0.lowerBound)
                freeze = true
                insertID = f.2
            } else if let s = speeds.last(where: { $0.0.contains(mid) }) {
                length = (b - a) / s.1
            }
            // Neighbors at the same speed form one piece.
            if !freeze, let last = pieces.last, !last.isFreeze, abs(last.rate - (b - a) / length) < 1e-9 {
                pieces[pieces.count - 1] = Piece(source: last.source.lowerBound...b, timeline: last.timeline.lowerBound...(t + length), isFreeze: false)
            } else {
                pieces.append(Piece(source: a...b, timeline: t...(t + length), isFreeze: freeze, insertID: insertID))
            }
            t += length
        }
        self.pieces = pieces
    }

    private func pieceIndex(source s: Double) -> Int? {
        var lo = 0, hi = pieces.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let p = pieces[mid]
            if s < p.source.lowerBound { hi = mid - 1 } else if s > p.source.upperBound { lo = mid + 1 } else { return mid }
        }
        return nil
    }

    private func pieceIndex(timeline t: Double) -> Int? {
        var lo = 0, hi = pieces.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let p = pieces[mid]
            if t < p.timeline.lowerBound { hi = mid - 1 } else if t > p.timeline.upperBound { lo = mid + 1 } else { return mid }
        }
        return nil
    }

    /// Timeline time of a source time.
    func timeline(_ s: Double) -> Double {
        if s <= 0 || pieces.isEmpty { return s }
        if s >= duration { return total + (s - duration) }
        return pieceIndex(source: s).map { pieces[$0].timeline(s) } ?? s
    }

    /// Source time of a timeline time.
    func source(_ t: Double) -> Double {
        if t <= 0 || pieces.isEmpty { return t }
        if t >= total { return duration + (t - total) }
        return pieceIndex(timeline: t).map { pieces[$0].source(t) } ?? t
    }

    /// Length of a source range on the timeline.
    func length(_ r: ClosedRange<Double>) -> Double { timeline(r.upperBound) - timeline(r.lowerBound) }

    /// The pieces covering a source range, clipped to it.
    func pieces(in r: ClosedRange<Double>) -> [Piece] {
        pieces.compactMap { p in
            let lo = max(p.source.lowerBound, r.lowerBound), hi = min(p.source.upperBound, r.upperBound)
            guard hi > lo else { return nil }
            return Piece(source: lo...hi, timeline: p.timeline(lo)...p.timeline(hi), isFreeze: p.isFreeze, insertID: p.insertID)
        }
    }

    /// The inserted clip shown at source time `s` (nil: the recording).
    func insertID(atSource s: Double) -> UUID? {
        pieces.first { $0.insertID != nil && s >= $0.source.lowerBound && s < $0.source.upperBound }?.insertID
    }

    /// True if timeline time `t` lies in a freeze frame.
    func isFrozen(atTimeline t: Double) -> Bool {
        guard t > 0, t < total, let i = pieceIndex(timeline: t) else { return false }
        return pieces[i].isFreeze
    }
}

extension EditSettings {
    func timeMap(duration: Double) -> TimeMap {
        TimeMap(duration: duration, speeds: speeds, freezes: freezes, inserts: inserts)
    }
}
