import AppKit
import AVFoundation
import Translation

// MARK: - AI suggestions

extension EditorModel {
    enum AIState: Equatable { case idle, working, done, failed(String) }

    /// Source time of a moment in the exported video (inverse of `outputTime(ofSource:)`).
    func sourceTime(ofOutput o: Double) -> Double? {
        let t = o - introLead
        return t >= 0 && t <= timeMap.total + 1e-6 ? sourceTime(min(t, timeMap.total - 1e-6)) : nil
    }

    /// The transcript with times in the finished video ("[12.3] Text"), from the captions.
    var transcriptForAI: String? {
        let lines = settings.captions.compactMap { c -> String? in
            guard let t = outputTime(ofSource: c.start) else { return nil }
            return String(format: "[%.1f] %@", t, c.text)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The prompt for any AI app (clipboard workflow) or the providers.
    func aiPrompt() throws -> String {
        guard let transcript = transcriptForAI else { throw AIError.noTranscript }
        let language = Locale(identifier: "de").localizedString(forIdentifier: settings.captionLanguage) ?? settings.captionLanguage
        return AIAssistant.prompt(transcript: transcript, duration: outputDuration, language: language)
    }

    /// Asks the chosen provider for chapters, titles, description and clip ideas.
    func askAI() async {
        aiState = .working
        do {
            let prompt = try aiPrompt()
            let answer = try await AIAssistant.run(prompt: prompt, provider: AISettings.provider)
            aiSuggestions = try AIAssistant.parse(answer)
            aiState = .done
        } catch {
            aiState = .failed(error.localizedDescription)
        }
    }

    /// The answer of another AI app, pasted back.
    func useAIAnswer(_ text: String) {
        do {
            aiSuggestions = try AIAssistant.parse(text)
            aiState = .done
        } catch {
            aiState = .failed(error.localizedDescription)
        }
    }

    /// Replaces the chapters with the suggested ones.
    func applyAIChapters() {
        guard let s = aiSuggestions else { return }
        commitUndoStep(); defer { commitUndoStep() }
        settings.chapters = s.chapters.compactMap { c in
            sourceTime(ofOutput: c.time).map { Chapter(time: $0, title: c.title) }
        }
    }

    /// Title, description, tags and chapters ready for the upload page.
    func youTubeText(title: String? = nil) -> String {
        var parts: [String] = []
        if let title = title ?? aiSuggestions?.titles.first { parts.append(title) }
        if let d = aiSuggestions?.description, !d.isEmpty { parts.append(d) }
        if !settings.chapters.isEmpty { parts.append(youTubeChapterText) }
        if let tags = aiSuggestions?.tags, !tags.isEmpty { parts.append(tags.map { "#" + $0.replacingOccurrences(of: " ", with: "") }.joined(separator: " ")) }
        return parts.joined(separator: "\n\n")
    }

    /// A suggested clip becomes its own project: a copy (cloned on APFS, no extra space) trimmed to
    /// the clip, in portrait with the recording at the top.
    func createClipProject(_ clip: AISuggestions.Clip) {
        guard let a = sourceTime(ofOutput: clip.start), let b = sourceTime(ofOutput: clip.end), b > a + 1 else { return }
        saveNow()
        let fm = FileManager.default
        let safe = clip.title.replacingOccurrences(of: "/", with: "-").prefix(40)
        var url = project.url.deletingLastPathComponent().appendingPathComponent("\(project.name) – \(safe).\(Project.fileExtension)")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = project.url.deletingLastPathComponent().appendingPathComponent("\(project.name) – \(safe) \(n).\(Project.fileExtension)")
            n += 1
        }
        do {
            try fm.copyItem(at: project.url, to: url)
            let copy = try Project.load(from: url)
            var s = copy.settings
            s.trimStart = a
            s.trimEnd = b
            s.texts.removeAll { $0.kind == .titleCard && $0.placement != .overlay }
            s.introOverlap = 0; s.outroOverlap = 0
            s.chapters = []
            s.switchAspect(to: .vertical)
            if s.captionStyle.mode == .sentence { CaptionStyle.presets.first { $0.id == "tiktok" }?.apply(&s.captionStyle) }
            copy.settings = s
            try copy.saveSettings()
            openProject?(url)
        } catch {
            aiState = .failed("Clip konnte nicht angelegt werden: \(error.localizedDescription)")
        }
    }
}

// MARK: - Text to speech

enum SpeechMaker {
    /// Voices for a language, best quality first.
    static func voices(language: String) -> [AVSpeechSynthesisVoice] {
        let prefix = String(language.prefix(2))
        // Premium and enhanced voices first, then Apple's natural voices; the synthetic "Eloquence"
        // and novelty voices last.
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            if v.identifier.contains("eloquence") { return 0 }
            if v.identifier.contains("speech.synthesis") { return -1 }
            return 1 + v.quality.rawValue * 2
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .sorted { (rank($0), $1.name) > (rank($1), $0.name) }
    }

    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        let quality = v.quality == .premium ? " (Premium)" : v.quality == .enhanced ? " (verbessert)" : ""
        return "\(v.name)\(quality)"
    }

