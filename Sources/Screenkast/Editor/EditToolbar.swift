import SwiftUI

/// Every editing tool in one row directly above the timeline. Each one also has a key,
/// named in its tooltip. Scrolls sideways in narrow windows.
struct EditToolbar: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                tool("arrow.uturn.backward", "Widerrufen (⌘Z)", .undo).disabled(!editor.canUndo)
                tool("arrow.uturn.forward", "Wiederholen (⇧⌘Z)", .redo).disabled(!editor.canRedo)
                divider
                tool("scissors", "Am Abspielkopf teilen (S)", .split)
                Button { editor.perform(.join) } label: { icon("arrow.triangle.merge").rotationEffect(.degrees(90)) }
                    .help("Geteilte Clips wieder verbinden (⇧S) – den ausgewählten mit seinem Nachbarn, mehrere ausgewählte oder den Teil am Abspielkopf")
                    .disabled(editor.joinPlan.isEmpty)
                Button { editor.deleteSelection() } label: { icon("trash") }
                    .help("Auswahl löschen (⌫)")
                    .disabled(editor.selection == nil)
                tool("doc.on.doc", "Auswahl kopieren (⌘C)", .copy).disabled(editor.selection == nil)
                tool("doc.on.clipboard", "Am Abspielkopf einfügen (⌘V)", .paste).disabled(editor.clipboard.isEmpty)
                tool("arrow.right.to.line", "Anfang hierher kürzen (Q)", .trimStart)
                tool("arrow.left.to.line", "Ende hierher kürzen (W)", .trimEnd)
                tool("snowflake", "Standbild einfügen (⌥F)", .freeze)
                tool("circle.lefthalf.filled", "Überblendung an der ausgewählten oder nächsten Schnittstelle (⌘T)", .transition)
                tempo
                divider
                tool("plus.magnifyingglass", "Zoom am Abspielkopf (Z)", .addZoom)
                tool("textformat", "Text einblenden (T)", .addText)
                tool("square.grid.3x3", "Maske zum Verpixeln (X)", .addMask)
                tool(AnnotationKind.arrow.icon, "Pfeil (A)", .addArrow)
                tool(AnnotationKind.frame.icon, "Rahmen (R)", .addFrame)
                tool(AnnotationKind.spotlight.icon, "Spotlight (P)", .addSpotlight)
                tool(AnnotationKind.touch.icon, "Finger-Geste für iPad-Videos: Tippen, Halten, Ziehen, Pinch … (F)", .addFinger)
                tool(AnnotationKind.step.icon, "Nummerierter Schritt, zählt von selbst weiter (B)", .addStep)
                tool("cursorarrow.rays", "Mauszeiger-Bereich (C)", .addCursor)
                tool("photo", "Bild hinzufügen (I)", .addImage)
                tool("pip", "Video als Bild im Bild (O)", .addVideo)
                tool("bookmark", "Kapitelmarke (M)", .chapter)
                Button { editor.showMemeBoard.toggle() } label: { icon("face.smiling") }
                    .help("Meme-Board (E) – Tasten 1 bis 0 setzen die Memes am Abspielkopf ein")
                    .popover(isPresented: $editor.showMemeBoard, arrowEdge: .top) {
                        MemeBoardView { editor.addMeme($0) }
                            .padding(12)
                            .frame(width: 380)
                    }
                voiceOver
                divider
                toggle("arrow.right.and.line.vertical.and.arrow.left", on: editor.snapping,
                       editor.snapping ? "Einrasten an (N) – Kanten rasten am Abspielkopf und an anderen Clips ein" : "Einrasten aus (N)", .toggleSnapping)
                toggle("rectangle.split.2x1", on: editor.magnet,
                       editor.magnet ? "Zusammenkleben an (G) – Clips einer Spur haften an ihren Enden aneinander; weiter geschoben blenden sie über" : "Zusammenkleben aus (G)", .toggleMagnet)
                Button { editor.trimMode = editor.trimMode == .roll ? .normal : .roll } label: { icon("arrow.left.and.right.righttriangle.left.righttriangle.right.fill") }
                    .buttonStyle(GhostButtonStyle(active: editor.trimMode == .roll))
                    .help(editor.trimMode == .roll ? "Rollen an: Kante eines Teils ziehen verschiebt den Schnitt, die Länge bleibt gleich (Y)" : "Rollen (Y)")
                Button { editor.trimMode = editor.trimMode == .slip ? .normal : .slip } label: { icon("arrow.left.and.right.square.fill") }
                    .buttonStyle(GhostButtonStyle(active: editor.trimMode == .slip))
                    .help(editor.trimMode == .slip ? "Slip an: Teil ziehen zeigt einen früheren oder späteren Ausschnitt an derselben Stelle (Y)" : "Slip (Y)")
                tool("text.line.last.and.arrowtriangle.forward", "Alles rechts vom Abspielkopf auswählen (⇧⌘→)", .selectRight)
                tool("arrow.left.and.right.square", "Ganze Timeline zeigen (⇧Z)", .zoomFit)
                Button { editor.showShortcutHelp.toggle() } label: { icon("keyboard") }
                    .help("Alle Tastenkürzel")
                    .popover(isPresented: $editor.showShortcutHelp, arrowEdge: .top) { ShortcutHelp() }
            }
            .padding(.horizontal, 2)
        }
        .buttonStyle(GhostButtonStyle())
        .controlSize(.regular)
        .disabled(editor.voiceOverState == .saving)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .medium))
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
    }

    private func tool(_ name: String, _ help: String, _ command: EditorKeyCommand) -> some View {
        Button { editor.perform(command) } label: { icon(name) }.help(help)
    }

    private func toggle(_ name: String, on: Bool, _ help: String, _ command: EditorKeyCommand) -> some View {
        Button { editor.perform(command) } label: { icon(name) }
            .buttonStyle(GhostButtonStyle(active: on))
            .help(help)
    }

    private var divider: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 18).padding(.horizontal, 6)
    }

    private var tempo: some View {
        Menu {
            ForEach(EditorModel.tempoSteps, id: \.self) { rate in
                Button(rate == 1 ? "Normal" : "\(rate.formatted(.number.locale(Locale(identifier: "de_DE"))))×") { editor.setTempo(rate) }
            }
        } label: {
            icon("speedometer")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Tempo des ausgewählten Teils oder des Teils am Abspielkopf (⌥↑ schneller, ⌥↓ langsamer)")
        .disabled(editor.partForTempo == nil)
    }

    private var voiceOver: some View {
        Button { editor.perform(.voiceOver) } label: {
            switch editor.voiceOverState {
            case .idle, .saving: icon("mic")
            case .countdown: icon("xmark.circle")
            case .recording: icon("stop.circle.fill").foregroundStyle(.red)
            }
        }
        .help("Voice-over einsprechen ab dem Abspielkopf (V)")
    }
}
