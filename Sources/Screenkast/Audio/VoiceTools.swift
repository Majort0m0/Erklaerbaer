import Foundation
import AVFoundation
import Accelerate

// MARK: - Pauses

/// Finds pauses in speech from a peak envelope (`Waveform`, 100 values per second).
enum PauseDetector {
    struct Options: Equatable {
        /// Shortest pause that is shortened.
        var minPause: Double = 0.8
        /// How much of each pause stays (split before and after).
        var keep: Double = 0.3
        /// 0 … 1: higher counts more as silence.
        var sensitivity: Double = 0.5
    }

    /// Level below which a 10 ms bucket counts as silence: between the noise floor and the speech
    /// level, in decibels.
    static func threshold(_ peaks: [Float], sensitivity: Double) -> Float {
        let sorted = peaks.filter { $0 > 0 }.sorted()
        guard sorted.count > 20 else { return 0.01 }
        func db(_ v: Float) -> Double { 20 * log10(Double(max(v, 1e-5))) }
        let floor = db(sorted[Int(Double(sorted.count - 1) * 0.1)])
        let loud = db(sorted[Int(Double(sorted.count - 1) * 0.95)])
        let t = floor + max(4, (loud - floor) * (0.1 + 0.3 * min(1, max(0, sensitivity))))
        return Float(pow(10, t / 20))
    }

    /// Stretches of silence at least `minPause` long, each shortened by `keep / 2` at both ends
    /// (seconds of the envelope's timeline).
    static func silences(_ peaks: [Float], minLength: Double, threshold: Float) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        var runStart: Int?
        for i in 0...peaks.count {
            let silent = i < peaks.count && peaks[i] < threshold
            if silent, runStart == nil { runStart = i }
            if !silent, let s = runStart {
                if Double(i - s) / Waveform.rate >= minLength { result.append(Double(s) / Waveform.rate...Double(i) / Waveform.rate) }
                runStart = nil
            }
        }
        return result
    }

    /// Pauses to cut out.
    static func pauses(_ peaks: [Float], options: Options) -> [ClosedRange<Double>] {
        let t = threshold(peaks, sensitivity: options.sensitivity)
        let half = options.keep / 2
        return silences(peaks, minLength: max(options.minPause, options.keep + 0.1), threshold: t).compactMap { r in
            let a = r.lowerBound + half, b = r.upperBound - half
            return b - a > 0.05 ? a...b : nil
        }
    }

    /// Where someone speaks (gaps shorter than 0.4 s bridged), for ducking music.
    static func speech(_ peaks: [Float], duration: Double) -> [ClosedRange<Double>] {
        let t = threshold(peaks, sensitivity: 0.4)
        var speech: [ClosedRange<Double>] = []
        var cursor = 0.0
        for s in silences(peaks, minLength: 0.4, threshold: t) {
            if s.lowerBound > cursor + 0.05 { speech.append(cursor...s.lowerBound) }
            cursor = s.upperBound
        }
        if duration > cursor + 0.05 { speech.append(cursor...duration) }
        return speech
    }
}

// MARK: - Voice enhancement

/// High-pass, spectral noise reduction, loudness normalization (ITU-R BS.1770) and a soft limiter.
enum VoiceProcessor {
    struct Result: Codable, Equatable {
        var loudnessBefore: Double
        var loudnessAfter: Double
        /// How much quieter the background noise got (dB).
        var noiseReductionDB: Double
        /// Breath sounds found and made quieter (nil: not looked for).
        var breaths: Int? = nil
    }

    static let sampleRate = EchoCanceller.sampleRate

    static func enhance(_ input: [Float], settings: VoiceEnhancement) -> ([Float], Result) {
        let (wet, _, result) = enhanceWithDry(input, settings: settings)
        return (wet, result)
    }