    /// Speaks `text` into a 48 kHz audio file.
    @MainActor
    static func synthesize(_ text: String, voiceID: String?, rate: Float, to url: URL) async throws {
        let synth = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: "de-DE")
        utterance.rate = AVSpeechUtteranceMinimumSpeechRate + (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * rate
        try? FileManager.default.removeItem(at: url)
        final class Sink: @unchecked Sendable { var file: AVAudioFile?; var error: Error?; var done = false }
        let sink = Sink()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            synth.write(utterance) { buffer in
                guard !sink.done else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    sink.done = true
                    sink.file = nil   // closes the file
                    if let error = sink.error { cont.resume(throwing: error) } else { cont.resume() }
                    return
                }
                do {
                    if sink.file == nil {
                        sink.file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                                    commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                    }
                    try sink.file?.write(from: pcm)
                } catch {
                    sink.error = error
                }
            }
        }
        _ = synth
        // Some voices (Siri's) may not render into a file for other apps: fall back to a standard voice.
        if !FileManager.default.fileExists(atPath: url.path) || ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 1000 {
            let fallback = voices(language: utterance.voice?.language ?? "de-DE")
                .first { !$0.identifier.contains("siri") && $0.identifier != voiceID }?.identifier
            if let fallback, fallback != voiceID {
                try await synthesize(text, voiceID: fallback, rate: rate, to: url)
            }
        }
    }
}

extension EditorModel {
    /// Turns typed text into a voice-over clip at the playhead.
    func addSpokenText(_ text: String, voiceID: String?, rate: Float) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let dir = project.url.appendingPathComponent("voiceover", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = "voiceover/tts-\(UUID().uuidString.prefix(8)).caf"
        let url = project.url.appendingPathComponent(file)
        do {
            try await SpeechMaker.synthesize(trimmed, voiceID: voiceID, rate: rate, to: url)
            let length = try await AVURLAsset(url: url).load(.duration).seconds
            guard length > 0.1 else { return }
            commitUndoStep(); defer { commitUndoStep() }
            let clip = VoiceOverClip(file: file, fileOffset: 0, start: min(max(0, currentTime), duration), duration: length)
            settings.voiceOvers.append(adopted(clip))
            selectedVoiceOverID = clip.id
            loadVoiceOverWaveform(file)
        } catch {
            voiceOverError = "Sprachausgabe fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}

// MARK: - Translating captions

extension EditorModel {
    /// Translates all captions with Apple's on-device translation (one undo step).
    func translateCaptions(with session: TranslationSession, target: String) async {
        let requests = settings.captions.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString) }
        guard !requests.isEmpty else { return }
        captionStatus = "Untertitel werden übersetzt …"
        do {
            let responses = try await session.translations(from: requests)
            commitUndoStep(); defer { commitUndoStep() }
            for r in responses {
                guard let id = r.clientIdentifier, let i = settings.captions.firstIndex(where: { $0.id.uuidString == id }) else { continue }
                settings.captions[i].text = r.targetText
            }
            settings.captionLanguage = target
            captionStatus = "\(responses.count) Untertitel übersetzt (⌘Z stellt das Original wieder her)."
        } catch {
            captionError = "Übersetzung fehlgeschlagen: \(error.localizedDescription)"
            captionStatus = nil
        }
    }
}

// MARK: - Polish in one go

/// What "Automatisch aufpolieren" does.
struct PolishOptions: Equatable {
    var voice = true
    var breaths = true
    var captions = true
    var fillers = true
    var pauses = true
    var zoom = true
    var levels = true
}

/// Starting points for a new video ("Was möchtest du erstellen?").
enum VideoGoal: String, CaseIterable, Identifiable {
    case tutorial, short, demo, training
    var id: String { rawValue }

