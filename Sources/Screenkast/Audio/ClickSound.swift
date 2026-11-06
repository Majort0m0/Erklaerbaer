import Foundation

/// Synthesized mouse-click sound (own sound, no third-party assets).
enum ClickSound {
    static let fileName = "click.caf"
    static let length = 0.06   // seconds

    static func url(for project: Project) -> URL { project.url.appendingPathComponent(fileName) }

    /// Writes the click sample into the project once.
    static func ensureFile(for project: Project) throws -> URL {
        let url = url(for: project)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try EchoCanceller.writeCAF(samples(), to: url)
        return url
    }

    static func samples(sampleRate: Double = 48_000) -> [Float] {
        let n = Int(length * sampleRate)
        var out = [Float](repeating: 0, count: n)
        var rng = SplitMix(seed: 42)
        var hp: Float = 0, last: Float = 0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            // Bright noise transient (1-pole high-pass) + two short resonances.
            let white = rng.nextFloat() * 2 - 1
            hp = 0.6 * (hp + white - last)
            last = white
            let noise = hp * Float(exp(-t / 0.0025)) * 0.55
            let body = Float(sin(2 * .pi * 1900 * t) * exp(-t / 0.007)) * 0.45
            let tick = Float(sin(2 * .pi * 3600 * t) * exp(-t / 0.0025)) * 0.3
            let attack = Float(min(1, t / 0.0004))   // no hard edge at the start
            out[i] = (noise + body + tick) * attack * 0.8
        }
        return out
    }

    /// Deterministic noise so every build writes the same file.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func nextFloat() -> Float { Float(next() >> 40) / Float(1 << 24) }
    }
}


/// A soft "whoosh" (filtered noise sweep) for zooms and transitions.
enum WhooshSound {
    static let fileName = "whoosh.caf"
    static let length = 0.45

    static func ensureFile(for project: Project) throws -> URL {
        let url = project.url.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try EchoCanceller.writeCAF(samples(), to: url)
        return url
    }

    static func samples(sampleRate: Double = 48_000) -> [Float] {
        let n = Int(length * sampleRate)
        var out = [Float](repeating: 0, count: n)
        var rng = ClickSound.SplitMix(seed: 7)
        var low: Float = 0, band: Float = 0
        for i in 0..<n {
            let p = Double(i) / Double(n)
            // State-variable band-pass sweeping from 400 Hz to 3.5 kHz, rising then falling.
            let f = 400 + 3_100 * sin(p * .pi / 2)
            let k = Float(2 * sin(.pi * f / sampleRate))
            let white = rng.nextFloat() * 2 - 1
            low += k * band
            let high = white - low - 0.7 * band
            band += k * high
            let envelope = Float(sin(p * .pi) * sin(p * .pi))   // smooth in and out
            out[i] = band * envelope * 0.5
        }
        return out
    }
}
