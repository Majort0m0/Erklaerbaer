import Foundation
import CoreGraphics

// MARK: - Auto zoom

enum AutoZoom {
    /// Seconds the zoom starts before a click.
    static let lead = 0.6
    /// Seconds the zoom holds after the last click of a cluster.
    static let hold = 2.4
    /// Clicks closer than this are merged into one zoom segment.
    static let mergeGap = 1.2

    static func segments(for clicks: [ClickEvent], duration: Double, scale: Double) -> [ZoomSegment] {
        guard duration > 0 else { return [] }
        var result: [ZoomSegment] = []
        for click in clicks.sorted(by: { $0.t < $1.t }) where click.isInsideCapture {
            let start = max(0, click.t - lead)
            let end = min(duration, click.t + hold)
            if var last = result.last, start <= last.end + mergeGap {
                last.end = max(last.end, end)
                result[result.count - 1] = last
            } else {
                result.append(ZoomSegment(start: start, end: end, scale: scale, isAuto: true))
            }
        }
        return result.filter { $0.end - $0.start >= 0.8 }
    }

    /// Eased zoom progress (0…1) of one segment at time `t`: ramps in, holds, ramps out.
    static func progress(at t: Double, in s: ZoomSegment) -> Double {
        guard t >= s.start && t <= s.end else { return 0 }
        let ramp = min(0.7, (s.end - s.start) / 2)
        guard ramp > 0 else { return 0 }
        let pIn = (t - s.start) / ramp
        let pOut = (s.end - t) / ramp
        return smootherstep(min(1, min(pIn, pOut)))
    }

    /// The segment that determines the zoom at time `t` (largest zoom wins) and its progress.
    static func dominant(at t: Double, segments: [ZoomSegment]) -> (segment: ZoomSegment, progress: Double)? {
        var best: (segment: ZoomSegment, progress: Double)?
        var bestZoom = 1.0
        for s in segments where t >= s.start && t <= s.end && s.scale > 1 {
            let p = progress(at: t, in: s)
            let z = 1 + (s.scale - 1) * p
            if z > bestZoom { bestZoom = z; best = (s, p) }
        }
        return best
    }

    /// Zoom factor (≥1) at time `t`.
    static func zoom(at t: Double, segments: [ZoomSegment]) -> Double {
        guard let d = dominant(at: t, segments: segments) else { return 1 }
        return 1 + (d.segment.scale - 1) * d.progress
    }

    static func smootherstep(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}

// MARK: - Cursor motion

/// Precomputed, spring-smoothed cursor paths sampled at a fixed rate.
/// `cursor` is the visible (lightly smoothed) cursor, `focus` the slower
/// camera target used while zoomed in.
struct MotionPaths {
    static let rate = 240.0

    var cursorX: [Double] = []
    var cursorY: [Double] = []
    var focusX: [Double] = []
    var focusY: [Double] = []
    var duration: Double = 0

    init() {}

    init(track: CursorTrack, duration: Double, smoothing: Double) {
        self.duration = duration
        let samples = track.samples
        guard !samples.isEmpty, duration > 0 else { return }
        let n = Int(duration * Self.rate) + 2
        let dt = 1 / Self.rate

        // Raw path resampled at fixed rate (linear interpolation).
        var rawX = [Double](repeating: 0, count: n)
        var rawY = [Double](repeating: 0, count: n)
        var j = 0
        for i in 0..<n {
            let t = Double(i) * dt
            while j + 1 < samples.count && samples[j + 1].t <= t { j += 1 }
            let a = samples[j]
            if j + 1 < samples.count, samples[j + 1].t > a.t, t >= a.t {
                let b = samples[j + 1]
                let f = (t - a.t) / (b.t - a.t)
                rawX[i] = a.x + (b.x - a.x) * f
                rawY[i] = a.y + (b.y - a.y) * f
            } else {
                rawX[i] = a.x
                rawY[i] = a.y
            }
        }

        // Critically damped springs. Higher omega = snappier.
        let s = min(1, max(0, smoothing))
        let cursorOmega = s < 0.01 ? 0 : 60 - 50 * s     // 60 … 10 rad/s
        let focusOmega = 3.2

        func spring(_ input: [Double], omega: Double) -> [Double] {
            guard omega > 0 else { return input }
            var out = [Double](repeating: 0, count: input.count)
            var x = input[0], v = 0.0
            for i in 0..<input.count {
                let a = omega * omega * (input[i] - x) - 2 * omega * v
                v += a * dt
                x += v * dt
                out[i] = x
            }
            return out
        }
        cursorX = spring(rawX, omega: cursorOmega)
        cursorY = spring(rawY, omega: cursorOmega)
        focusX = spring(rawX, omega: focusOmega)
        focusY = spring(rawY, omega: focusOmega)
    }

    private func lookup(_ arr: [Double], _ t: Double) -> Double? {
        guard !arr.isEmpty else { return nil }
        let p = max(0, t) * Self.rate
        let i = min(arr.count - 1, Int(p))
        let k = min(arr.count - 1, i + 1)
        let f = p - Double(i)
        return arr[i] + (arr[k] - arr[i]) * min(1, max(0, f))
    }

    func cursor(at t: Double) -> CGPoint? {
        guard let x = lookup(cursorX, t), let y = lookup(cursorY, t) else { return nil }
        return CGPoint(x: x, y: y)
    }

    func focus(at t: Double) -> CGPoint? {
        guard let x = lookup(focusX, t), let y = lookup(focusY, t) else { return nil }
        return CGPoint(x: x, y: y)
    }
}

extension ClickEvent {
    var isInsideCapture: Bool { x >= -0.01 && x <= 1.01 && y >= -0.01 && y <= 1.01 }
}

extension CursorTrack {
    /// Index of the cursor image active at time t.
    func imageIndex(at t: Double) -> Int {
        guard !samples.isEmpty else { return -1 }
        var lo = 0, hi = samples.count - 1
        if t <= samples[0].t { return samples[0].c }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        return samples[lo].c
    }

    /// Seconds since the cursor last moved noticeably (for hiding an idle cursor).
    func idleTime(at t: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        let ref = samples[lo]
        var i = lo
        while i > 0 {
            let s = samples[i - 1]
            if abs(s.x - ref.x) > 0.002 || abs(s.y - ref.y) > 0.002 { return t - samples[i].t }
            i -= 1
        }
        return t - samples[0].t
    }
}