    var title: String {
        switch self {
        case .tutorial: return "YouTube-Tutorial"
        case .short: return "Kurzvideo"
        case .demo: return "Produkt-Demo"
        case .training: return "Anleitung für Kolleg:innen"
        }
    }

    var subtitle: String {
        switch self {
        case .tutorial: return "16:9, Untertitel, Kapitel, Zooms"
        case .short: return "9:16 für Reels, Shorts, TikTok – Wortgruppen-Untertitel"
        case .demo: return "16:9, ruhig, Zooms auf jeden Klick, ohne Untertitel"
        case .training: return "16:9, Untertitel mit hervorgehobenem Wort"
        }
    }

    var icon: String {
        switch self {
        case .tutorial: return "play.rectangle"
        case .short: return "iphone"
        case .demo: return "sparkles.tv"
        case .training: return "person.2.wave.2"
        }
    }

    func apply(to s: inout EditSettings, options: inout PolishOptions) {
        switch self {
        case .tutorial:
            s.switchAspect(to: .wide)
            CaptionStyle.presets.first { $0.id == "classic" }?.apply(&s.captionStyle)
        case .short:
            s.switchAspect(to: .vertical)
            CaptionStyle.presets.first { $0.id == "tiktok" }?.apply(&s.captionStyle)
            s.exportFPS = 30
        case .demo:
            s.switchAspect(to: .wide)
            options.captions = false
            options.fillers = false
        case .training:
            s.switchAspect(to: .wide)
            CaptionStyle.presets.first { $0.id == "karaoke" }?.apply(&s.captionStyle)
        }
    }
}

extension EditorModel {
    enum PolishState: Equatable { case idle, running(String), done(String) }

    /// Runs the chosen steps one after another (each is its own undo step).
    func polish(_ o: PolishOptions) async {
        var notes: [String] = []
        if o.voice {
            polishState = .running("Stimme verbessern …")
            settings.voice.enabled = true
            notes.append("Stimme verbessert")
            if o.breaths {
                polishState = .running("Atemgeräusche suchen …")
                await setBreaths(true)
                if !breathRegions.isEmpty { notes.append("\(breathRegions.count) Atemgeräusche gedämpft") }
            }
        }
        if o.captions || o.fillers {
            polishState = .running("Sprache erkennen …")
            if settings.captions.isEmpty || settings.words.isEmpty {
                await generateCaptionsNow()
            }
            if o.captions, !settings.captions.isEmpty { settings.showCaptions = true; notes.append("\(settings.captions.count) Untertitel") }
        }
        if o.fillers {
            let count = fillerWordIndices.count
            polishState = .running("Füllwörter entfernen …")
            removeFillerWords()
            if count > 0 { notes.append("\(count) Füllwörter entfernt") }
        }
        if o.pauses {
            polishState = .running("Pausen entfernen …")
            let count = detectedPauses.count
            removePauses()
            if count > 0 { notes.append("\(count) Pausen gekürzt") }
        }
        if o.zoom {
            polishState = .running("Zooms setzen …")
            regenerateAutoZoom()
            notes.append("Zooms auf Klicks")
        }
        if o.levels {
            polishState = .running("Pegel angleichen …")
            await autoLevel()
            notes.append("Pegel angeglichen")
        }
        polishState = .done(notes.isEmpty ? "Nichts zu tun." : notes.joined(separator: " · ") + ". ⌘Z nimmt die Schritte einzeln zurück.")
    }
}
