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
        try transcriptToolsTest()
        try await MainActor.run { try editorTest(base) }
        try await speechTest(dir)
        try await polishTest(base)
        try await appleTest()
        try await RoundTwoTest.run(base: base, dir: dir)
    }

    /// Searching the transcript (case, accents, across words) and its parts between chapters.
    private static func transcriptToolsTest() throws {
        let words = ["Ja", " du", " möchtest", " das", " Lernsachenheft", " wie", " eine", " App", " benutzen.", " Eine", " App!"]
        let m = { (q: String) in TranscriptTools.matches(in: words, query: q) }
        guard m("MOCHTEST") == [2...2], m("eine  app") == [6...7, 9...10], m("sachen") == [4...4], m("app benutzen") == [7...8],
              m("") == [], m("  ") == [], m("gibt es nicht") == [] else {
            throw fail("transcript search: \(m("MOCHTEST")) \(m("eine  app")) \(m("app benutzen"))")
        }
        let starts: [Double] = [0, 1, 2, 3, 4]
        let a = Chapter(time: 0.5, title: "A"), b = Chapter(time: 1.5, title: "B"), empty = Chapter(time: 1.7, title: "Leer")
        let parts = TranscriptTools.parts(wordStarts: starts, chapters: [b, a, empty])
        guard parts.map(\.chapter?.title) == [nil, "A", "B", "Leer"], parts.map(\.words) == [0..<1, 1..<2, 2..<2, 2..<5],
              TranscriptTools.parts(wordStarts: starts, chapters: []).map(\.words) == [0..<5],
              TranscriptTools.parts(wordStarts: starts, chapters: [Chapter(time: 0, title: "Start")]).map(\.words) == [0..<5] else {
            throw fail("transcript parts: \(parts.map(\.words))")
        }
        // Inside an inserted clip all words and chapters share a tiny source range: they are
        // divided on the timeline.
        let clipStarts = [0.999, 0.999001, 0.999002, 0.999003]
        let inClip = [Chapter(time: 0.9990005, title: "Eins"), Chapter(time: 0.9990025, title: "Zwei")]
        let clipParts = TranscriptTools.parts(wordStarts: clipStarts, chapters: inClip) { ($0 - 0.999) * 600_000 }
        guard clipParts.map(\.chapter?.title) == [nil, "Eins", "Zwei"], clipParts.map(\.words) == [0..<1, 1..<3, 3..<4] else {
            throw fail("transcript parts in an inserted clip: \(clipParts.map(\.words))")
        }
        print("✓ transcript: search ignores case and accents and finds phrases across words; chapters divide the words (also inside an inserted clip)")
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
        // YouTube upload helper: a draft from the suggestions, kept with the project, its chapters
        // brought up to date, checked like YouTube Studio checks, captions as SRT next to the video.
        let draft = editor.loadYouTubeDraft()
        guard draft.title == "T", draft.description.hasPrefix("D\n\n0:00 Start"), draft.description.hasSuffix("#a"), draft.problems.isEmpty else {
            throw fail("YouTube draft: \(draft)")
        }
        var bad = draft
        bad.title = String(repeating: "x", count: 101) + "<"
        guard bad.problems.count == 2 else { throw fail("YouTube checks: \(bad.problems)") }
        guard EditorModel.replacingChapters(in: "Intro\n\n0:00 Alt\n1:00 Alt 2\n\n#tag", with: "0:00 Start\n0:05 Neu") == "Intro\n\n0:00 Start\n0:05 Neu\n\n#tag",
              EditorModel.replacingChapters(in: "Ohne Kapitel", with: "0:00 Start") == "Ohne Kapitel" else { throw fail("chapters in the description") }
        let draftFile = editor.project.url.appendingPathComponent(YouTubeDraft.fileName)
        defer { try? FileManager.default.removeItem(at: draftFile) }
        editor.saveYouTubeDraft(YouTubeDraft(title: "Mein Titel", description: "Text\n\n0:00 Alt\n\nLinks"))
        let saved = editor.loadYouTubeDraft()
        guard saved.title == "Mein Titel", saved.description == "Text\n\n" + editor.youTubeChapterText + "\n\nLinks" else { throw fail("saved YouTube draft: \(saved)") }
        // The exported video is remembered with the draft (the helper opens any time later) and
        // knows whether the project changed since.
        let exported = editor.project.url.deletingLastPathComponent().appendingPathComponent("export-test.mp4")
        editor.rememberExport(exported)
        let remembered = editor.loadYouTubeDraft()
        guard remembered.video == exported.path, remembered.videoEdit == editor.editFingerprint, remembered.title == "Mein Titel" else {
            throw fail("remembered export: \(remembered)")
        }
        let paddingBefore = editor.settings.padding
        editor.settings.padding += 0.01
        guard editor.editFingerprint != remembered.videoEdit else { throw fail("edit fingerprint did not change") }
        editor.settings.padding = paddingBefore
        guard editor.editFingerprint == remembered.videoEdit,
              EditorModel.isChapterLine("0:00 Start"), EditorModel.isChapterLine("1:02:03 Ende"), !EditorModel.isChapterLine("Links 0:00") else {
            throw fail("edit fingerprint / chapter lines")
        }
        let captionsBefore = editor.settings.captions
        editor.settings.captions = [Caption(start: 0.5, end: 1.0, text: "Hallo YouTube")]
        let video = editor.project.url.deletingLastPathComponent().appendingPathComponent("upload-test.mp4")
        let srt = editor.writeUploadCaptions(nextTo: video)
        defer { srt.map { try? FileManager.default.removeItem(at: $0) } }
        guard let srt, srt.lastPathComponent == "upload-test.srt", (try? String(contentsOf: srt, encoding: .utf8))?.contains("Hallo YouTube") == true else {
            throw fail("captions for YouTube: \(String(describing: srt))")
        }
        editor.settings.captions = captionsBefore
        // Library: a file still used by the project cannot be removed.
        let libraryFile = editor.project.url.appendingPathComponent("media/1234ABCD-Bibliothek Test.m4a")
        guard editor.libraryUses(libraryFile) == 0 else { throw fail("unused library file counted as used") }
        editor.settings.music = BackgroundMusic(file: "media/1234ABCD-Bibliothek Test.m4a", name: "Bibliothek Test")
        guard editor.libraryUses(libraryFile) == 1 else { throw fail("used library file not found: \(editor.libraryUses(libraryFile))") }
        editor.settings.music = nil
        // Renaming a project: its folder gets the new name; "/" is not allowed, an existing name is refused.
        let folder = editor.project.url.deletingLastPathComponent().appendingPathComponent("Umbenennen-Test", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Alt.\(Project.fileExtension)"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Belegt.\(Project.fileExtension)"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let renamed = try AppModel.rename(project: folder.appendingPathComponent("Alt.\(Project.fileExtension)"), to: " Neu/Teil 2 ")
        let recased = try AppModel.rename(project: renamed, to: "neu-teil 2")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard renamed.lastPathComponent == "Neu-Teil 2.\(Project.fileExtension)", names.contains("neu-teil 2.\(Project.fileExtension)"),
              recased.lastPathComponent == "neu-teil 2.\(Project.fileExtension)", (try? AppModel.rename(project: recased, to: "Belegt")) == nil,
              (try? AppModel.rename(project: recased, to: "  ")) == nil else { throw fail("rename: \(names)") }
        // Simple mode: empty mask and marking lanes disappear.
        let full = TimelineLayout(available: 600, audioCount: 2)
        let simple = TimelineLayout(available: 600, audioCount: 2, showMasks: false, showAnnotations: false)
        guard simple.textY == full.textY - 48, simple.maskH == 0 else { throw fail("simple layout") }
        print("✓ AI: answer parsed (also from code fences and loose JSON), transcript with output times, chapters and a portrait clip project from the suggestions, YouTube text and upload helper (draft, checks, chapters, SRT), library files in use, renaming projects; simple mode hides empty lanes")
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
