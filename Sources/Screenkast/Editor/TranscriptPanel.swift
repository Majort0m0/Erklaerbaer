import SwiftUI
import AppKit

/// "Skript" page of the inspector: remove pauses and filler words, cut by deleting words.
struct TranscriptPanel: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        let pauses = editor.detectedPauses
        let saved = pauses.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        Section("Pausen entfernen") {
            LabeledSlider(title: "Pausen ab", value: $editor.pauseOptions.minPause, range: 0.3...3,
                          format: { String(format: "%.1f s", $0) })
            LabeledSlider(title: "Davon behalten", value: $editor.pauseOptions.keep, range: 0...1,
                          format: { String(format: "%.1f s", $0) })
            LabeledSlider(title: "Empfindlichkeit", value: $editor.pauseOptions.sensitivity, range: 0...1,
                          format: { "\(Int($0 * 100)) %" })
            HStack {
                Text(pauses.isEmpty ? "Keine Pausen gefunden" : String(format: "%d Pausen · %.1f s kürzer", pauses.count, saved))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Schneiden") { editor.removePauses() }
                    .disabled(pauses.isEmpty)
            }
            Text("Findet stille Stellen im Mikrofon. Einzelne Schnitte lassen sich danach in der Timeline anpassen oder mit ⌘Z zurücknehmen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if editor.settings.words.isEmpty {
            Section("Transkript") {
                Text("Erkennt die gesprochenen Wörter (auf dem Mac, nichts wird hochgeladen). Danach lässt sich das Video schneiden, indem man Wörter löscht.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Picker("Sprache", selection: $editor.settings.captionLanguage) {
                        Text("Deutsch").tag("de-DE")
                        Text("Englisch").tag("en-US")
                        Text("Französisch").tag("fr-FR")
                        Text("Spanisch").tag("es-ES")
                        Text("Italienisch").tag("it-IT")
                    }
                    .labelsHidden()
                    Button("Transkript erstellen") { editor.generateCaptions() }
                        .disabled(editor.isGeneratingCaptions)
                }
                if editor.isGeneratingCaptions {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(editor.captionStatus ?? "") }.font(.caption)
                }
                if let error = editor.captionError { Text(error).font(.caption).foregroundStyle(.red) }
            }
        } else {
            let fillers = editor.fillerWordIndices
            Section("Füllwörter") {
                HStack {
                    Text(fillers.isEmpty ? "Keine gefunden" : "\(fillers.count) Füllwörter und Wiederholungen")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Entfernen") { editor.removeFillerWords() }
                        .disabled(fillers.isEmpty)
                }
                Text("„äh“, „ähm“ … und doppelte Wörter. Die Spracherkennung schreibt nicht jedes „äh“ mit – Pausen entfernen hilft zusätzlich.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Transkript") {
                selectionBar
                WordFlow(editor: editor, fillers: Set(fillers))
                Text("Wort anklicken springt dorthin, ⇧-Klick wählt bis dorthin aus. ⌫ schneidet die Auswahl heraus. Durchgestrichene Wörter sind entfernt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if let r = editor.transcriptSelection {
            let removed = r.allSatisfy { editor.isWordRemoved($0) }
            HStack {
                Text("\(r.count) \(r.count == 1 ? "Wort" : "Wörter") ausgewählt").foregroundStyle(.secondary)
                Spacer()
                if removed {
                    Button("Wiederherstellen") { editor.restoreWords(r) }
                } else {
                    Button("Herausschneiden (⌫)") { editor.cutWords(r) }
                }
                Button { editor.transcriptSelection = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
            }
        }
    }
}

/// The words, wrapped like text; each one can be clicked.
private struct WordFlow: View {
    @ObservedObject var editor: EditorModel
    let fillers: Set<Int>

    var body: some View {
        let current = editor.currentWordIndex
        let selection = editor.transcriptSelection
        FlowLayout(spacing: 2, lineSpacing: 3) {
            ForEach(Array(editor.settings.words.enumerated()), id: \.offset) { i, word in
                let removed = editor.isWordRemoved(i)
                let selected = selection?.contains(i) ?? false
                Text(word.text.trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 12.5))
                    .strikethrough(removed)
                    .foregroundStyle(removed ? Color.secondary.opacity(0.6) : fillers.contains(i) ? Color.orange : Color.primary)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(selected ? Theme.brand.opacity(0.35) : i == current ? Color.yellow.opacity(0.3) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { tap(i) }
            }
        }
    }

    private func tap(_ i: Int) {
        editor.selection = nil
        if NSEvent.modifierFlags.contains(.shift), let r = editor.transcriptSelection {
            editor.transcriptSelection = min(r.lowerBound, i)...max(r.upperBound, i)
        } else {
            editor.transcriptSelection = i...i
            if editor.isPlaying { editor.pause() }
            editor.seek(to: editor.settings.words[i].start)
        }
    }
}

/// Lays out views left to right, wrapping into lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x)
            lineHeight = max(lineHeight, size.height)
        }
        return (positions, CGSize(width: min(width, maxX), height: y + lineHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? 260).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrange(subviews, width: bounds.width).positions
        for (view, p) in zip(subviews, positions) {
            view.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }
}
