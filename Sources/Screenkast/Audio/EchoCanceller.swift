import Foundation
import Accelerate
import AVFoundation

/// Removes the speaker echo from the microphone track, using the recorded system audio
/// as reference (MacBook speakers → built-in mic arrive ~30–40 ms late and sound like a chorus).
///
/// 1. Linear echo path: least-squares FIR (Wiener–Hopf, solved with Levinson recursion)
///    from system audio to mic, then subtracted.
/// 2. Residual echo suppression: per STFT bin, attenuate where the remaining signal is
///    mostly predicted echo (handles speaker non-linearity). Bins without echo stay untouched,
///    so speech recorded while the system is silent is unchanged.
enum EchoCanceller {
    static let sampleRate = 48_000.0
    static let filterLength = 4096         // 85 ms echo path
    static let preDelay = 480              // 10 ms: tolerate mic timestamps slightly ahead of the system track
    static let suppressionStrength: Float = 1.5
    static let suppressionFloor: Float = 0.12

    struct Stats: Codable, Equatable {
        var delayMs: Double
        var linearReductionDB: Double
        var totalReductionDB: Double
    }

    // MARK: Project level

    static let cleanFileName = "mic-clean.caf"
    static let statsFileName = "echo.json"

    static func cleanURL(for project: Project) -> URL { project.url.appendingPathComponent(cleanFileName) }

    static func loadStats(for project: Project) -> Stats? {
        guard let data = try? Data(contentsOf: project.url.appendingPathComponent(statsFileName)) else { return nil }
        return try? JSONDecoder().decode(Stats.self, from: data)
    }

    /// Reads mic + system audio of the project, cancels the echo and writes `mic-clean.caf`.
    static func process(project: Project, outputURL: URL? = nil) async throws -> Stats {
        let asset = AVURLAsset(url: project.videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let roles = await AudioRole.roles(of: tracks, fallback: project.info.audioRoles)
        guard let micIndex = roles.firstIndex(of: "mic"), let sysIndex = roles.firstIndex(of: "system") else {
            throw RecorderError.writerFailed("Mikrofon- und Systemspur werden benötigt")
        }
        let duration = try await asset.load(.duration).seconds
        let mic = try await readMono(track: tracks[micIndex], asset: asset, duration: duration)
        let sys = try await readMono(track: tracks[sysIndex], asset: asset, duration: duration)
        let (clean, stats) = cancel(mic: mic, reference: sys)
        let url = outputURL ?? cleanURL(for: project)
        // Write next to the target and move into place, so a half-written file is never used.
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).caf")
        try writeCAF(clean, to: temp)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
        if outputURL == nil {
            try JSONEncoder().encode(stats).write(to: project.url.appendingPathComponent(statsFileName), options: .atomic)
        }
        return stats
    }

    // MARK: Core algorithm

