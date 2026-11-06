import Foundation

/// Checks for the echo canceller (run as part of `--selftest`).
enum EchoSelfTest {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() throws {
        var rng = SystemRandomNumberGenerator()
        func noise(_ n: Int) -> [Float] { (0..<n).map { _ in Float.random(in: -1...1, using: &rng) } }

        // 1. FFT helpers against direct computation.
        let a = noise(50_000), b = noise(50_000)
        let lags = 64
        let fast = EchoCanceller.crossCorrelation(a, b, lags: lags)
        for j in [0, 1, 17, 63] {
            var direct = 0.0
            for i in 0..<(a.count - j) { direct += Double(a[i]) * Double(b[i + j]) }
            if abs(fast[j] - direct) > 1e-3 * max(1, abs(direct)) + 0.5 {
                throw Failure(description: "crossCorrelation lag \(j): \(fast[j]) vs \(direct)")
            }
        }
        let h: [Float] = (0..<300).map { i in i == 0 ? 1 : Float(exp(-Double(i) / 40) * 0.3 * sin(Double(i))) }
        let conv = EchoCanceller.convolve(a, h, outputCount: 40_000)
        for i in [0, 5, 299, 12_345, 39_999] {
            var direct: Float = 0
            for k in 0..<h.count where i - k >= 0 { direct += h[k] * a[i - k] }
            if abs(conv[i] - direct) > 1e-3 { throw Failure(description: "convolve[\(i)]: \(conv[i]) vs \(direct)") }
        }
        let T: [Double] = [4, 1, 0.5, 0.25]
        let rhs: [Double] = [1, 2, 3, 4]
        guard let sol = EchoCanceller.solveSymmetricToeplitz(r: T, b: rhs) else { throw Failure(description: "Toeplitz nil") }
        for i in 0..<4 {
            var s = 0.0
            for j in 0..<4 { s += T[abs(i - j)] * sol[j] }
            if abs(s - rhs[i]) > 1e-9 { throw Failure(description: "Toeplitz row \(i): \(s) vs \(rhs[i])") }
        }
        print("✓ FFT correlation/convolution and Toeplitz solver match direct computation")

        // 2. Synthetic room: system audio 0–6 s, own voice 6–9 s, both 9–10 s.
        let sr = 48_000, n = 10 * sr
        func bursts(_ n: Int, from: Int, to: Int, seed: Float) -> [Float] {
            var s = [Float](repeating: 0, count: n)
            var lp: Float = 0
            for i in from..<min(to, n) {
                lp = 0.85 * lp + 0.15 * Float.random(in: -1...1, using: &rng)
                let env = 0.5 + 0.5 * sin(Float(i) / Float(sr) * seed)   // syllable-like envelope
                s[i] = lp * env * 2
            }
            return s
        }
        let system = bursts(n, from: 0, to: 6 * sr, seed: 17).enumerated().map { $0.offset >= 9 * sr ? 0 : $0.element }
            .enumerated().map { i, v in i >= 9 * sr ? bursts(1, from: 0, to: 1, seed: 3)[0] : v }
        var sys = system
        let extra = bursts(n, from: 9 * sr, to: 10 * sr, seed: 11)
        for i in (9 * sr)..<n { sys[i] = extra[i] }
        let voice = bursts(n, from: 6 * sr, to: 10 * sr, seed: 9)
        // Echo path: 30 ms delay, small reverb tail, mild speaker non-linearity.
        var room = [Float](repeating: 0, count: 2400)
        room[1440] = 0.35
        for i in 1441..<2400 { room[i] = Float(exp(-Double(i - 1440) / 150)) * 0.05 * Float.random(in: -1...1, using: &rng) }
        let echo = EchoCanceller.convolve(sys.map { tanh(1.3 * $0) / 1.3 }, room, outputCount: n)
        let mic = (0..<n).map { voice[$0] * 0.5 + echo[$0] }

        let (clean, stats) = EchoCanceller.cancel(mic: mic, reference: sys)
        func energy(_ s: [Float], _ a: Int, _ b: Int) -> Double { s[a..<b].reduce(0) { $0 + Double($1 * $1) } }
        let erle = 10 * log10(energy(mic, sr, 6 * sr) / energy(clean, sr, 6 * sr))
        let voiceChange = 10 * log10(energy(clean, 6 * sr + 4800, 9 * sr) / energy(mic, 6 * sr + 4800, 9 * sr))
        print(String(format: "✓ synthetic echo: delay %.1f ms, echo reduced %.1f dB, own voice changed %+.2f dB", stats.delayMs, erle, voiceChange))
        guard abs(stats.delayMs - 30) < 1.5 else { throw Failure(description: "delay \(stats.delayMs) ms") }
        guard erle > 18 else { throw Failure(description: "echo reduction only \(erle) dB") }
        guard abs(voiceChange) < 0.5 else { throw Failure(description: "voice changed by \(voiceChange) dB") }
    }
}
