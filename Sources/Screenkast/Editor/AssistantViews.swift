import SwiftUI
import AVFoundation
import Translation

// MARK: - Polish ("Automatisch aufpolieren") and the start assistant

final class PolishSheetModel: ObservableObject {
    @Published var goal: VideoGoal?
    @Published var options = PolishOptions()
}

struct PolishSheet: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var model = PolishSheetModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Was möchtest du erstellen?").font(.title2.bold())
            Text("Erklärbär stellt Format und Stil passend ein und poliert die Aufnahme auf. Alles lässt sich danach ändern.")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(VideoGoal.allCases) { goal in
                    let active = model.goal == goal
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: goal.icon).font(.title2).frame(width: 30).foregroundStyle(Theme.brand)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(goal.title).font(.headline)
                            Text(goal.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                    .background(active ? Theme.brand.opacity(0.15) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(active ? Theme.brand : .clear, lineWidth: 2))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.goal = active ? nil : goal
                        var o = PolishOptions()
                        var s = editor.settings
                        if let g = model.goal { g.apply(to: &s, options: &o) }
                        model.options = o
                    }
                }
            }
            GroupBox("Aufpolieren") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Stimme verbessern (Rauschen, Lautheit)", isOn: $model.options.voice)
                    Toggle("Atemgeräusche dämpfen", isOn: $model.options.breaths).disabled(!model.options.voice).padding(.leading, 18)
                    Toggle("Untertitel erzeugen", isOn: $model.options.captions)
                    Toggle("Füllwörter („äh“, „ähm“, Doppelungen) herausschneiden", isOn: $model.options.fillers)
                    Toggle("Lange Pausen kürzen", isOn: $model.options.pauses)
                    Toggle("Zooms auf Klicks setzen", isOn: $model.options.zoom)
                    Toggle("Pegel der Tonspuren angleichen", isOn: $model.options.levels)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            switch editor.polishState {
            case .running(let step):
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(step) }
            case .done(let note):
                Label(note, systemImage: "checkmark.circle.fill").foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }
            HStack {
                Button("Schließen") { editor.showPolishSheet = false }
                    .keyboardShortcut(.cancelAction)
                Toggle("Nach jeder Aufnahme fragen", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "showAssistant") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "showAssistant"); editor.objectWillChange.send() }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Button {
                    if let goal = model.goal {
                        editor.commitUndoStep()
                        var o = model.options
                        goal.apply(to: &editor.settings, options: &o)
                        editor.commitUndoStep()
                    }
                    let options = model.options
                    Task { await editor.polish(options) }
                } label: {
                    Label("Aufpolieren", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled({ if case .running = editor.polishState { return true } else { return false } }())
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear { if case .done = editor.polishState { editor.polishState = .idle } }
    }
}

// MARK: - AI suggestions

final class AISheetModel: ObservableObject {
    @Published var provider = AISettings.provider { didSet { AISettings.provider = provider } }
    @Published var model = AISettings.claudeModel { didSet { AISettings.claudeModel = model } }
    @Published var key = AISettings.claudeKey ?? ""
    @Published var pasted = ""
    @Published var copied = false
}

