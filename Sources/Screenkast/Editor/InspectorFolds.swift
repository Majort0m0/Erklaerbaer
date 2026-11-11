import SwiftUI
import AppKit

/// A part of the inspector that folds: the sections of the tabs and the groups inside "Stimme
/// verbessern". Closed, its header says what is set.
enum InspectorFold: String, CaseIterable {
    // Stil
    case preset, scene, scenePosition, sceneVideo, background, frame, color, fades
    // Audio
    case mixer, master, voice, voiceRoom, voiceColor, voiceBreaths, voiceLoudness, voiceExchange, autoEdits, music, script, voiceOver, echo
    // Text
    case texts, textDesign, chapters, captions, captionStyle, captionPosition
    // Medien
    case library, media, logo

    var title: String {
        switch self {
        case .preset: return "Vorlage"
        case .scene: return "Szene"
        case .scenePosition: return "Position in der Szene"
        case .sceneVideo: return "Video im Bildschirm"
        case .background: return "Hintergrund"
        case .frame: return "Format & Rahmen"
        case .color: return "Farbkorrektur"
        case .fades: return "Ein- und Ausblenden"
        case .mixer: return "Mischpult"
        case .master: return "Gesamtlautstärke"
        case .voice: return "Stimme verbessern"
        case .voiceRoom: return "Rauschen und Hall"
        case .voiceColor: return "Stärke und Stimmfarbe"
        case .voiceBreaths: return "Atemgeräusche"
        case .voiceLoudness: return "Lautheit"
        case .voiceExchange: return "Stimme extern bearbeiten"
        case .autoEdits: return "Automatische Änderungen"
        case .music: return "Hintergrundmusik"
        case .script: return "Sprechtext"
        case .voiceOver: return "Voice-over"
        case .echo: return "Echo"
        case .texts: return "Texte"
        case .textDesign: return "Design aller Texte"
        case .chapters: return "Kapitel"
        case .captions: return "Untertitel"
        case .captionStyle: return "Untertitel-Stil"
        case .captionPosition: return "Position der Untertitel"
        case .library: return "Bibliothek"
        case .media: return "Bilder & Videos"
        case .logo: return "Logo / Wasserzeichen"
        }
    }

    /// What nearly every video needs is open; the rest takes no room until it is needed.
    var defaultOpen: Bool {
        switch self {
        case .preset, .background, .frame, .mixer, .voice, .voiceRoom, .autoEdits, .voiceOver,
             .texts, .captions, .library, .media:
            return true
        case .scene, .scenePosition, .sceneVideo, .color, .fades, .master, .voiceColor, .voiceBreaths, .voiceLoudness,
             .voiceExchange, .music, .script, .echo, .textDesign, .chapters, .captionStyle, .captionPosition, .logo:
            return false
        }
    }

    /// Folds of the same tab (⌥-click opens or closes all of them).
    var tab: InspectorTab {
        switch self {
        case .preset, .scene, .scenePosition, .sceneVideo, .background, .frame, .color, .fades: return .style
        case .mixer, .master, .voice, .voiceRoom, .voiceColor, .voiceBreaths, .voiceLoudness, .voiceExchange, .autoEdits,
             .music, .script, .voiceOver, .echo: return .audio
        case .texts, .textDesign, .chapters, .captions, .captionStyle, .captionPosition: return .text
        case .library, .media, .logo: return .media
        }
    }

    var defaultsKey: String { "inspector.open." + rawValue }
}

/// Which parts of the inspector are open, for the whole app (kept in the settings).
@MainActor
final class InspectorFolds: ObservableObject {
    static let shared = InspectorFolds(defaults: .standard)

    @Published private(set) var open: Set<InspectorFold>
    /// nil: only in memory (self-tests and pictures must not change the user's settings).
    private var defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        open = Set(InspectorFold.allCases.filter { fold in
            (defaults?.object(forKey: fold.defaultsKey) as? Bool) ?? fold.defaultOpen
        })
    }

    func isOpen(_ fold: InspectorFold) -> Bool { open.contains(fold) }

    func set(_ fold: InspectorFold, open isOpen: Bool) {
        if isOpen { open.insert(fold) } else { open.remove(fold) }
        defaults?.set(isOpen, forKey: fold.defaultsKey)
    }

    /// A click on a header; with ⌥ all parts of its tab follow.
    func toggle(_ fold: InspectorFold, all: Bool = false) {
        let now = !isOpen(fold)
        for f in all ? InspectorFold.allCases.filter({ $0.tab == fold.tab }) : [fold] { set(f, open: now) }
    }

    /// Back to how the inspector looks the first time.
    func restoreDefaults() {
        open = Set(InspectorFold.allCases.filter(\.defaultOpen))
        for fold in InspectorFold.allCases { defaults?.removeObject(forKey: fold.defaultsKey) }
    }

    /// Self-tests and pictures: these parts open, nothing written to the settings.
    func keepInMemory(open parts: Set<InspectorFold>) {
        defaults = nil
        open = parts
    }
}

