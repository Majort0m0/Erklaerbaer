import Foundation
import AVFoundation
import Accelerate

/// A voice edited in another program (e.g. a podcast editor) that replaces the microphone.
struct ImportedVoice: Codable, Equatable {
    /// File in the project (48 kHz mono, as long as the recording, lined up with it).
    var file: String
    /// Name of the file it came from.
    var name: String
}

enum VoiceExchangeError: LocalizedError {
    case noVoice, silent
    var errorDescription: String? {
        switch self {
        case .noVoice: return "Die Aufnahme hat keine Mikrofonspur."
        case .silent: return "In der Datei ist nichts zu hören."
        }
    }
}

/// The voice of the recording as its own file: exported whole and uncut, edited elsewhere and
/// imported again. The import is lined up with the recording by its sound, so a short silence
/// or jingle before it or an encoder delay (MP3) does not shift it against the picture.
enum VoiceExchange {
    static let sampleRate = VoiceProcessor.sampleRate

    /// The voice as recorded (echo-free when echo removal is on), on the recording's time.
    static func originalVoice(project: Project, settings: EditSettings) async throws -> [Float] {
        let clean = EchoCanceller.cleanURL(for: project)
        if settings.removeEcho, FileManager.default.fileExists(atPath: clean.path) {
            return try await VoiceProcessor.readFile(clean)
        }
        let asset = AVURLAsset(url: project.videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let roles = await AudioRole.roles(of: tracks, fallback: project.info.audioRoles)
        guard let i = roles.firstIndex(of: "mic") else { throw VoiceExchangeError.noVoice }
        return try await EchoCanceller.readMono(track: tracks[i], asset: asset, duration: try await asset.load(.duration).seconds)
    }

    /// WAV, 48 kHz, 24 bit, mono.
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 65536
        var start = 0
        while start < samples.count {
            let count = min(chunk, samples.count - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { s in buffer.floatChannelData![0].update(from: s.baseAddress! + start, count: count) }
            try file.write(from: buffer)
            start += count
        }
    }

    struct Placement: Equatable {
        /// Samples the voice starts later than the recording (a lead-in before it); negative: earlier.
        var lag: Int
        /// The sound matched clearly.
        var found: Bool
        /// The end matches too (nothing cut out of the file, same speed).
        var endFits: Bool
    }

    /// Reads, lines up and stores the voice in the project. Returns it and a note for the user.
    static func importVoice(from source: URL, project: Project, settings: EditSettings) async throws -> (voice: ImportedVoice, note: String) {
        let reference = try await originalVoice(project: project, settings: settings)
        let voice = try await VoiceProcessor.readFile(source)
        guard voice.contains(where: { abs($0) > 1e-4 }) else { throw VoiceExchangeError.silent }
        let placement = place(voice, against: reference)
        let aligned = shifted(voice, by: placement.lag, count: reference.count)
        // Next to the other sound files of the project, not in the media library.
        let file = "stimme-import-\(UUID().uuidString.prefix(8)).caf"
        try VoiceProcessor.write(aligned, to: project.url.appendingPathComponent(file))

        var note: String
        if !placement.found {
            note = "Die Stimme ließ sich nicht sicher an der Aufnahme ausrichten und beginnt wie die Aufnahme bei 0:00."
        } else if abs(placement.lag) < Int(0.002 * sampleRate) {
            note = "Passt genau zur Aufnahme."
        } else {
            let ms = Int((Double(placement.lag) / sampleRate * 1000).rounded())
            note = ms > 0 ? "Um \(ms) ms vorgezogen, damit sie zum Bild passt." : "Um \(-ms) ms nach hinten gerückt, damit sie zum Bild passt."
        }
        let extra = Double(voice.count - placement.lag - reference.count) / sampleRate
        if abs(extra) > 0.5 {
            note += String(format: extra > 0 ? " Die Datei ist %.1f s länger, der Rest wird nicht verwendet." : " Die Datei ist %.1f s kürzer, danach ist die Stimme still.", abs(extra))
        }
        if placement.found, !placement.endFits {
            note += " Achtung: Gegen Ende passt die Stimme nicht mehr zum Bild – wurden in der Datei Pausen gekürzt oder etwas herausgeschnitten?"
        }
        return (ImportedVoice(file: file, name: source.lastPathComponent), note)
    }

    /// The voice moved by `lag` samples (positive: its start is dropped) and cut or padded to `count`.
    static func shifted(_ voice: [Float], by lag: Int, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let j = i + lag
            if j >= 0, j < voice.count { out[i] = voice[j] }
        }
        return out
    }