    static func cancel(mic y: [Float], reference xRaw: [Float]) -> ([Float], Stats) {
        let n = min(y.count, xRaw.count)
        let L = filterLength
        guard n > L * 4 else { return (y, Stats(delayMs: 0, linearReductionDB: 0, totalReductionDB: 0)) }
        let y = Array(y.prefix(n))
        // Reference advanced by `preDelay` (x[i] = ref[i + D]): the causal filter then covers
        // echo lags from −D to L − D, tolerating mic timestamps slightly ahead of the system track.
        var x = [Float](repeating: 0, count: n)
        x.withUnsafeMutableBufferPointer { dst in
            xRaw.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress! + preDelay, count: n - preDelay)
            }
        }

        // 1. Correlations for lags 0..<L, Wiener–Hopf solution.
        var rxx = crossCorrelation(x, x, lags: L)
        let ryx = crossCorrelation(x, y, lags: L)
        rxx[0] = rxx[0] * 1.001 + 1e-9
        guard let hD = solveSymmetricToeplitz(r: rxx, b: ryx) else {
            return (y, Stats(delayMs: 0, linearReductionDB: 0, totalReductionDB: 0))
        }
        let h = hD.map { Float($0) }
        var peak = 0
        for i in 1..<L where abs(h[i]) > abs(h[peak]) { peak = i }

        // 2. Linear echo estimate and subtraction.
        let echo = convolve(x, h, outputCount: n)
        var linear = [Float](repeating: 0, count: n)
        vDSP.subtract(y, echo, result: &linear)

        // 3. Residual echo suppression.
        let output = suppressResidual(signal: linear, echo: echo)

        // Stats over the parts where the system is playing.
        let active = activeMask(x, frame: 2400, thresholdDB: -45)
        let stats = Stats(delayMs: Double(peak - preDelay) / sampleRate * 1000,
                          linearReductionDB: reduction(y, linear, mask: active, frame: 2400),
                          totalReductionDB: reduction(y, output, mask: active, frame: 2400))
        return (output, stats)
    }

    /// R[j] = Σ a[i]·b[i+j] for j in 0..<lags (block FFT).
    static func crossCorrelation(_ a: [Float], _ b: [Float], lags: Int) -> [Double] {
        let N = 32768
        let B = N - lags
        let fft = RealFFT(count: N)
        var result = [Double](repeating: 0, count: lags)
        var aBlock = [Float](repeating: 0, count: N)
        var bBlock = [Float](repeating: 0, count: N)
        var out = [Float](repeating: 0, count: N)
        var A = SplitBuffer(count: N / 2), Bs = SplitBuffer(count: N / 2), P = SplitBuffer(count: N / 2)
        let scale = 1 / Float(4 * N)
        var start = 0
        while start < a.count {
            let aCount = min(B, a.count - start)
            let bCount = min(B + lags, b.count - start)
            fill(&aBlock, from: a, start: start, count: aCount)
            fill(&bBlock, from: b, start: start, count: max(0, bCount))
            fft.forward(aBlock, into: &A)
            fft.forward(bBlock, into: &Bs)
            SplitBuffer.multiply(A, Bs, conjugateFirst: true, into: &P)
            fft.inverse(P, into: &out)
            for j in 0..<lags { result[j] += Double(out[j] * scale) }
            start += B
        }
        return result
    }

    /// Linear convolution x * h (overlap-add), first `outputCount` samples.
    static func convolve(_ x: [Float], _ h: [Float], outputCount: Int) -> [Float] {
        let N = 16384
        let B = N - h.count + 1
        let fft = RealFFT(count: N)
        var hPadded = [Float](repeating: 0, count: N)
        fill(&hPadded, from: h, start: 0, count: h.count)
        var H = SplitBuffer(count: N / 2), X = SplitBuffer(count: N / 2), P = SplitBuffer(count: N / 2)
        fft.forward(hPadded, into: &H)
        var result = [Float](repeating: 0, count: outputCount + N)
        var block = [Float](repeating: 0, count: N)
        var out = [Float](repeating: 0, count: N)
        let scale = 1 / Float(4 * N)
        var start = 0
        while start < outputCount {
            fill(&block, from: x, start: start, count: min(B, x.count - start))
            fft.forward(block, into: &X)
            SplitBuffer.multiply(X, H, conjugateFirst: false, into: &P)
            fft.inverse(P, into: &out)
            result.withUnsafeMutableBufferPointer { r in
                out.withUnsafeBufferPointer { o in
                    vDSP_vsma(o.baseAddress!, 1, [scale], r.baseAddress! + start, 1, r.baseAddress! + start, 1, vDSP_Length(N))
                }
            }
            start += B
        }
        return Array(result.prefix(outputCount))
    }

    /// STFT gain: g = clamp(1 − β·|E|²/|S|², floor, 1).
    static func suppressResidual(signal: [Float], echo: [Float]) -> [Float] {
        let N = 1024, hop = 256
        let n = signal.count
        let fft = RealFFT(count: N)
        var window = [Float](repeating: 0, count: N)
        for i in 0..<N { window[i] = sqrt(0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(N))) }   // sqrt periodic Hann
        var output = [Float](repeating: 0, count: n + 2 * N)
        var sFrame = [Float](repeating: 0, count: N), eFrame = [Float](repeating: 0, count: N)
        var S = SplitBuffer(count: N / 2), E = SplitBuffer(count: N / 2)
        var out = [Float](repeating: 0, count: N)
        let beta = suppressionStrength, floor = suppressionFloor
        // Hann² overlap at hop N/4 sums to 2; inverse FFT adds 2N (forward ×2, inverse ×N).
        let scale = 1 / (2 * Float(2 * N))
        var pos = -N   // frames start before 0 so the first samples get full overlap
        while pos < n {
            for i in 0..<N {
                let j = pos + i
                let inRange = j >= 0 && j < n
                sFrame[i] = inRange ? signal[j] * window[i] : 0
                eFrame[i] = inRange ? echo[j] * window[i] : 0
            }
            fft.forward(sFrame, into: &S)
            fft.forward(eFrame, into: &E)
            func gain(_ s2: Float, _ e2: Float) -> Float { min(1, max(floor, 1 - beta * e2 / (s2 + 1e-12))) }
            // Packed bin 0: real = DC, imag = Nyquist.
            S.re[0] *= gain(S.re[0] * S.re[0], E.re[0] * E.re[0])
            S.im[0] *= gain(S.im[0] * S.im[0], E.im[0] * E.im[0])
            for k in 1..<(N / 2) {
                let g = gain(S.re[k] * S.re[k] + S.im[k] * S.im[k], E.re[k] * E.re[k] + E.im[k] * E.im[k])
                S.re[k] *= g
                S.im[k] *= g
            }
            fft.inverse(S, into: &out)
            for i in 0..<N {
                let j = pos + i + N
                if j >= 0 && j < output.count { output[j] += out[i] * window[i] * scale }
            }
            pos += hop
        }
        return Array(output[N..<(N + n)])
    }

    /// Solves T·x = b for symmetric Toeplitz T with first column r (Levinson recursion, O(n²)).
    static func solveSymmetricToeplitz(r: [Double], b: [Double]) -> [Double]? {
        let n = r.count
        guard n > 0, r[0] != 0, b.count == n else { return nil }
        var f = [Double](repeating: 0, count: n)
        var x = [Double](repeating: 0, count: n)
        var newF = [Double](repeating: 0, count: n)
        f[0] = 1 / r[0]
        x[0] = b[0] / r[0]
        for k in 1..<n {
            var ef = 0.0
            for i in 0..<k { ef += r[k - i] * f[i] }
            let denom = 1 - ef * ef
            guard abs(denom) > 1e-12 else { return nil }
            for i in 0...k {
                let fwd = i < k ? f[i] : 0
                let bwd = i > 0 ? f[k - i] : 0
                newF[i] = (fwd - ef * bwd) / denom
            }
            for i in 0...k { f[i] = newF[i] }
            var ex = 0.0
            for i in 0..<k { ex += r[k - i] * x[i] }
            let c = b[k] - ex
            for i in 0...k { x[i] += c * f[k - i] }
        }
        return x
    }

    // MARK: Helpers

    private static func fill(_ dst: inout [Float], from src: [Float], start: Int, count: Int) {
        let c = max(0, min(count, src.count - start, dst.count))
        dst.withUnsafeMutableBufferPointer { d in
            if c > 0 {
                src.withUnsafeBufferPointer { s in d.baseAddress!.update(from: s.baseAddress! + start, count: c) }
            }
            if c < d.count { (d.baseAddress! + c).update(repeating: 0, count: d.count - c) }
        }
    }

    private static func activeMask(_ x: [Float], frame: Int, thresholdDB: Float) -> [Bool] {
        stride(from: 0, to: x.count, by: frame).map { s in
            let e = min(x.count, s + frame)
            let rms = vDSP.rootMeanSquare(x[s..<e])
            return 20 * log10(max(rms, 1e-9)) > thresholdDB
        }
    }

    private static func reduction(_ before: [Float], _ after: [Float], mask: [Bool], frame: Int) -> Double {
        var eb = 0.0, ea = 0.0
        for (i, on) in mask.enumerated() where on {
            let s = i * frame, e = min(before.count, s + frame)
            eb += Double(vDSP.sumOfSquares(before[s..<e]))
            ea += Double(vDSP.sumOfSquares(after[s..<e]))
        }
        guard eb > 0, ea > 0 else { return 0 }
        return 10 * log10(eb / ea)
    }

    /// One audio track as mono 48 kHz floats, placed on the asset timeline (index = time × rate).
    static func readMono(track: AVAssetTrack, asset: AVAsset, duration: Double) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecorderError.writerFailed("Audio lesen") }
        var samples = [Float](repeating: 0, count: Int(duration * sampleRate) + 1)
        while let sb = output.copyNextSampleBuffer() {
            guard let block = sb.dataBuffer else { continue }
            let start = Int((sb.presentationTimeStamp.seconds * sampleRate).rounded())
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            let from = max(0, -start), to = min(chunk.count, samples.count - start)
            if to > from {
                samples.withUnsafeMutableBufferPointer { d in
                    chunk.withUnsafeBufferPointer { c in (d.baseAddress! + start + from).update(from: c.baseAddress! + from, count: to - from) }
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? RecorderError.writerFailed("Audio lesen") }
        return samples
    }

    /// 16-bit PCM CAF (no encoder delay, exact alignment with the screen timeline).
    static func writeCAF(_ samples: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 65536
        var start = 0
        while start < samples.count {
            let count = min(chunk, samples.count - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { s in
                buffer.floatChannelData![0].update(from: s.baseAddress! + start, count: count)
            }
            try file.write(from: buffer)
            start += count
        }
    }
}

// MARK: - Real FFT (vDSP zrip; forward result is 2×DFT, packed DC/Nyquist in bin 0)

struct SplitBuffer {
    var re: [Float]
    var im: [Float]
    init(count: Int) {
        re = [Float](repeating: 0, count: count)
        im = [Float](repeating: 0, count: count)
    }

    /// P = A·B or conj(A)·B, including the packed DC/Nyquist bin.
    static func multiply(_ a: SplitBuffer, _ b: SplitBuffer, conjugateFirst: Bool, into p: inout SplitBuffer) {
        let n = a.re.count
        let dc = a.re[0] * b.re[0], ny = a.im[0] * b.im[0]
        let sign: Float = conjugateFirst ? -1 : 1
        for k in 0..<n {
            let ar = a.re[k], ai = a.im[k] * sign, br = b.re[k], bi = b.im[k]
            p.re[k] = ar * br - ai * bi
            p.im[k] = ar * bi + ai * br
        }
        p.re[0] = dc
        p.im[0] = ny
    }
}

final class RealFFT {
    let count: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init(count: Int) {
        self.count = count
        log2n = vDSP_Length(log2(Double(count)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func forward(_ input: [Float], into out: inout SplitBuffer) {
        out.re.withUnsafeMutableBufferPointer { re in
            out.im.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                input.withUnsafeBufferPointer { inp in
                    inp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: count / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(count / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
    }

    /// Inverse; the result is scaled by 2·count relative to the original signal (for 2×DFT input).
    func inverse(_ spectrum: SplitBuffer, into output: inout [Float]) {
        var s = spectrum
        s.re.withUnsafeMutableBufferPointer { re in
            s.im.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                output.withUnsafeMutableBufferPointer { o in
                    o.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: count / 2) {
                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(count / 2))
                    }
                }
            }
        }
    }
}