/// The row that folds a part: chevron, title and, while closed, what is set.
private struct FoldHeader: View {
    let fold: InspectorFold
    let summary: String
    /// Groups inside a section: smaller title, the summary on a line of its own.
    let stacked: Bool
    @ObservedObject var folds: InspectorFolds

    var body: some View {
        let isOpen = folds.isOpen(fold)
        Button {
            folds.toggle(fold, all: NSEvent.modifierFlags.contains(.option))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12)
                if stacked {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(fold.title).fontWeight(.medium).lineLimit(1)
                        if !isOpen, !summary.isEmpty { summaryText }
                    }
                    Spacer(minLength: 0)
                } else {
                    Text(fold.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    if !isOpen { summaryText }
                }
            }
            .frame(minHeight: stacked ? nil : 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Zuklappen (⌥-Klick: alle Bereiche des Tabs)" : "Aufklappen (⌥-Klick: alle Bereiche des Tabs)")
        .accessibilityLabel(fold.title)
        .accessibilityValue((isOpen ? "aufgeklappt" : "zugeklappt") + (summary.isEmpty ? "" : ", " + summary))
    }

    private var summaryText: some View {
        Text(summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// A section of the inspector with a fold in its header.
struct FoldSection<Content: View>: View {
    let fold: InspectorFold
    let summary: String
    @ViewBuilder let content: () -> Content
    @ObservedObject private var folds = InspectorFolds.shared

    init(_ fold: InspectorFold, summary: String, @ViewBuilder content: @escaping () -> Content) {
        self.fold = fold
        self.summary = summary
        self.content = content
    }

    var body: some View {
        Section {
            if folds.isOpen(fold) { content() }
        } header: {
            FoldHeader(fold: fold, summary: summary, stacked: false, folds: folds)
        }
    }
}

/// A group of rows inside a section.
struct FoldGroup<Content: View>: View {
    let fold: InspectorFold
    let summary: String
    @ViewBuilder let content: () -> Content
    @ObservedObject private var folds = InspectorFolds.shared

    init(_ fold: InspectorFold, summary: String, @ViewBuilder content: @escaping () -> Content) {
        self.fold = fold
        self.summary = summary
        self.content = content
    }

    var body: some View {
        FoldHeader(fold: fold, summary: summary, stacked: true, folds: folds)
        if folds.isOpen(fold) { content() }
    }
}

// MARK: - Summaries

extension EditorModel {
    /// What a closed part says about its settings: real values, or "aus" / "keine".
    func foldSummary(_ fold: InspectorFold) -> String {
        let s = settings
        func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
        func join(_ parts: [String?], empty: String = "aus") -> String {
            let list = parts.compactMap { $0 }
            return list.isEmpty ? empty : list.joined(separator: " · ")
        }
        func count(_ n: Int, _ one: String, _ many: String, none: String = "keine") -> String {
            n == 0 ? none : n == 1 ? "1 \(one)" : "\(n) \(many)"
        }
        func seconds(_ t: Double) -> String { String(format: "%.1f s", t).replacingOccurrences(of: ".", with: ",") }
        func lufs(_ v: Double) -> String { "\(Int(v))".replacingOccurrences(of: "-", with: "−") + " LUFS" }
        let voice = s.voice
        switch fold {
        case .preset:
            return ""
        case .scene:
            return s.mockup?.label ?? "ohne"
        case .scenePosition:
            let p = s.mockupPlacement
            return p == MockupPlacement() ? "Standard" : "verschoben"
        case .sceneVideo:
            let p = s.mockupPlacement
            return p.videoScale > 1.001 ? String(format: "%.1f× vergrößert", p.videoScale).replacingOccurrences(of: ".", with: ",") : "ganz"
        case .background:
            let name: String
            switch s.background {
            case .gradient(let i): name = Backgrounds.presets.indices.contains(i) ? Backgrounds.presets[i].name : "Verlauf"
            case .color: name = "Farbe"
            case .image: name = "Bild"
            }
            return join([name, s.backgroundBlur > 0.01 ? "unscharf" : nil])
        case .frame:
            return join([s.aspect.rawValue, s.cornerRadius > 0.5 ? "Ecken \(Int(s.cornerRadius))" : nil,
                         s.shadow > 0.01 ? "Schatten \(percent(s.shadow))" : nil])
        case .color:
            let g = s.color
            if g.isNeutral { return "neutral" }
            let preset = ColorGrade.presets.first { p in
                abs(g.exposure - p.exposure) < 0.01 && abs(g.contrast - p.contrast) < 0.01 && abs(g.saturation - p.saturation) < 0.01
                    && abs(g.temperature - p.temperature) < 0.01 && abs(g.vibrance - p.vibrance) < 0.01
            }
            return preset?.name ?? "angepasst"
        case .fades:
            return join([s.fadeIn >= 0.05 ? "Anfang \(seconds(s.fadeIn))" : nil, s.fadeOut >= 0.05 ? "Ende \(seconds(s.fadeOut))" : nil])
        case .mixer:
            var parts: [String] = []
            if project.info.hasMicAudio { parts.append("Mikrofon " + (s.micMuted ? "stumm" : percent(s.micVolume))) }
            if project.info.hasSystemAudio { parts.append("System " + (s.systemMuted ? "stumm" : percent(s.systemVolume))) }
            if let music = s.music { parts.append("Musik " + (music.muted ? "stumm" : percent(music.volume))) }
            return join(parts, empty: "")
        case .master:
            return s.masterNormalize ? lufs(s.masterTargetLUFS) : "aus"
        case .voice:
            guard voice.enabled else { return "aus" }
            return join([voice.noiseReduction > 0.01 ? "Rauschen \(percent(voice.noiseReduction))" : nil,
                         voice.reverbReduction > 0.01 ? "Hall \(percent(voice.reverbReduction))" : nil,
                         voice.narration > 0.01 ? "Erzähler" : nil,
                         voice.reducesBreaths ? "Atem" : nil,
                         voice.normalize ? lufs(voice.targetLUFS) : nil], empty: "an")
        case .voiceRoom:
            return join([voice.noiseReduction > 0.01 ? "Rauschen \(percent(voice.noiseReduction))" : nil,
                         voice.reverbReduction > 0.01 ? "Hall \(percent(voice.reverbReduction))" : nil])
        case .voiceColor:
            return join(["Stärke \(percent(voice.strength))", voice.narration > 0.01 ? "Erzähler \(percent(voice.narration))" : "neutral"])
        case .voiceBreaths:
            guard voice.reducesBreaths else { return "aus" }
            return join(["−\(Int(voice.breathDB)) dB", count(breathRegions.count, "Stelle", "Stellen")])
        case .voiceLoudness:
            return voice.normalize ? lufs(voice.targetLUFS) : "aus"
        case .voiceExchange:
            return s.importedVoice?.name ?? "Original"
        case .autoEdits:
            let n = automaticCuts(.filler).count + automaticCuts(.pause).count + automaticCuts(.transcript).count + breathRegions.count
            return count(n, "Änderung", "Änderungen")
        case .music:
            return s.music?.name ?? "keine"
        case .script:
            let words = (s.script ?? "").split(whereSeparator: \.isWhitespace).count
            return count(words, "Wort", "Wörter", none: "leer")
        case .voiceOver:
            return count(s.voiceOvers.filter { !$0.isMusic }.count, "Aufnahme", "Aufnahmen")
        case .echo:
            return s.removeEcho ? "wird entfernt" : "aus"
        case .texts:
            return count(s.texts.count, "Text", "Texte")
        case .textDesign:
            return s.textDesign?.name ?? "Standard"
        case .chapters:
            return count(s.chapters.count, "Kapitel", "Kapitel")
        case .captions:
            guard !s.captions.isEmpty else { return "keine" }
            return join([count(s.captions.count, "Zeile", "Zeilen"), s.showCaptions ? nil : "ausgeblendet",
                         s.captionsFrom.map { "ab \(formatTime($0))" }])
        case .captionStyle:
            return s.captionStyle.mode.label
        case .captionPosition:
            let y = s.captionStyle.y
            return y > 0.75 ? "unten" : y < 0.25 ? "oben" : "Mitte"
        case .library:
            return count(mediaLibrary.count, "Datei", "Dateien", none: "leer")
        case .media:
            return count(s.images.count + s.videoOverlays.count + s.inserts.count, "Element", "Elemente")
        case .logo:
            return s.watermark == nil ? "keins" : "an"
        }
    }
}