    /// The enhanced track and a "dry" one with the same loudness but without noise reduction.
    /// The editor mixes both: how strong the enhancement is can change live, also per region.
    static func enhanceWithDry(_ input: [Float], settings: VoiceEnhancement) -> (wet: [Float], dry: [Float], result: Result) {
        var x = input
        let before = loudness(x)
        let speech = hasSpeech(input)
        highPass(&x, cutoff: 80)
        var dry = x
        let noiseBefore = noiseLevel(x)
        if settings.noiseReduction > 0.01 { x = denoise(x, strength: Float(settings.noiseReduction)) }
        let noiseAfter = noiseLevel(x)
        // Only a track with speech is brought to the target: a microphone that recorded nothing
        // but room noise (narration came as a voice-over) must not be amplified.
        if settings.normalize, speech {
            let current = loudness(x)
            if current.isFinite, current > -70 {
                let gain = min(Float(pow(10, (settings.targetLUFS - current) / 20)), 30)
                vDSP.multiply(gain, x, result: &x)
                vDSP.multiply(gain, dry, result: &dry)
            }
        }
        limit(&x, ceiling: 0.89)   // −1 dBFS
        limit(&dry, ceiling: 0.89)
        let after = loudness(x)
        return (x, dry, Result(loudnessBefore: before, loudnessAfter: after,
                               noiseReductionDB: noiseBefore > 0 && noiseAfter > 0 ? 20 * log10(Double(noiseBefore / noiseAfter)) : 0))
    }

    // MARK: Breaths

    /// Breath sounds: noise-like (no pitch), clearly quieter than the speech, not as bright as
    /// "s"/"sch", 0.13–1.2 s long (shorter ones only at high sensitivity). The threshold follows the speaker's own level: `sensitivity`
    /// 0 finds only quiet breaths, 1 also loud ones. Times in seconds.
    static func breaths(_ x: [Float], sensitivity: Double) -> [ClosedRange<Double>] {
        let hop = Int(0.01 * sampleRate), size = Int(0.03 * sampleRate)
        guard x.count > size * 10 else { return [] }
        let frames = (x.count - size) / hop + 1
        var level = [Double](repeating: -120, count: frames)
        var zcr = [Double](repeating: 0, count: frames)
        var voiced = [Double](repeating: 0, count: frames)
        // Pitch check on an 8 kHz copy (averaging six samples is low-pass enough for voice pitch).
        let k = 6
        var low = [Float](repeating: 0, count: x.count / k)
        for i in low.indices { var s: Float = 0; for j in 0..<k { s += x[i * k + j] }; low[i] = s / Float(k) }
        let lowSize = size / k, minLag = 8_000 / 400, maxLag = 8_000 / 70
        for f in 0..<frames {
            let a = f * hop
            let slice = x[a..<(a + size)]
            level[f] = 10 * log10(max(1e-12, Double(vDSP.meanSquare(slice))))
            var crossings = 0
            for i in (a + 1)..<(a + size) where (x[i - 1] < 0) != (x[i] < 0) { crossings += 1 }
            zcr[f] = Double(crossings) / Double(size)
            let la = a / k
            guard la + lowSize + maxLag < low.count else { continue }
            var e0: Float = 0
            for i in 0..<lowSize { e0 += low[la + i] * low[la + i] }
            guard e0 > 1e-9 else { continue }
            var best: Float = 0
            for lag in minLag...maxLag {
                var c: Float = 0, e1: Float = 0
                for i in 0..<lowSize { c += low[la + i] * low[la + i + lag]; e1 += low[la + i + lag] * low[la + i + lag] }
                if e1 > 1e-9 { best = max(best, c / (e0 * e1).squareRoot()) }
            }
            voiced[f] = Double(best)
        }
        let sorted = level.sorted()
        let floor = sorted[sorted.count / 10]
        let active = sorted.filter { $0 > floor + 10 }
        guard active.count > 20 else { return [] }
        let speech = active[Int(Double(active.count - 1) * 0.9)]
        // Breaths lie this far below the loud speech frames at most.
        let margin = 18 - 10 * min(1, max(0, sensitivity))
        var candidate = [Bool](repeating: false, count: frames)
        for f in 0..<frames {
            candidate[f] = voiced[f] < 0.45 && zcr[f] < 0.32 && level[f] > floor + 4 && level[f] < speech - margin
        }
        // Runs of candidate frames (gaps up to 50 ms closed) of a breath's length.
        var ranges: [ClosedRange<Double>] = []
        var f = 0
        while f < frames {
            guard candidate[f] else { f += 1; continue }
            var end = f
            var g = f
            while g < frames {
                if candidate[g] { end = g; g += 1; continue }
                var gap = g
                while gap < frames, !candidate[gap], gap - end <= 5 { gap += 1 }
                if gap < frames, candidate[gap], gap - end <= 5 { g = gap } else { break }
            }
            let start = Double(f * hop) / sampleRate, stop = Double(end * hop + size) / sampleRate
            // Unvoiced sounds inside words ("ch", "f") are shorter than a breath.
            let minLength = 0.25 - 0.12 * min(1, max(0, sensitivity))
            if stop - start >= minLength, stop - start <= 1.2 { ranges.append(start...stop) }
            f = end + 1
        }
        return ranges
    }

