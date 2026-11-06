import Foundation
import CoreMedia

/// Shared pause bookkeeping for screen, audio, camera and cursor (all on the host clock).
/// Samples inside a pause are dropped; later samples are shifted back by the paused time,
/// so every stream stays in sync without gaps.
final class PauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var intervals: [(start: Double, end: Double)] = []
    private var pausedSince: Double?

    var isPaused: Bool { lock.withLock { pausedSince != nil } }

    func reset() {
        lock.withLock { intervals = []; pausedSince = nil }
    }

    func pause(at t: Double) {
        lock.withLock { if pausedSince == nil { pausedSince = t } }
    }

    func resume(at t: Double) {
        lock.withLock {
            if let s = pausedSince {
                intervals.append((s, max(s, t)))
                pausedSince = nil
            }
        }
    }

    /// Host time → recording time (pauses removed). `nil` if `t` lies inside a pause.
    func adjust(_ t: Double) -> Double? {
        lock.withLock {
            if let s = pausedSince, t >= s { return nil }
            var offset = 0.0
            for iv in intervals {
                if t >= iv.end { offset += iv.end - iv.start }
                else if t >= iv.start { return nil }
            }
            return t - offset
        }
    }

    /// Recording time at host time `t`; while paused, the time at which the pause began.
    func recordingTime(at t: Double) -> Double {
        lock.withLock {
            let paused = intervals.reduce(0) { $0 + ($1.end - $1.start) }
            if let s = pausedSince { return min(t, s) - paused }
            return t - paused
        }
    }

    /// Copy of the sample buffer shifted by the paused time, or `nil` if it falls into a pause.
    func retime(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        let pts = sb.presentationTimeStamp
        guard pts.isValid else { return sb }
        guard let adjusted = adjust(pts.seconds) else { return nil }
        let offsetSeconds = pts.seconds - adjusted
        if offsetSeconds == 0 { return sb }
        let offset = CMTime(seconds: offsetSeconds, preferredTimescale: 1_000_000_000)
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sb }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for i in timings.indices {
            timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, offset)
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timings, sampleBufferOut: &out)
        return out
    }
}