    // MARK: Lining up

    /// Where the voice lies against the recording: its loudness curve compared with the
    /// recording's, first in 10 ms steps over ±30 s, then in 1 ms steps around the best match.
    static func place(_ voice: [Float], against reference: [Float]) -> Placement {
        let coarseHop = Int(sampleRate / 100), fineHop = Int(sampleRate / 1000)
        let a = envelope(reference, hop: coarseHop), b = envelope(voice, hop: coarseHop)
        guard a.count > 50, b.count > 50 else { return Placement(lag: 0, found: false, endFits: true) }
        let coarse = bestLag(a, b, lags: -3000...3000)
        guard coarse.score > 0.35 else { return Placement(lag: 0, found: false, endFits: true) }
        let af = envelope(reference, hop: fineHop), bf = envelope(voice, hop: fineHop)
        let center = coarse.lag * (coarseHop / fineHop)
        let fine = bestLag(af, bf, lags: (center - 15)...(center + 15))
        // The last third on its own: does it still match at the same place?
        let tail = Array(a[(a.count * 2 / 3)...])
        let tailLag = bestLag(tail, b, lags: (coarse.lag - 1000)...(coarse.lag + 1000), offset: a.count * 2 / 3)
        let endFits = tailLag.score < 0.35 || abs(tailLag.lag - coarse.lag) <= 3
        return Placement(lag: fine.lag * fineHop, found: true, endFits: endFits)
    }

    /// Loudness curve in dB (floor 50 dB below the loudest part), without its mean, unit length.
    private static func envelope(_ x: [Float], hop: Int) -> [Float] {
        let n = x.count / hop
        guard n > 0 else { return [] }
        var e = [Float](repeating: 0, count: n)
        x.withUnsafeBufferPointer { p in
            for i in 0..<n {
                var ms: Float = 0
                vDSP_measqv(p.baseAddress! + i * hop, 1, &ms, vDSP_Length(hop))
                e[i] = ms
            }
        }
        let peak = e.max() ?? 0
        guard peak > 0 else { return e }
        let floor = peak * 1e-5
        e = e.map { 10 * log10(max($0, floor)) }
        let mean = vDSP.mean(e)
        e = vDSP.add(-mean, e)
        let norm = sqrt(vDSP.sumOfSquares(e))
        return norm > 0 ? vDSP.divide(e, norm) : e
    }

    /// The shift of `b` against `a` (a[i] ~ b[i + lag]) with the highest match. `offset`: where
    /// `a` starts in the full curve that `b` belongs to.
    private static func bestLag(_ a: [Float], _ b: [Float], lags: ClosedRange<Int>, offset: Int = 0) -> (lag: Int, score: Float) {
        var best = (lag: 0, score: -Float.infinity)
        let na = sqrt(vDSP.sumOfSquares(a))
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for lag in lags {
                    let start = max(0, -(lag + offset)), end = min(a.count, b.count - lag - offset)
                    guard end - start > 20 else { continue }
                    var dot: Float = 0
                    vDSP_dotpr(pa.baseAddress! + start, 1, pb.baseAddress! + start + lag + offset, 1, &dot, vDSP_Length(end - start))
                    var nb: Float = 0
                    vDSP_svesq(pb.baseAddress! + start + lag + offset, 1, &nb, vDSP_Length(end - start))
                    let score = nb > 0 && na > 0 ? dot / (na * sqrt(nb)) : 0
                    if score > best.score { best = (lag, score) }
                }
            }
        }
        return (best.lag, max(0, best.score))
    }
}