struct AISheet: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var m = AISheetModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("KI-Vorschläge").font(.title2.bold())
                Spacer()
                Button("Schließen") { editor.showAISheet = false }.keyboardShortcut(.cancelAction)
            }
            Text("Kapitel, Titel, Beschreibung, Schlagwörter und Ideen für Kurzclips – aus dem Transkript des Videos.")
                .foregroundStyle(.secondary)
            Picker("KI", selection: $m.provider) {
                ForEach(AIProvider.allCases) { Text($0.label).tag($0) }
            }
            providerDetails
            if editor.settings.captions.isEmpty {
                Label("Zuerst Untertitel erzeugen (Text › Untertitel) – sie sind die Grundlage.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            switch editor.aiState {
            case .working: HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Die KI denkt nach …") }
            case .failed(let message): Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            default: EmptyView()
            }
            if let s = editor.aiSuggestions {
                ScrollView { results(s) }.frame(maxHeight: 360)
            }
        }
        .padding(22)
        .frame(width: 620)
    }

    @ViewBuilder
    private var providerDetails: some View {
        switch m.provider {
        case .apple:
            if let problem = AISettings.appleProblem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            } else {
                Text("Läuft komplett auf dem Mac, nichts verlässt das Gerät. Für sehr lange Videos reicht sein Gedächtnis eventuell nicht – dann Claude oder eine andere KI nutzen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            askButton
        case .claude:
            HStack {
                SecureField("API-Schlüssel (sk-ant-…)", text: $m.key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { AISettings.claudeKey = m.key }
                Picker("", selection: $m.model) {
                    ForEach(AISettings.claudeModels, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
            }
            Text("Der Schlüssel liegt im Schlüsselbund des Macs. Das Transkript wird an Anthropic gesendet; Kosten laufen über dein Konto (console.anthropic.com).")
                .font(.caption).foregroundStyle(.secondary)
            askButton
        case .clipboard:
            HStack {
                Button {
                    do {
                        let prompt = try editor.aiPrompt()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt, forType: .string)
                        m.copied = true
                    } catch {
                        editor.aiState = .failed(error.localizedDescription)
                    }
                } label: {
                    Label(m.copied ? "Prompt kopiert – jetzt in die KI-App einfügen" : "1. Prompt kopieren", systemImage: m.copied ? "checkmark" : "doc.on.doc")
                }
                Spacer()
            }
            Text("2. In ChatGPT, Claude, Gemini … einfügen und senden. 3. Die Antwort kopieren und hier einfügen:")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $m.pasted)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            HStack {
                Button("Aus der Zwischenablage einfügen") { m.pasted = NSPasteboard.general.string(forType: .string) ?? "" }
                Spacer()
                Button("4. Antwort übernehmen") { editor.useAIAnswer(m.pasted) }
                    .buttonStyle(.borderedProminent)
                    .disabled(m.pasted.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var askButton: some View {
        HStack {
            Spacer()
            Button {
                if m.provider == .claude { AISettings.claudeKey = m.key }
                Task { await editor.askAI() }
            } label: {
                Label("Vorschläge erzeugen", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(editor.aiState == .working || editor.settings.captions.isEmpty)
        }
    }

    @ViewBuilder
    private func results(_ s: AISuggestions) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !s.titles.isEmpty {
                GroupBox("Titel") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(s.titles, id: \.self) { title in
                            HStack {
                                Text(title).textSelection(.enabled)
                                Spacer()
                                copyButton(title)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !s.description.isEmpty {
                GroupBox("Beschreibung") {
                    HStack(alignment: .top) {
                        Text(s.description).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        copyButton(s.description)
                    }
                }
            }
            if !s.chapters.isEmpty {
                GroupBox("Kapitel") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(s.chapters.enumerated()), id: \.offset) { _, c in
                            HStack {
                                Text(formatTime(c.time, fractional: false)).monospacedDigit().foregroundStyle(.secondary)
                                Text(c.title)
                            }
                        }
                        Button("Als Kapitelmarken übernehmen") { editor.applyAIChapters() }
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !s.clips.isEmpty {
                GroupBox("Ideen für Kurzclips") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(s.clips) { clip in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(clip.title).font(.headline)
                                    Text("\(formatTime(clip.start, fractional: false)) – \(formatTime(clip.end, fractional: false))"
                                         + (clip.reason.map { " · \($0)" } ?? ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Als Kurzvideo anlegen") { editor.createClipProject(clip) }
                                    .help("Neues Projekt im Hochformat, auf diesen Abschnitt gekürzt (die Aufnahme wird nicht doppelt gespeichert)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                if !s.tags.isEmpty {
                    Text(s.tags.map { "#\($0)" }.joined(separator: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(editor.youTubeText(), forType: .string)
                    NSWorkspace.shared.open(URL(string: "https://studio.youtube.com")!)
                } label: {
                    Label("Für YouTube vorbereiten", systemImage: "play.rectangle.on.rectangle")
                }
                .help("Kopiert Titel, Beschreibung, Kapitel und Schlagwörter und öffnet YouTube Studio zum Hochladen")
            }
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help("Kopieren")
    }
}

// MARK: - Text to speech

final class SpeechSheetModel: ObservableObject {
    @Published var text = ""
    @Published var voiceID: String?
    @Published var rate: Double = 0.5
    @Published var working = false
}

struct SpeechSheet: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var m = SpeechSheetModel()

    var body: some View {
        let voices = SpeechMaker.voices(language: editor.settings.captionLanguage)
        VStack(alignment: .leading, spacing: 12) {
            Text("Text sprechen lassen").font(.title2.bold())
            Text("Die Mac-Stimme spricht den Text als Voice-over ab dem Abspielkopf (\(formatTime(editor.display(editor.currentTime)))). Bessere Stimmen: Systemeinstellungen › Bedienungshilfen › Gesprochene Inhalte › Stimmen verwalten.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $m.text)
                .font(.body)
                .frame(height: 130)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            Picker("Stimme", selection: $m.voiceID) {
                ForEach(voices, id: \.identifier) { Text(SpeechMaker.label($0)).tag(Optional($0.identifier)) }
            }
            LabeledSlider(title: "Tempo", value: $m.rate, range: 0.3...0.7, format: { $0 < 0.45 ? "langsam" : $0 > 0.55 ? "schnell" : "normal" })
            HStack {
                Button("Probehören") {
                    let synth = PreviewSpeaker.shared
                    synth.speak(m.text, voiceID: m.voiceID, rate: Float(m.rate))
                }
                .disabled(m.text.isEmpty)
                Spacer()
                Button("Abbrechen") { editor.showSpeechSheet = false }.keyboardShortcut(.cancelAction)
                Button {
                    m.working = true
                    Task {
                        await editor.addSpokenText(m.text, voiceID: m.voiceID, rate: Float(m.rate))
                        m.working = false
                        editor.showSpeechSheet = false
                    }
                } label: {
                    if m.working { ProgressView().controlSize(.small) } else { Text("Als Voice-over einfügen") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(m.text.trimmingCharacters(in: .whitespaces).isEmpty || m.working)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { if m.voiceID == nil { m.voiceID = voices.first?.identifier } }
    }
}

/// Plays a preview of the text-to-speech voice.
@MainActor
final class PreviewSpeaker {
    static let shared = PreviewSpeaker()
    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String, voiceID: String?, rate: Float) {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:))
        u.rate = AVSpeechUtteranceMinimumSpeechRate + (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * rate
        synth.speak(u)
    }
}

// MARK: - Translating captions

final class TranslateModel: ObservableObject {
    @Published var target = "en-US"
    @Published var configuration: TranslationSession.Configuration?
}

struct CaptionTranslateRow: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var m = TranslateModel()

    static let languages: [(String, String)] = [("en-US", "Englisch"), ("de-DE", "Deutsch"), ("fr-FR", "Französisch"),
                                                ("es-ES", "Spanisch"), ("it-IT", "Italienisch"), ("nl-NL", "Niederländisch"),
                                                ("pl-PL", "Polnisch"), ("tr-TR", "Türkisch"), ("uk-UA", "Ukrainisch")]

    var body: some View {
        HStack {
            Picker("Übersetzen nach", selection: $m.target) {
                ForEach(Self.languages.filter { $0.0 != editor.settings.captionLanguage }, id: \.0) { Text($0.1).tag($0.0) }
            }
            Button("Übersetzen") {
                m.configuration = TranslationSession.Configuration(source: Locale.Language(identifier: editor.settings.captionLanguage),
                                                                   target: Locale.Language(identifier: m.target))
            }
        }
        .help("Übersetzt die Untertitel direkt auf dem Mac (Apple Übersetzen). Fehlende Sprachen lädt macOS nach Rückfrage.")
        .translationTask(m.configuration) { session in
            await editor.translateCaptions(with: session, target: m.target)
            m.configuration = nil
        }
    }
}

// MARK: - Command palette (⌘K)

struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    var keywords: String = ""
    let run: () -> Void
}

final class PaletteModel: ObservableObject {
    @Published var query = ""
    @Published var index = 0
}

struct CommandPalette: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var m = PaletteModel()

    private var commands: [PaletteCommand] {
        let e = editor
        var list: [PaletteCommand] = [
            .init(title: "Automatisch aufpolieren …", icon: "wand.and.stars", keywords: "assistent magie verbessern") { e.showPolishSheet = true },
            .init(title: "KI-Vorschläge (Kapitel, Titel, Clips) …", icon: "sparkles", keywords: "ai youtube beschreibung") { e.showAISheet = true },
            .init(title: "Text sprechen lassen …", icon: "text.bubble", keywords: "tts stimme voice") { e.showSpeechSheet = true },
            .init(title: "Sensible Daten verpixeln …", icon: "eye.slash", keywords: "datenschutz email telefon gesicht maske") { e.showSensitiveSheet = true },
            .init(title: "Anleitung aus Klicks (PDF, Markdown) …", icon: "list.number", keywords: "schritte guide dokumentation") { e.showGuideSheet = true },
            .init(title: "Am Abspielkopf teilen", icon: "scissors", keywords: "schneiden split s") { e.perform(.split) },
            .init(title: "Auswahl löschen", icon: "trash", keywords: "entfernen delete") { e.deleteSelection() },
            .init(title: "Widerrufen", icon: "arrow.uturn.backward", keywords: "undo") { e.undo() },
            .init(title: "Wiederholen", icon: "arrow.uturn.forward", keywords: "redo") { e.redo() },
            .init(title: "Standbild einfügen", icon: "snowflake", keywords: "freeze anhalten") { e.insertFreeze() },
            .init(title: "Kapitelmarke setzen", icon: "bookmark", keywords: "chapter") { e.addChapter() },
            .init(title: "Bauchbinde hinzufügen", icon: "text.below.photo", keywords: "text titel name") { e.addLowerThird() },
            .init(title: "Titelkarte (Vorspann)", icon: "rectangle.inset.filled", keywords: "intro") { e.addTitleCard(placement: .intro) },
            .init(title: "Zoom am Abspielkopf", icon: "plus.magnifyingglass", keywords: "vergrößern") { e.addZoomAtPlayhead() },
            .init(title: "Maske hinzufügen", icon: "square.grid.3x3", keywords: "verpixeln blur") { e.addMaskAtPlayhead() },
            .init(title: "Pfeil hinzufügen", icon: "arrow.up.right", keywords: "markierung") { e.addAnnotation(.arrow) },
            .init(title: "Rahmen hinzufügen", icon: "rectangle", keywords: "markierung") { e.addAnnotation(.frame) },
            .init(title: "Spotlight hinzufügen", icon: "flashlight.on.fill", keywords: "markierung") { e.addAnnotation(.spotlight) },
            .init(title: "Bild einblenden …", icon: "photo", keywords: "logo grafik") { e.addImage() },
            .init(title: "Video als Bild im Bild …", icon: "pip", keywords: "overlay") { e.addVideoOverlay() },
            .init(title: "Videoclip einfügen …", icon: "film.stack", keywords: "insert") { e.addInsertClip() },
            .init(title: "Sprachaufnahme (Audiodatei) …", icon: "waveform.badge.plus", keywords: "audio voice") { e.addNarrationFile() },
            .init(title: "Musik wählen …", icon: "music.note", keywords: "hintergrund") { e.chooseMusic() },
            .init(title: "Untertitel erzeugen", icon: "captions.bubble", keywords: "transkript sprache") { e.generateCaptions() },
            .init(title: "Füllwörter entfernen", icon: "text.badge.minus", keywords: "äh ähm") { e.removeFillerWords() },
            .init(title: "Pausen kürzen", icon: "pause", keywords: "stille") { e.removePauses() },
            .init(title: "Pegel angleichen", icon: "slider.horizontal.3", keywords: "lautstärke audio") { Task { await e.autoLevel() } },
            .init(title: "Video exportieren …", icon: "square.and.arrow.up", keywords: "export mp4") { e.showExportSheet = true },
            .init(title: e.simpleMode ? "Profi-Modus (alle Spuren)" : "Einfach-Modus (weniger Spuren)", icon: "slider.horizontal.below.square.filled.and.square",
                  keywords: "ansicht modus") { e.simpleMode.toggle() },
        ]
        for aspect in OutputAspect.allCases {
            list.append(.init(title: "Format \(aspect.rawValue)", icon: "aspectratio", keywords: "hochformat querformat reels") { e.setAspect(aspect) })
        }
        for tab in InspectorTab.allCases {
            list.append(.init(title: "Seitenleiste: \(tab.title)", icon: tab.icon, keywords: tab.help) { e.selection = nil; e.inspectorTab = tab })
        }
        return list
    }

    private var filtered: [PaletteCommand] {
        let q = m.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        let words = q.split(separator: " ").map(String.init)
        return commands.filter { c in
            let hay = (c.title + " " + c.keywords).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    var body: some View {
        let items = filtered
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Befehl suchen …", text: $m.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit { run(items) }
                    .onChange(of: m.query) { _, _ in m.index = 0 }
                    .onKeyPress(.downArrow) { m.index = min(items.count - 1, m.index + 1); return .handled }
                    .onKeyPress(.upArrow) { m.index = max(0, m.index - 1); return .handled }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                            HStack(spacing: 10) {
                                Image(systemName: c.icon).frame(width: 20).foregroundStyle(.secondary)
                                Text(c.title)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(i == m.index ? Theme.brand.opacity(0.2) : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { m.index = i; run(items) }
                            .id(i)
                        }
                    }
                }
                .onChange(of: m.index) { _, i in proxy.scrollTo(i) }
            }
            .frame(height: 320)
        }
        .frame(width: 480)
        .onExitCommand { editor.showPalette = false }
    }

    private func run(_ items: [PaletteCommand]) {
        guard items.indices.contains(m.index) else { return }
        let command = items[m.index]
        editor.showPalette = false
        DispatchQueue.main.async { command.run() }
    }
}

// MARK: - Context bar on the preview

/// Small bar next to the selected element in the preview with its most used actions.
struct PreviewContextBar: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        GeometryReader { geo in
            if let (rect, title) = target(size: geo.size) {
                let y = rect.minY > 44 ? rect.minY - 22 : rect.maxY + 22
                HStack(spacing: 8) {
                    Text(title).font(.caption.bold()).lineLimit(1)
                    actions
                    Divider().frame(height: 14)
                    Button { editor.deleteSelection() } label: { Image(systemName: "trash") }
                        .help("Löschen (⌫)")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                .fixedSize()
                .position(x: min(max(rect.midX, 110), geo.size.width - 110), y: y)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch editor.selection {
        case .annotation(let id):
            if let a = editor.settings.annotations.first(where: { $0.id == id }), a.kind != .spotlight {
                ForEach(AnnotationColor.allCases) { c in
                    let (r, g, b) = c.rgb
                    Circle().fill(Color(red: r, green: g, blue: b))
                        .overlay(Circle().strokeBorder(a.color == c ? Color.primary : .clear, lineWidth: 1.5))
                        .frame(width: 13, height: 13)
                        .onTapGesture { editor.updateAnnotation(id: id) { $0.color = c } }
                }
            }
        case .mask(let id):
            if let m = editor.settings.masks.first(where: { $0.id == id }) {
                Button(m.style == .pixelate ? "Weichzeichnen" : "Verpixeln") {
                    editor.updateMask(id: id) { $0.style = m.style == .pixelate ? .blur : .pixelate }
                }
            }
        case .videoOverlay:
            Button { editor.perform(.split) } label: { Image(systemName: "scissors") }.help("Am Abspielkopf teilen (S)")
        case .text(let id):
            Menu {
                ForEach(TextDesignLibrary.all) { d in Button(d.name) { editor.setTextDesign(id: id, d) } }
            } label: { Image(systemName: "paintbrush") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Design")
        default:
            EmptyView()
        }
    }

    /// Element rectangle in view coordinates and its name.
    private func target(size: CGSize) -> (CGRect, String)? {
        let out = editor.renderer.outputSize
        let k = size.width / max(1, out.width)
        let toView = { (r: CGRect) in CGRect(x: r.minX * k, y: (out.height - r.maxY) * k, width: r.width * k, height: r.height * k) }
        let g = PreviewGeometry(editor: editor, size: size)
        switch editor.selection {
        case .annotation(let id):
            guard let a = editor.settings.annotations.first(where: { $0.id == id }), editor.isVisibleNow(start: a.start, end: a.end) else { return nil }
            return (g.view(CGRect(x: min(a.x, a.x + a.width), y: min(a.y, a.y + a.height), width: abs(a.width), height: abs(a.height))), a.kind.label)
        case .mask(let id):
            guard let m = editor.settings.masks.first(where: { $0.id == id }), editor.isVisibleNow(start: m.start, end: m.end) else { return nil }
            return (g.view(CGRect(x: m.x, y: m.y, width: m.width, height: m.height)), "Maske")
        case .image(let id):
            guard let o = editor.settings.images.first(where: { $0.id == id }), editor.isVisibleNow(image: o),
                  let r = editor.renderer.imageFrame(o, out: out) else { return nil }
            return (toView(r), "Bild")
        case .videoOverlay(let id):
            guard let o = editor.settings.videoOverlays.first(where: { $0.id == id }), editor.isVisibleNow(videoOverlay: o) else { return nil }
            return (toView(FrameRenderer.videoOverlayFrame(o, out: out)), o.name)
        case .text(let id):
            guard let t = editor.settings.texts.first(where: { $0.id == id }), t.kind == .lowerThird,
                  editor.isVisibleNow(text: t) else { return nil }
            return (toView(editor.renderer.lowerThirdFrame(t)), "Bauchbinde")
        default:
            return nil
        }
    }
}

// MARK: - Sensitive data

final class SensitiveModel: ObservableObject {
    @Published var faces = true
    @Published var progress: Double?
    @Published var findings: [SensitiveFinding]?
    @Published var error: String?
    var task: Task<Void, Never>?
}

struct SensitiveSheet: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var m = SensitiveModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sensible Daten verpixeln").font(.title2.bold())
            Text("Sucht in der Aufnahme nach E-Mail-Adressen, Telefonnummern, IBANs, Kartennummern, API-Schlüsseln und Gesichtern – mit Apples Texterkennung direkt auf dem Mac. Gefundenes wird mit Masken verdeckt.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Auch Gesichter (z. B. in Videokonferenzen)", isOn: $m.faces)
            if let p = m.progress {
                ProgressView(value: p) { Text("Aufnahme wird durchsucht …") }
            }
            if let error = m.error { Text(error).foregroundStyle(.red) }
            if let findings = m.findings {
                if findings.isEmpty {
                    Label("Nichts gefunden.", systemImage: "checkmark.shield").foregroundStyle(.green)
                } else {
                    List {
                        ForEach(findings.indices, id: \.self) { i in
                            HStack {
                                Toggle("", isOn: Binding(get: { m.findings?[i].selected ?? false }, set: { m.findings?[i].selected = $0 }))
                                    .labelsHidden()
                                Text(findings[i].kind.label).frame(width: 120, alignment: .leading)
                                Text(findings[i].hint).monospaced().foregroundStyle(.secondary)
                                Spacer()
                                Text("\(formatTime(editor.display(findings[i].start))) – \(formatTime(editor.display(findings[i].end)))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(height: 220)
                }
            }
            HStack {
                Button("Schließen") { m.task?.cancel(); editor.showSensitiveSheet = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Suchen") { start() }.disabled(m.progress != nil)
                Button {
                    editor.addMasks(for: (m.findings ?? []).filter(\.selected))
                    editor.showSensitiveSheet = false
                } label: {
                    Text("\((m.findings ?? []).filter(\.selected).count) Masken anlegen")
                }
                .buttonStyle(.borderedProminent)
                .disabled((m.findings ?? []).filter(\.selected).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 600)
    }

    private func start() {
        m.progress = 0
        m.findings = nil
        m.error = nil
        let project = editor.project, faces = m.faces
        m.task = Task {
            do {
                let found = try await SensitiveScanner.scan(project: project, faces: faces) { p in
                    Task { @MainActor in m.progress = p }
                }
                await MainActor.run { m.findings = found; m.progress = nil }
            } catch {
                await MainActor.run { m.error = error.localizedDescription; m.progress = nil }
            }
        }
    }
}

extension EditorModel {
    /// A blur mask over each finding for the time it is on screen (one undo step).
    func addMasks(for findings: [SensitiveFinding]) {
        guard !findings.isEmpty else { return }
        commitUndoStep(); defer { commitUndoStep() }
        for f in findings {
            var mask = BlurMask(start: f.start, end: max(f.end, f.start + 0.3), x: f.rect.minX, y: f.rect.minY,
                                width: max(0.01, f.rect.width), height: max(0.01, f.rect.height))
            mask.style = f.kind == .face ? .blur : .pixelate
            settings.masks.append(mask)
        }
    }
}

// MARK: - Step-by-step guide

final class GuideModel: ObservableObject {
    @Published var title = "Anleitung"
    @Published var steps: [GuideStep] = []
    @Published var progress: Double?
    @Published var message: String?
}

struct GuideSheet: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var m = GuideModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Anleitung aus der Aufnahme").font(.title2.bold())
                Spacer()
                Button("Schließen") { editor.showGuideSheet = false }.keyboardShortcut(.cancelAction)
            }
            Text("Jeder Klick wird zu einem Schritt mit Bild. Was angeklickt wurde, erkennt der Mac im Bild; gesprochene Erklärungen kommen aus den Untertiteln.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Titel", text: $m.title).textFieldStyle(.roundedBorder).font(.title3)
            if let p = m.progress { ProgressView(value: p) { Text("Schritte werden erstellt …") } }
            if !m.steps.isEmpty {
                List {
                    ForEach($m.steps) { $step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(nsImage: NSImage(cgImage: step.image, size: NSSize(width: 160, height: 160 * CGFloat(step.image.height) / CGFloat(max(1, step.image.width)))))
                                .resizable().aspectRatio(contentMode: .fit).frame(width: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("Schritt", text: $step.title).font(.headline).textFieldStyle(.plain)
                                TextField("Erklärung", text: $step.detail, axis: .vertical).font(.callout).textFieldStyle(.plain).foregroundStyle(.secondary)
                                Text(formatTime(editor.display(step.time))).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button(role: .destructive) { m.steps.removeAll { $0.id == step.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .frame(height: 340)
            }
            if let message = m.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button(m.steps.isEmpty ? "Schritte erstellen" : "Neu erstellen") { make() }.disabled(m.progress != nil)
                Spacer()
                Button("Text kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(StepGuideMaker.text(steps: m.steps, title: m.title), forType: .string)
                    m.message = "Text kopiert."
                }
                .disabled(m.steps.isEmpty)
                Button("Als Markdown …") { exportMarkdown() }.disabled(m.steps.isEmpty)
                Button("Als PDF …") { exportPDF() }.buttonStyle(.borderedProminent).disabled(m.steps.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 720)
        .onAppear {
            m.title = editor.settings.intro?.title.isEmpty == false ? editor.settings.intro!.title : editor.project.name
            if m.steps.isEmpty { make() }
        }
    }

    private func make() {
        m.progress = 0
        let project = editor.project, settings = editor.settings
        Task {
            let steps = (try? await StepGuideMaker.make(project: project, settings: settings) { p in
                Task { @MainActor in m.progress = p }
            }) ?? []
            await MainActor.run {
                m.steps = steps
                m.progress = nil
                m.message = steps.isEmpty ? "In dieser Aufnahme wurden keine Klicks aufgezeichnet." : nil
            }
        }
    }

    private func exportPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = m.title + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try StepGuideMaker.writePDF(steps: m.steps, title: m.title, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { m.message = "PDF fehlgeschlagen: \(error.localizedDescription)" }
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = m.title
        panel.message = "Ordner für Anleitung.md und die Bilder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try StepGuideMaker.writeMarkdown(steps: m.steps, title: m.title, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url.appendingPathComponent("Anleitung.md")])
        } catch { m.message = "Export fehlgeschlagen: \(error.localizedDescription)" }
    }
}
