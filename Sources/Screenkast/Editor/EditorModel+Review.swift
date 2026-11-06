import Foundation
import AVFoundation

// MARK: - Breath sounds as ranges, automatic edits to review

extension EditorModel {
    /// Turns breath reduction on or off: on, the breaths of the microphone become ranges with
    /// their own (lower) volume in the microphone lane, each one reviewable.
    func setBreaths(_ on: Bool) async {
        settings.voice.breaths = on
        if on { await detectBreathRegions() } else { removeBreathRegions() }
    }

    func setBreathSensitivity(_ value: Double) {
        settings.voice.breathSensitivity = value
        breathTask?.cancel()
        breathTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.detectBreathRegions()
        }
    }

    /// How much quieter breaths become (all breath ranges follow).
    func setBreathReduction(_ db: Double) {
        settings.voice.breathReductionDB = db
        let gain = pow(10, -db / 20)
        for i in settings.audioMutes.indices where settings.audioMutes[i].kind == .breath {
            settings.audioMutes[i].gain = gain
        }
    }

    var breathRegions: [AudioMute] { settings.audioMutes.filter { $0.kind == .breath } }

    func removeBreathRegions() {
        commitUndoStep(); defer { commitUndoStep() }
        settings.audioMutes.removeAll { $0.kind == .breath }
    }

    /// Finds breaths in the microphone (the enhanced track when there is one) and replaces the
    /// breath ranges.
    func detectBreathRegions() async {
        guard project.info.hasMicAudio else { return }
        breathState = "Atemgeräusche werden gesucht …"
        let project = self.project, s = settings
        let found: [ClosedRange<Double>] = await Task.detached(priority: .userInitiated) {
            let wet = VoiceProcessor.micURL(for: project, settings: s)
            let clean = EchoCanceller.cleanURL(for: project)
            var x: [Float]?
            if FileManager.default.fileExists(atPath: wet.path) {
                x = try? await VoiceProcessor.readFile(wet)
            } else if s.removeEcho, FileManager.default.fileExists(atPath: clean.path) {
                x = try? await VoiceProcessor.readFile(clean)
            } else if let asset = Optional(AVURLAsset(url: project.videoURL)),
                      let tracks = try? await asset.loadTracks(withMediaType: .audio) {
                let roles = await AudioRole.roles(of: tracks, fallback: project.info.audioRoles)
                if let i = roles.firstIndex(of: "mic"), let d = try? await asset.load(.duration).seconds {
                    x = try? await EchoCanceller.readMono(track: tracks[i], asset: asset, duration: d)
                }
            }
            guard var samples = x else { return [] }
            VoiceProcessor.highPass(&samples, cutoff: 80)
            return VoiceProcessor.breaths(samples, sensitivity: s.voice.breathLevel)
        }.value
        guard settings.voice.reducesBreaths else { breathState = nil; return }
        let kept = Self.outsideWords(found, words: settings.words)
        commitUndoStep(); defer { commitUndoStep() }
        settings.audioMutes.removeAll { $0.kind == .breath }
        let gain = pow(10, -settings.voice.breathDB / 20)
        for r in kept {
            var m = AudioMute(lane: .mic, start: r.lowerBound, end: r.upperBound)
            m.gain = gain
            m.kind = .breath
            settings.audioMutes.append(m)
        }
        breathState = kept.isEmpty ? "Keine Atemgeräusche gefunden." : "\(kept.count) Atemgeräusche gedämpft – in der Mikrofonspur als „Atem“ zu sehen."
    }

    /// Breath ranges without the recognized words: "s", "f" or "ch" inside a word can sound like a
    /// breath. Each range keeps its longest part outside the words' cores (when ≥ 0.15 s).
    static func outsideWords(_ ranges: [ClosedRange<Double>], words: [TranscriptWord]) -> [ClosedRange<Double>] {
        guard !words.isEmpty else { return ranges }
        let cores = words.map { ($0.start + 0.02)...max($0.start + 0.02, $0.end - 0.05) }
        return ranges.compactMap { r in
            var pieces = [r]
            for c in cores where c.overlaps(r) {
                pieces = pieces.flatMap { p -> [ClosedRange<Double>] in
                    guard p.overlaps(c) else { return [p] }
                    var out: [ClosedRange<Double>] = []
                    if c.lowerBound > p.lowerBound { out.append(p.lowerBound...c.lowerBound) }
                    if c.upperBound < p.upperBound { out.append(c.upperBound...p.upperBound) }
                    return out
                }
            }
            return pieces.max { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }
                .flatMap { $0.upperBound - $0.lowerBound >= 0.15 ? $0 : nil }
        }
    }

    // MARK: Review

    /// Automatic cuts of one kind, in time order.
    func automaticCuts(_ origin: CutOrigin) -> [CutRange] {
        settings.cuts.filter { $0.origin == origin }.sorted { $0.start < $1.start }
    }

    /// Takes back all automatic cuts of one kind (one undo step).
    func restoreCuts(_ origin: CutOrigin) {
        commitUndoStep(); defer { commitUndoStep() }
        settings.cuts.removeAll { $0.origin == origin }
        dropStaleSelection()
    }

    /// Selects the next automatic change after the playhead and puts the playhead just before it
    /// (space plays it). Wraps around at the end.
    func reviewNext(cuts origin: CutOrigin? = nil, breaths: Bool = false) {
        let items: [(Double, EditorSelection)] = breaths
            ? breathRegions.map { ($0.start, EditorSelection.mute($0.id)) }
            : automaticCuts(origin ?? .filler).map { ($0.start, EditorSelection.cut($0.id)) }
        guard !items.isEmpty else { return }
        let sorted = items.sorted { $0.0 < $1.0 }
        let next = sorted.first { $0.0 > currentTime + 0.05 } ?? sorted[0]
        if isPlaying { pause() }
        selection = next.1
        seek(to: sourceTime(max(0, display(next.0) - 1.5)))
    }
}

// MARK: - Cursor ranges

extension EditorModel {
    var selectedCursorRange: CursorRange? {
        guard case .cursorRange(let id) = selection else { return nil }
        return settings.cursorRanges.first { $0.id == id }
    }

    func addCursorRange(start: Double, end: Double, effect: CursorEffect = .spotlight) {
        commitUndoStep(); defer { commitUndoStep() }
        let r = clampedRange(start, end, minLength: 0.3)
        let range = CursorRange(start: r.start, end: r.end, effect: effect)
        settings.cursorRanges.append(range)
        settings.cursorRanges.sort { $0.start < $1.start }
        selection = .cursorRange(range.id)
    }

    func addCursorRangeAtPlayhead() {
        let r = sourceRange(from: currentTime, timelineLength: 3)
        addCursorRange(start: r.start, end: r.end)
    }

    func updateCursorRange(id: UUID, _ change: (inout CursorRange) -> Void) {
        guard let i = settings.cursorRanges.firstIndex(where: { $0.id == id }) else { return }
        var r = settings.cursorRanges[i]
        change(&r)
        (r.start, r.end) = clampedRange(r.start, r.end, minLength: 0.3)
        r.size = min(2.5, max(0.5, r.size))
        settings.cursorRanges[i] = r
    }
}
