import Foundation
import AVFoundation

/// Selftests for the AI suggestions (parsing, time mapping, clip projects, providers), text to
/// speech, "Automatisch aufpolieren" and the simple mode layout.
enum AssistantTest {
    private static func fail(_ m: String) -> NSError {
        NSError(domain: "selftest", code: 80, userInfo: [NSLocalizedDescriptionKey: m])
    }

    static func run(base: Project, dir: URL) async throws {
        try parseTest()
        try await MainActor.run { try editorTest(base) }
        try await speechTest(dir)
        try await polishTest(base)
        try await appleTest()
        try await RoundTwoTest.run(base: base, dir: dir)
    }

    private static func parseTest() throws {
        let fenced = """
        Hier ist das Ergebnis:
        ```json
        {"chapters":[{"time":0,"title":"Start"},{"time":42.5,"title":"Export"}],"titles":["A","B","C"],
         "description":"Man lernt X.","tags":["mac","video"],"clips":[{"start":10,"end":40,"title":"Tipp","reason":"kurz"}]}
        ```
        """
        let s = try AIAssistant.parse(fenced)
        guard s.chapters.count == 2, s.chapters[1].time == 42.5, s.titles.count == 3, s.clips.first?.end == 40 else { throw fail("AI parse: \(s)") }
        // Lenient: numbers as strings, missing parts.
        let loose = try AIAssistant.parse("{\"chapters\":[{\"time\":\"12\",\"title\":\"X\"}],\"clips\":[{\"start\":\"5\",\"end\":\"25\"}]}")
        guard loose.chapters.first?.time == 12, loose.clips.first?.title == "Clip", loose.titles.isEmpty else { throw fail("AI lenient parse: \(loose)") }
        do { _ = try AIAssistant.parse("keine Ahnung"); throw fail("AI parse accepted text") } catch is AIError {}
        let prompt = AIAssistant.prompt(transcript: "[0.0] Hallo", duration: 60, language: "Deutsch")
        guard prompt.contains("\"chapters\"") && prompt.contains("[0.0] Hallo") else { throw fail("AI prompt") }
    }

    @MainActor
    private static func editorTest(_ base: Project) throws {
        var s = EditSettings()
        s.removeEcho = false
        s.cuts = [CutRange(start: 1.0, end: 1.5)]
        s.captions = [Caption(start: 0.2, end: 0.9, text: "Hallo zusammen"), Caption(start: 1.6, end: 2.8, text: "Jetzt geht es los")]
        let editor = EditorModel(project: Project(url: base.url, info: base.info, cursor: base.cursor, settings: s))
        // Output ↔ source (the cut removes 0.5 s).
        for t in [0.3, 0.9, 1.7, 2.5] {
            guard let o = editor.outputTime(ofSource: t), let back = editor.sourceTime(ofOutput: o), abs(back - t) < 1e-6 else {
                throw fail("output/source mapping at \(t)")
            }
        }
        guard let transcript = editor.transcriptForAI, transcript.contains("[0.2] Hallo zusammen"), transcript.contains("[1.1] Jetzt") else {
            throw fail("transcript for AI: \(editor.transcriptForAI ?? "nil")")
        }
        // Suggestions → chapters (source time) and a clip project.
        editor.aiSuggestions = AISuggestions(chapters: [.init(time: 0, title: "Start"), .init(time: 1.1, title: "Los")], titles: ["T"],
                                             description: "D", tags: ["a"], clips: [.init(start: 1.1, end: 2.5, title: "Selbsttest-Clip", reason: nil)])
        editor.applyAIChapters()
        guard editor.settings.chapters.count == 2, abs(editor.settings.chapters[1].time - 1.6) < 1e-6 else {
            throw fail("AI chapters: \(editor.settings.chapters.map(\.time))")
        }
        var opened: URL?
        editor.openProject = { opened = $0 }
        editor.createClipProject(editor.aiSuggestions!.clips[0])
        guard let url = opened, let clip = try? Project.load(from: url) else { throw fail("clip project not created") }
        defer { try? FileManager.default.removeItem(at: url) }
        guard abs(clip.settings.trimStart - 1.6) < 1e-6, let end = clip.settings.trimEnd, abs(end - 3.0) < 1e-6,
              clip.settings.aspect == .vertical, clip.settings.contentY != nil else {
            throw fail("clip project: trim \(clip.settings.trimStart)–\(String(describing: clip.settings.trimEnd)), \(clip.settings.aspect)")
        }
        guard editor.youTubeText().contains("D"), editor.youTubeText().contains("#a") else { throw fail("YouTube text") }
        // Simple mode: empty mask and marking lanes disappear.
        let full = TimelineLayout(available: 600, audioCount: 2)
        let simple = TimelineLayout(available: 600, audioCount: 2, showMasks: false, showAnnotations: false)
        guard simple.textY == full.textY - 48, simple.maskH == 0 else { throw fail("simple layout") }
        print("✓ AI: answer parsed (also from code fences and loose JSON), transcript with output times, chapters and a portrait clip project from the suggestions, YouTube text; simple mode hides empty lanes")
    }

    private static func speechTest(_ dir: URL) async throws {
        let url = dir.appendingPathComponent("tts.caf")
        let voice = SpeechMaker.voices(language: "de-DE").first?.identifier
        try await SpeechMaker.synthesize("Hallo, ich bin der Erklärbär.", voiceID: voice, rate: 0.5, to: url)
        let length = try await AVURLAsset(url: url).load(.duration).seconds
        guard length > 0.5 else { throw fail("text to speech: \(length) s") }
        print(String(format: "✓ text to speech: %.1f s spoken with %@", length, voice.flatMap { AVSpeechSynthesisVoice(identifier: $0)?.name } ?? "default voice"))
    }

    private static func polishTest(_ base: Project) async throws {
        let editor = await MainActor.run { () -> EditorModel in
            var s = EditSettings()
            s.removeEcho = false
            s.zoomSegments = []
            return EditorModel(project: Project(url: base.url, info: base.info, cursor: base.cursor, settings: s))
        }
        var o = PolishOptions()
        o.voice = false; o.captions = false; o.fillers = false
        await editor.polish(o)
        let (state, zooms) = await MainActor.run { (editor.polishState, editor.settings.zoomSegments.count) }
        guard case .done(let note) = state, zooms > 0, note.contains("Zooms") else { throw fail("polish: \(state), zooms \(zooms)") }
        print("✓ automatisch aufpolieren: \(note)")
    }

    private static func appleTest() async throws {
        if let problem = AISettings.appleProblem {
            print("– Apple Intelligence skipped: \(problem)")
            return
        }
        let answer: String
        do {
            answer = try await AIAssistant.apple("Antworte nur mit diesem JSON und sonst nichts: {\"titles\":[\"Test\"]}")
        } catch {
            // The model on the Mac can fail for reasons of its own; that says nothing about the app.
            print("– Apple Intelligence skipped: \(error.localizedDescription)")
            return
        }
        let parsed = try AIAssistant.parse(answer)
        guard !parsed.titles.isEmpty else { throw fail("Apple Intelligence answer: \(answer)") }
        print("✓ Apple Intelligence on the Mac answers with readable JSON")
    }
}