    /// Lowers `ranges` by `db` with 20 ms fades inside their edges.
    static func reduce(_ x: inout [Float], ranges: [ClosedRange<Double>], byDB db: Double) {
        let g = Float(pow(10, -db / 20))
        let fade = Int(0.02 * sampleRate)
        for r in ranges {
            let a = max(0, Int(r.lowerBound * sampleRate)), b = min(x.count, Int(r.upperBound * sampleRate))
            guard b - a > 2 * fade else { continue }
            for i in a..<b {
                let edge = min(i - a, b - 1 - i)
                let w = edge >= fade ? g : 1 - (1 - g) * Float(edge) / Float(fade)
                x[i] *= w
            }
        }
    }

    // MARK: Filters

    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        func run(_ x: inout [Float]) {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in x.indices {
                let v = Double(x[i])
                let y = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = v; y2 = y1; y1 = y
                x[i] = Float(y)
            }
        }
    }

    /// Second-order Butterworth high-pass (rumble, desk knocks).
    static func highPass(_ x: inout [Float], cutoff: Double) {
        let w = 2 * Double.pi * cutoff / sampleRate
        let q = 1 / sqrt(2.0)
        let alpha = sin(w) / (2 * q), cw = cos(w), a0 = 1 + alpha
        Biquad(b0: (1 + cw) / 2 / a0, b1: -(1 + cw) / a0, b2: (1 + cw) / 2 / a0, a1: -2 * cw / a0, a2: (1 - alpha) / a0).run(&x)
    }

    /// Integrated loudness in LUFS (K-weighting, 400 ms blocks with 75 % overlap, absolute and
    /// relative gating). Coefficients for 48 kHz.
    static func loudness(_ input: [Float]) -> Double {
        var x = input
        Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
               a1: -1.69065929318241, a2: 0.73248077421585).run(&x)
        Biquad(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621).run(&x)
        let block = Int(0.4 * sampleRate), step = Int(0.1 * sampleRate)
        guard x.count >= block else { return -.infinity }
        var powers: [Double] = []
        var start = 0
        while start + block <= x.count {
            powers.append(Double(vDSP.meanSquare(x[start..<(start + block)])))
            start += step
        }
        func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(max(z, 1e-12)) }
        let absolute = powers.filter { lufs($0) > -70 }
        guard !absolute.isEmpty else { return -.infinity }
        let relativeGate = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lufs($0) > relativeGate }
        guard !gated.isEmpty else { return -.infinity }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    /// Speech: at least a fifth of the 50 ms frames lie 10 dB above the noise floor. Room noise
    /// stays near the floor, typing makes only short spikes.
    static func hasSpeech(_ x: [Float]) -> Bool {
        let frame = Int(0.05 * sampleRate)
        guard x.count > frame * 20 else { return false }
        var levels: [Float] = []
        var s = 0
        while s + frame <= x.count {
            levels.append(vDSP.rootMeanSquare(x[s..<(s + frame)]))
            s += frame
        }
        levels.sort()
        let noise = max(levels[levels.count / 10], 1e-7)
        let loud = levels.filter { $0 > noise * 3.16 }.count
        return Double(loud) / Double(levels.count) >= 0.2
    }

    /// RMS of the quietest 10 % of 50 ms frames (background noise).
    static func noiseLevel(_ x: [Float]) -> Float {
        let frame = Int(0.05 * sampleRate)
        guard x.count > frame * 10 else { return 0 }
        var levels: [Float] = []
        var s = 0
        while s + frame <= x.count {
            levels.append(vDSP.rootMeanSquare(x[s..<(s + frame)]))
            s += frame
        }
        levels.sort()
        let quiet = levels.prefix(max(1, levels.count / 10))
        return quiet.reduce(0, +) / Float(quiet.count)
    }

    /// Spectral subtraction: the noise spectrum (quiet percentile per frequency) is taken off
    /// every frame, with a floor and smoothing over time against "musical noise".
    static func denoise(_ input: [Float], strength: Float) -> [Float] {
        let n = 1024, hop = 256, bins = n / 2
        guard input.count > n * 4 else { return input }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let frames = (input.count - n) / hop + 1
        let fft = RealFFT(count: n)
        var spectra = [SplitBuffer](repeating: SplitBuffer(count: bins), count: frames)
        var magnitudes = [[Float]](repeating: [Float](repeating: 0, count: bins), count: frames)
        var frame = [Float](repeating: 0, count: n)
        for f in 0..<frames {
            input.withUnsafeBufferPointer { src in
                frame.withUnsafeMutableBufferPointer { dst in
                    vDSP_vmul(src.baseAddress! + f * hop, 1, window, 1, dst.baseAddress!, 1, vDSP_Length(n))
                }
            }
            fft.forward(frame, into: &spectra[f])
            let s = spectra[f]
            for k in 1..<bins { magnitudes[f][k] = (s.re[k] * s.re[k] + s.im[k] * s.im[k]).squareRoot() }
            magnitudes[f][0] = abs(s.re[0])
        }
        // Noise profile: 15th percentile of each bin over time. Noise magnitudes are Rayleigh
        // distributed; their RMS is about 2.5 × this percentile.
        var noise = [Float](repeating: 0, count: bins)
        var column = [Float](repeating: 0, count: frames)
        for k in 0..<bins {
            for f in 0..<frames { column[f] = magnitudes[f][k] }
            column.sort()
            noise[k] = 2.48 * column[Int(Double(frames - 1) * 0.15)]
        }
        // Gentle: less over-subtraction and a higher floor keep the voice natural (no "underwater" sound).
        let over = 1 + 1.0 * strength
        let floorGain = pow(10, -(4 + 12 * strength) / 20)
        var previous = [Float](repeating: 1, count: bins)
        var output = [Float](repeating: 0, count: input.count)
        var block = [Float](repeating: 0, count: n)
        for f in 0..<frames {
            var gains = [Float](repeating: 1, count: bins)
            for k in 0..<bins {
                let m = max(magnitudes[f][k], 1e-9)
                let ratio = noise[k] / m
                let g = max(floorGain, (max(0, 1 - over * ratio * ratio)).squareRoot())
                // Gains rise at once but fall gently (less flutter in the remaining noise).
                gains[k] = max(g, previous[k] * 0.55)
            }
            // Smooth across neighbouring frequencies.
            var smoothed = gains
            for k in 1..<(bins - 1) { smoothed[k] = (gains[k - 1] + 2 * gains[k] + gains[k + 1]) / 4 }
            previous = smoothed
            var s = spectra[f]
            s.re[0] *= smoothed[0]
            s.im[0] *= smoothed[bins - 1]
            for k in 1..<bins { s.re[k] *= smoothed[k]; s.im[k] *= smoothed[k] }
            fft.inverse(s, into: &block)
            // Inverse is scaled by 2n; Hann² windows at 75 % overlap sum to 1.5.
            let scale = 1 / (Float(2 * n) * 1.5)
            for i in 0..<n { output[f * hop + i] += block[i] * window[i] * scale }
        }
        return output
    }

    /// Soft limiter: transparent below 70 % of the ceiling, smoothly saturating above.
    static func limit(_ x: inout [Float], ceiling c: Float) {
        let knee = 0.7 * c, range = c - knee
        for i in x.indices {
            let a = abs(x[i])
            guard a > knee else { continue }
            let y = knee + range * (1 - exp(-(a - knee) / range))
            x[i] = x[i] < 0 ? -y : y
        }
    }

    // MARK: Files

    /// Processed microphone track (made from the echo-free one when echo removal is on).
    static func micURL(for project: Project, settings: EditSettings) -> URL {
        let echo = settings.removeEcho && FileManager.default.fileExists(atPath: EchoCanceller.cleanURL(for: project).path)
        return project.url.appendingPathComponent("mic-voice-\(settings.voice.key)\(echo ? "-e" : "").caf")
    }

    /// The same loudness without noise reduction (mixed with the enhanced one).
    static func micDryURL(for project: Project, settings: EditSettings) -> URL {
        let wet = micURL(for: project, settings: settings)
        return wet.deletingPathExtension().appendingPathExtension("dry.caf")
    }

    /// Processed voice-over file next to the original.
    static func voiceOverURL(for project: Project, file: String, settings: EditSettings) -> URL {
        let original = project.url.appendingPathComponent(file)
        return original.deletingPathExtension().appendingPathExtension("voice-\(settings.voice.key).caf")
    }

    /// Processes the microphone and all voice-over files that have no processed copy yet.
    static func process(project: Project, settings: EditSettings) async throws -> Result? {
        var result: Result?
        if project.info.hasMicAudio {
            let target = micURL(for: project, settings: settings)
            let dryTarget = micDryURL(for: project, settings: settings)
            if !FileManager.default.fileExists(atPath: target.path) || !FileManager.default.fileExists(atPath: dryTarget.path) {
                let samples: [Float]
                let clean = EchoCanceller.cleanURL(for: project)
                if target.lastPathComponent.hasSuffix("-e.caf") {
                    samples = try await readFile(clean)
                } else {
                    let asset = AVURLAsset(url: project.videoURL)
                    let tracks = try await asset.loadTracks(withMediaType: .audio)
                    let roles = await AudioRole.roles(of: tracks, fallback: project.info.audioRoles)
                    guard let i = roles.firstIndex(of: "mic") else { return nil }
                    samples = try await EchoCanceller.readMono(track: tracks[i], asset: asset, duration: try await asset.load(.duration).seconds)
                }
                let (out, dry, r) = enhanceWithDry(samples, settings: settings.voice)
                try write(out, to: target)
                try write(dry, to: dryTarget)
                result = r
                try? JSONEncoder().encode(r).write(to: target.appendingPathExtension("json"))
            } else {
                result = (try? Data(contentsOf: target.appendingPathExtension("json"))).flatMap { try? JSONDecoder().decode(Result.self, from: $0) }
            }
        }
        for file in Set(settings.voiceOvers.map(\.file)) {
            let target = voiceOverURL(for: project, file: file, settings: settings)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            let samples = try await readFile(project.url.appendingPathComponent(file))
            let (out, r) = enhance(samples, settings: settings.voice)
            try write(out, to: target)
            if result == nil { result = r }
        }
        return result
    }

    static func readFile(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        return try await EchoCanceller.readMono(track: track, asset: asset, duration: try await asset.load(.duration).seconds)
    }

    /// Writes next to the target and moves into place, so a half-written file is never used.
    static func write(_ samples: [Float], to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).caf")
        try EchoCanceller.writeCAF(samples, to: temp)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }
}
