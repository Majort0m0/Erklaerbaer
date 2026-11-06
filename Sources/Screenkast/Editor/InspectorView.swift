import SwiftUI
import UniformTypeIdentifiers

/// Right sidebar. Without a selection: settings pages behind icon tabs. With a selection: the
/// settings of the selected item, with a header to delete it or go back.
struct InspectorView: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let info = selectionInfo {
                selectionHeader(info)
                Divider()
                Form { selectionContent }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            } else {
                Form { tabContent }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: Tabs

    private var tabs: [InspectorTab] {
        InspectorTab.allCases.filter { $0 != .camera || editor.hasCamera }
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let active = editor.selection == nil && editor.inspectorTab == tab
                Button {
                    editor.selection = nil
                    editor.inspectorTab = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 15))
                            .frame(height: 18)
                        Text(tab.title).font(.system(size: 9.5, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(active ? Theme.brand : Color.secondary)
                    .background(active ? Theme.brand.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.help)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch editor.inspectorTab {
        case .style:
            presetSection
            backgroundSection
            frameSection
            ColorGradeSection(editor: editor)
            fadeSection
        case .camera:
            if editor.hasCamera { cameraSection; cameraLayoutHint } else { backgroundSection }
        case .cursor:
            cursorSection
        case .zoom:
            zoomSection
        case .audio:
            MixerSection(editor: editor)
            voiceEnhancementSection
            AutoEditsSection(editor: editor)
            musicSection
            voiceOverSection
            if editor.canRemoveEcho { echoSection }
        case .text:
            textsSection
            textDesignDefaultsSection
            chaptersSection
            captionSection
            if !editor.settings.captions.isEmpty { CaptionStyleSection(editor: editor) }
        case .media:
            imagesSection
            logoSection
        case .transcript:
            AutoEditsSection(editor: editor)
            TranscriptPanel(editor: editor)
        }
    }

    // MARK: Selection

    private struct SelectionInfo {
        let icon: String
        let title: String
        let subtitle: String
        let delete: String
    }

    private var selectionInfo: SelectionInfo? {
        switch editor.selection {
        case .zoom:
            guard let i = editor.selectedZoomIndex else { return nil }
            let z = editor.settings.zoomSegments[i]
            return SelectionInfo(icon: "plus.magnifyingglass", title: "Zoom", subtitle: shown(z.start, z.end), delete: "Zoom löschen")
        case .cut:
            guard let c = editor.selectedCut else { return nil }
            return SelectionInfo(icon: "scissors", title: "Entfernter Bereich", subtitle: shown(c.start, c.end), delete: "Wiederherstellen")
        case .mask:
            guard let m = editor.selectedMask else { return nil }
            return SelectionInfo(icon: "square.grid.3x3", title: "Maske", subtitle: shown(m.start, m.end), delete: "Maske löschen")
        case .mute:
            guard let m = editor.selectedMute else { return nil }
            return SelectionInfo(icon: m.isMute ? "speaker.slash" : "speaker.wave.1", title: (m.isMute ? "Stumm: " : "Leiser: ") + m.lane.label,
                                 subtitle: shown(m.start, m.end), delete: "Bereich entfernen")
        case .voiceOver:
            guard let c = editor.selectedVoiceOver else { return nil }
            let r = editor.displayRange(c)
            return SelectionInfo(icon: "waveform", title: "Voice-over", subtitle: Self.range(r.lowerBound, r.upperBound), delete: "Clip löschen")
        case .text:
            guard let t = editor.selectedText else { return nil }
            let title = t.kind == .lowerThird ? "Bauchbinde" : t.placement == .overlay ? "Titelkarte" : t.placement.label
            let subtitle = t.kind == .titleCard && t.placement != .overlay ? String(format: "%.1f s", t.length) : shown(t.start, t.end)
            return SelectionInfo(icon: t.kind == .lowerThird ? "text.below.photo" : "rectangle.inset.filled", title: title,
                                 subtitle: subtitle, delete: "\(title) löschen")
        case .segment:
            guard let seg = editor.selectedSegment else { return nil }
            let a = editor.display(seg.lowerBound), b = editor.display(seg.upperBound)
            return SelectionInfo(icon: "film", title: "Teil der Aufnahme", subtitle: Self.range(a, b), delete: "Teil entfernen")
        case .freeze:
            guard let f = editor.selectedFreeze else { return nil }
            return SelectionInfo(icon: "snowflake", title: "Standbild",
                                 subtitle: String(format: "%.1f s · bei %@", f.duration, formatTime(editor.display(f.at))),
                                 delete: "Standbild entfernen")
        case .cameraLayout:
            guard let r = editor.selectedCameraLayout else { return nil }
            return SelectionInfo(icon: r.layout.icon, title: "Kamera: \(r.layout.label)", subtitle: shown(r.start, r.end), delete: "Layout entfernen")
        case .annotation:
            guard let a = editor.selectedAnnotation else { return nil }
            return SelectionInfo(icon: a.kind.icon, title: a.kind.label, subtitle: shown(a.start, a.end), delete: "\(a.kind.label) löschen")
        case .image:
            guard let o = editor.selectedImage else { return nil }
            return SelectionInfo(icon: "photo", title: "Bild", subtitle: shown(o.start, o.end), delete: "Bild entfernen")
        case .insert:
            guard let c = editor.selectedInsert else { return nil }
            return SelectionInfo(icon: "film.stack", title: c.name, subtitle: String(format: "%.1f s · bei %@", c.duration, formatTime(editor.display(c.at))),
                                 delete: "Clip entfernen")
        case .chapter:
            guard let c = editor.selectedChapter else { return nil }
            return SelectionInfo(icon: "bookmark.fill", title: "Kapitel", subtitle: editor.outputTime(ofSource: c.time).map { formatTime($0) } ?? "herausgeschnitten",
                                 delete: "Kapitel löschen")
        case .panel(let panel):
            return SelectionInfo(icon: panel.icon, title: panel.title, subtitle: "Einstellungen", delete: "")
        case .cursorRange:
            guard let r = editor.selectedCursorRange else { return nil }
            return SelectionInfo(icon: r.effect.icon, title: "Cursor: \(r.effect.label)", subtitle: shown(r.start, r.end), delete: "Bereich löschen")
        case .audioLane(let lane):
            return SelectionInfo(icon: lane.icon, title: "Spur: \(lane.label)", subtitle: editor.isMuted(lane) ? "stumm" : "\(Int(editor.volume(of: lane) * 100)) %",
                                 delete: "")
        case .videoOverlay:
            guard let o = editor.selectedVideoOverlay else { return nil }
            let a = editor.display(o.start)
            return SelectionInfo(icon: o.synced ? "macwindow.on.rectangle" : "pip", title: o.name, subtitle: Self.range(a, a + o.duration),
                                 delete: "Video entfernen")
        case nil:
            return nil
        }
    }

    /// A source range as shown on the timeline.
    private func shown(_ a: Double, _ b: Double) -> String { Self.range(editor.display(a), editor.display(b)) }

    static func range(_ a: Double, _ b: Double) -> String {
        "\(formatTime(a)) – \(formatTime(b)) · \(String(format: "%.1f s", b - a))"
    }

    private func selectionHeader(_ info: SelectionInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: info.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 30, height: 30)
                .background(Theme.brand.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(info.title).font(.headline).lineLimit(1)
                Text(info.subtitle).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !info.delete.isEmpty {
                Button {
                    editor.deleteSelection()
                } label: {
                    Image(systemName: editor.selectedCut != nil ? "arrow.uturn.backward.circle" : "trash")
                }
                .buttonStyle(.borderless)
                .help("\(info.delete) (⌫)")
            }
            Button {
                editor.selection = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Auswahl aufheben (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var selectionContent: some View {
        switch editor.selection {
        case .zoom: selectedZoomSection
        case .cut: if let cut = editor.selectedCut { cutSection(cut) }
        case .mask: maskSection
        case .mute: muteSection
        case .voiceOver: if let clip = editor.selectedVoiceOver { voiceOverClipSection(clip) }
        case .text: if let text = editor.selectedText { textEditSection(text) }
        case .segment: if let seg = editor.selectedSegment { segmentSection(seg) }
        case .freeze: if let freeze = editor.selectedFreeze { freezeSection(freeze) }
        case .cameraLayout: if let r = editor.selectedCameraLayout { cameraLayoutSection(r) }
        case .annotation: if let a = editor.selectedAnnotation { annotationSection(a) }
        case .image: if let o = editor.selectedImage { imageSection(o) }
        case .insert: if let c = editor.selectedInsert { insertSection(c) }
        case .chapter: if let c = editor.selectedChapter { chapterSection(c) }
        case .videoOverlay: if let o = editor.selectedVideoOverlay { VideoOverlaySection(editor: editor, overlay: o) }
        case .audioLane(let lane): AudioLaneSection(editor: editor, lane: lane)
        case .panel(let panel): panelContent(panel)
        case .cursorRange: if let r = editor.selectedCursorRange { cursorRangeSection(r) }
        case nil: EmptyView()
        }
    }

    private func segmentSection(_ segment: ClosedRange<Double>) -> some View {
        let speed = editor.speed(of: segment)
        return Group {
            Section("Geschwindigkeit") {
                Picker("Geschwindigkeit", selection: Binding(get: { speed.flatMap { s in EditorModel.speedPresets.first { abs($0 - s) < 1e-6 } } ?? -1 },
                                                         set: { if $0 > 0 { editor.setSpeed($0, for: segment) } })) {
                    ForEach(EditorModel.speedPresets, id: \.self) { rate in
                        Text(Self.speedLabel(rate)).tag(rate)
                    }
                    if speed.map({ s in !EditorModel.speedPresets.contains { abs($0 - s) < 1e-6 } }) ?? true {
                        Text(speed.map(Self.speedLabel) ?? "gemischt").tag(-1.0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                LabeledSlider(title: "Feinregler", value: Binding(get: { log2(speed ?? 1) }, set: { editor.setSpeed(pow(2, $0), for: segment) }),
                              range: -2...3, format: { Self.speedLabel(pow(2, $0)) })
                Text(Self.lengthText(editor, segment))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Standbild") {
                Button {
                    editor.insertFreeze()
                } label: {
                    Label("Letztes Bild anhalten (⌥F)", systemImage: "snowflake")
                }
                Text("Hält das letzte Bild dieses Teils an – Zeit, um etwas zu erklären. Die Länge lässt sich in der Timeline an der Kante ziehen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            partActions(segment)
        }
    }

    static func speedLabel(_ rate: Double) -> String {
        let r = (rate * 100).rounded() / 100
        return r == r.rounded() ? String(format: "%.0f×", r) : String(format: "%g×", r)
    }

    private static func lengthText(_ editor: EditorModel, _ segment: ClosedRange<Double>) -> String {
        let source = segment.upperBound - segment.lowerBound
        let shown = editor.display(segment.upperBound) - editor.display(segment.lowerBound)
        return abs(source - shown) < 0.05 ? String(format: "Dauer %.1f s", shown)
            : String(format: "Aufnahme %.1f s → im Video %.1f s", source, shown)
    }

    private func partActions(_ segment: ClosedRange<Double>) -> some View {
        Section {
            Button(role: .destructive) {
                editor.removeSegment(segment)
            } label: {
                Label("Teil entfernen", systemImage: "trash")
            }
            .disabled(editor.isRemoved(segment))
            if segment.upperBound < editor.duration - 0.01 {
                Button {
                    editor.joinWithNext(segment)
                } label: {
                    Label("Mit dem nächsten Teil verbinden", systemImage: "arrow.triangle.merge")
                }
            }
            Text("Entfernte Teile werden beim Abspielen und im Export übersprungen. Teilen: Abspielkopf setzen und S drücken.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func freezeSection(_ freeze: FreezeFrame) -> some View {
        Section {
            LabeledSlider(title: "Dauer", value: Binding(get: { freeze.duration }, set: { editor.setFreezeDuration(id: freeze.id, $0) }),
                          range: 0.2...20, format: { String(format: "%.1f s", $0) })
            Text("Das Bild steht still, Cursor und Zoom halten an. Ein Voice-over oder eine Bauchbinde darüber erklärt, was zu sehen ist. "
                 + "Die Länge lässt sich auch an der rechten Kante in der Timeline ziehen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: New items

    private func cameraLayoutSection(_ r: CameraLayoutRange) -> some View {
        Section {
            Picker("Kamera", selection: Binding(get: { r.layout }, set: { v in editor.updateCameraLayout(id: r.id) { $0.layout = v } })) {
                ForEach(CameraLayout.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.inline)
            Text("Gilt für diesen Bereich; an den Rändern blendet die Kamera weich über. Länge in der Kamera-Spur ziehen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cameraLayoutHint: some View {
        Section("Layouts") {
            Text("In der Kamera-Spur der Timeline an eine Stelle klicken: dort wird die Kamera groß, bildschirmfüllend oder ausgeblendet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                editor.addCameraLayout(start: min(max(0, editor.currentTime), editor.duration))
            } label: {
                Label("Layout am Abspielkopf", systemImage: "plus")
            }
        }
    }

    private func annotationSection(_ a: Annotation) -> some View {
        Section {
            Picker("Art", selection: Binding(get: { a.kind }, set: { v in editor.updateAnnotation(id: a.id) { $0.kind = v } })) {
                ForEach(AnnotationKind.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
            if a.kind != .spotlight {
                HStack(spacing: 8) {
                    Text("Farbe")
                    Spacer()
                    ForEach(AnnotationColor.allCases) { c in
                        let (r, g, b) = c.rgb
                        Circle()
                            .fill(Color(red: r, green: g, blue: b))
                            .overlay(Circle().strokeBorder(a.color == c ? Theme.brand : Color.secondary.opacity(0.4), lineWidth: a.color == c ? 2.5 : 1))
                            .frame(width: 18, height: 18)
                            .onTapGesture { editor.updateAnnotation(id: a.id) { $0.color = c } }
                    }
                }
                LabeledSlider(title: "Linienstärke", value: Binding(get: { a.thickness }, set: { v in editor.updateAnnotation(id: a.id) { $0.thickness = v } }),
                              range: 0.4...3, format: { "\(Int($0 * 100)) %" })
            }
            if a.kind != .arrow {
                Picker("Form", selection: Binding(get: { a.outline }, set: { v in editor.updateAnnotation(id: a.id) { $0.shape = v } })) {
                    ForEach(AnnotationShape.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Text(a.kind == .arrow ? "Im Vorschaubild Anfang und Spitze ziehen, an der Linie verschieben." : "Im Vorschaubild verschieben, an den Ecken die Größe ändern.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func imageSection(_ o: ImageOverlay) -> some View {
        Section {
            LabeledSlider(title: "Größe", value: Binding(get: { o.width }, set: { v in editor.updateImage(id: o.id) { $0.width = v } }),
                          range: 0.05...1, format: { "\(Int($0 * 100)) %" })
            LabeledSlider(title: "Deckkraft", value: Binding(get: { o.opacity }, set: { v in editor.updateImage(id: o.id) { $0.opacity = v } }),
                          range: 0.05...1, format: { "\(Int($0 * 100)) %" })
            PictureStyleRows(frame: o.frame ?? .none, shadow: o.shadow ?? false,
                             setFrame: { v in editor.updateImage(id: o.id) { $0.frame = v } },
                             setShadow: { v in editor.updateImage(id: o.id) { $0.shadow = v } },
                             applyToAll: { editor.applyFrameToAllImages(o.frame ?? .none, shadow: o.shadow ?? false) })
            Text("Im Vorschaubild verschieben, an den Ecken die Größe ändern; Dauer in der Medien-Spur ziehen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func insertSection(_ c: InsertClip) -> some View {
        Section {
            LabeledSlider(title: "Lautstärke", value: Binding(get: { c.volume }, set: { v in editor.updateInsert(id: c.id) { $0.volume = v } }),
                          range: 0...1, format: { "\(Int($0 * 100)) %" })
            LabeledSlider(title: "Beginn im Clip", value: Binding(get: { c.fileOffset }, set: { v in editor.updateInsert(id: c.id) { $0.fileOffset = v } }),
                          range: 0...max(0.1, c.fileDuration - 0.2), format: { String(format: "%.1f s", $0) })
            Text("Die Aufnahme wartet, während der Clip läuft. Kürzen: rechte Kante in der Timeline ziehen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chapterSection(_ c: Chapter) -> some View {
        Section {
            TextField("Titel", text: Binding(get: { c.title }, set: { v in editor.updateChapter(id: c.id) { $0.title = v } }))
            Text("Kapitelmarken erscheinen oben in der Zeitskala; ziehen verschiebt sie. M setzt eine neue am Abspielkopf.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Templates, logo

    private var presetSection: some View {
        Section("Vorlage") {
            HStack {
                Menu {
                    ForEach(StyleLibrary.all) { preset in
                        Button(preset.name + (StyleLibrary.defaultID == preset.id ? " (Standard)" : "")) { editor.applyStyle(preset) }
                    }
                } label: {
                    Label("Stil übernehmen", systemImage: "wand.and.stars")
                }
                .fixedSize()
                Menu {
                    Button("Aktuellen Stil sichern …") { editor.saveStyle() }
                    Menu("Als Standard für neue Aufnahmen") {
                        ForEach(StyleLibrary.all) { preset in
                            Button(preset.name) { StyleLibrary.defaultID = preset.id; editor.objectWillChange.send() }
                        }
                    }
                    Menu("Gesicherten Stil löschen") {
                        ForEach(StyleLibrary.load()) { preset in
                            Button(preset.name, role: .destructive) { StyleLibrary.remove(preset.id); editor.objectWillChange.send() }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Text("Übernimmt Hintergrund, Rahmen, Cursor, Kamera, Blenden, Logo und Export-Einstellungen – Schnitte und Texte bleiben."
                 + (StyleLibrary.defaultPreset.map { " Neue Aufnahmen: „\($0.name)“." } ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var logoSection: some View {
        Section("Logo") {
            if let w = editor.settings.watermark {
                Picker("Ecke", selection: Binding(get: { w.corner }, set: { v in editor.settings.watermark?.corner = v })) {
                    ForEach(CameraCorner.allCases) { Text($0.label).tag($0) }
                }
                LabeledSlider(title: "Größe", value: Binding(get: { w.size }, set: { editor.settings.watermark?.size = $0 }),
                              range: 0.05...0.4, format: { "\(Int($0 * 100)) %" })
                LabeledSlider(title: "Deckkraft", value: Binding(get: { w.opacity }, set: { editor.settings.watermark?.opacity = $0 }),
                              range: 0.1...1, format: { "\(Int($0 * 100)) %" })
                HStack {
                    Button("Anderes Bild …") { editor.chooseWatermark() }
                    Button("Entfernen", role: .destructive) { editor.settings.watermark = nil }
                }
            } else {
                Button {
                    editor.chooseWatermark()
                } label: {
                    Label("Logo wählen …", systemImage: "seal")
                }
                Text("Erscheint in einer Ecke des ganzen Videos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Voice and music

    private var voiceEnhancementSection: some View {
        Section("Stimme verbessern") {
            Toggle("Rauschen entfernen und Lautstärke angleichen", isOn: $editor.settings.voice.enabled)
            if editor.settings.voice.enabled {
                LabeledSlider(title: "Stärke (sofort hörbar)", value: Binding(get: { editor.settings.voice.strength },
                                                                              set: { editor.settings.voice.intensity = $0 }),
                              range: 0...1, format: { $0 < 0.02 ? "nur Lautstärke" : "\(Int($0 * 100)) %" })
                    .help("Mischt die bearbeitete Stimme mit der unbearbeiteten (gleich laut). Einzelne Bereiche: Mikrofonspur auswählen, S drücken, im Bereich die Stärke ändern.")
                LabeledSlider(title: "Rauschunterdrückung (neu berechnen)", value: $editor.settings.voice.noiseReduction, range: 0...1,
                              format: { $0 < 0.02 ? "aus" : "\(Int($0 * 100)) %" })
                Toggle("Atemgeräusche dämpfen", isOn: Binding(get: { editor.settings.voice.reducesBreaths },
                                                             set: { on in Task { await editor.setBreaths(on) } }))
                    .help("Erkennt Atemzüge (rauschig, ohne Tonhöhe, leiser als die Sprache) und legt sie als „Atem“-Bereiche in die Mikrofonspur – jeder einzeln prüfbar")
                if editor.settings.voice.reducesBreaths {
                    LabeledSlider(title: "Empfindlichkeit", value: Binding(get: { editor.settings.voice.breathLevel },
                                                                           set: { editor.setBreathSensitivity($0) }),
                                  range: 0...1, format: { String(format: "Atem bis %.0f dB unter der Sprache", 18 - 10 * $0) })
                    LabeledSlider(title: "Dämpfen um", value: Binding(get: { editor.settings.voice.breathDB },
                                                                      set: { editor.setBreathReduction($0) }),
                                  range: 3...40, format: { $0 >= 39 ? "fast stumm" : String(format: "%.0f dB", $0) })
                    if let state = editor.breathState { Text(state).font(.caption).foregroundStyle(.secondary) }
                }
                Toggle("Lautheit angleichen", isOn: $editor.settings.voice.normalize)
                if editor.settings.voice.normalize {
                    Picker("Ziel", selection: $editor.settings.voice.targetLUFS) {
                        Text("−14 LUFS (laut)").tag(-14.0)
                        Text("−16 LUFS (YouTube)").tag(-16.0)
                        Text("−19 LUFS (ruhig)").tag(-19.0)
                    }
                }
                Group {
                    switch editor.voiceState {
                    case .processing:
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Stimme wird bearbeitet …") }
                    case .ready(let r):
                        if let r {
                            Text(String(format: "Lautheit %.0f → %.0f LUFS, Rauschen −%.0f dB", r.loudnessBefore, r.loudnessAfter, max(0, r.noiseReductionDB))
                                 + (r.breaths.map { ", \($0) Atemgeräusche gedämpft" } ?? ""))
                        } else {
                            Text("Fertig.")
                        }
                    case .failed(let message):
                        Text("Fehlgeschlagen: \(message)").foregroundStyle(.red)
                    case .idle:
                        EmptyView()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var musicSection: some View {
        Section("Hintergrundmusik") {
            if let music = editor.settings.music {
                HStack {
                    Label(music.name, systemImage: "music.note").lineLimit(1)
                    Spacer()
                    Button("Ändern …") { editor.chooseMusic() }
                    Button(role: .destructive) { editor.removeMusic() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
                VolumeRow(title: "Lautstärke", icon: "speaker.wave.2.fill",
                          volume: Binding(get: { music.volume }, set: { editor.settings.music?.volume = $0 }),
                          muted: Binding(get: { music.muted }, set: { editor.settings.music?.muted = $0 }))
                Toggle("Unter Sprache leiser", isOn: Binding(get: { music.duckUnderSpeech }, set: { editor.settings.music?.duckUnderSpeech = $0 }))
                if music.duckUnderSpeech {
                    LabeledSlider(title: "Unter Sprache auf", value: Binding(get: { music.duckLevel }, set: { editor.settings.music?.duckLevel = $0 }),
                                  range: 0...0.8, format: { "\(Int($0 * 100)) %" })
                }
                LabeledSlider(title: "Einblenden", value: Binding(get: { music.fadeIn }, set: { editor.settings.music?.fadeIn = $0 }),
                              range: 0...6, format: { String(format: "%.1f s", $0) })
                LabeledSlider(title: "Ausblenden", value: Binding(get: { music.fadeOut }, set: { editor.settings.music?.fadeOut = $0 }),
                              range: 0...8, format: { String(format: "%.1f s", $0) })
                Toggle("Wiederholen, wenn das Stück zu kurz ist", isOn: Binding(get: { music.loop }, set: { editor.settings.music?.loop = $0 }))
                if let length = editor.musicLength, length > 1 {
                    LabeledSlider(title: "Beginn im Stück", value: Binding(get: { music.fileOffset }, set: { editor.settings.music?.fileOffset = $0 }),
                                  range: 0...max(0.1, length - 1), format: { formatTime($0, fractional: false) })
                }
            } else {
                Button {
                    editor.chooseMusic()
                } label: {
                    Label("Musik wählen …", systemImage: "music.note")
                }
                Text("Läuft unter dem ganzen Video durch – auch über Schnitte – und wird leiser, wenn jemand spricht.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Pictures, chapters

    private var imagesSection: some View {
        Section("Bilder & Videos") {
            HStack {
                Button { editor.addImage() } label: { Label("Bild …", systemImage: "photo") }
                Menu {
                    Button("Als Bild im Bild (über dem Video) …") { editor.addVideoOverlay() }
                    Button("In die Hauptspur einfügen …") { editor.addInsertClip() }
                } label: {
                    Label("Video", systemImage: "film")
                }
                .fixedSize()
            }
            ForEach(editor.settings.videoOverlays) { o in
                Button {
                    editor.selection = .videoOverlay(o.id)
                } label: {
                    HStack {
                        Image(systemName: o.synced ? "macwindow.on.rectangle" : "pip").foregroundStyle(.secondary)
                        Text(o.name).lineLimit(1)
                        Spacer()
                        Text("\(formatTime(editor.display(o.start)))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(editor.settings.images) { o in
                Button {
                    editor.selection = .image(o.id)
                    editor.seek(to: o.start + min(0.5, (o.end - o.start) / 2))
                } label: {
                    HStack {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                        Text(URL(fileURLWithPath: o.file).lastPathComponent).lineLimit(1)
                        Spacer()
                        Text("\(formatTime(editor.display(o.start)))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(editor.settings.inserts) { c in
                Button {
                    editor.selection = .insert(c.id)
                    editor.seek(to: c.sourceRange.lowerBound + FreezeFrame.span / 2)
                } label: {
                    HStack {
                        Image(systemName: "film.stack").foregroundStyle(.secondary)
                        Text(c.name).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f s", c.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("Bilder und Videos „Bild im Bild“ liegen über der Aufnahme. Ein eingefügter Videoclip unterbricht sie – die Aufnahme wartet, solange er läuft. "
                 + "Dateien lassen sich auch aus dem Finder in die Timeline ziehen: auf die Video-Spur zum Einfügen, auf die Medien-Spur oder ins Vorschaubild als Overlay.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Settings behind a lane header or an element of the picture (camera, captions, logo).
    @ViewBuilder
    private func panelContent(_ panel: EditorPanel) -> some View {
        switch panel {
        case .video:
            frameSection
            ColorGradeSection(editor: editor)
            fadeSection
        case .camera:
            if editor.hasCamera {
                cameraSection
                cameraLayoutHint
            } else {
                Section { Text("Diese Aufnahme hat keine Kamera.").foregroundStyle(.secondary) }
            }
        case .zoom:
            zoomSection
        case .cursor:
            cursorSection
        case .masks:
            Section("Masken") {
                Button { editor.addMaskAtPlayhead() } label: { Label("Maske am Abspielkopf", systemImage: "plus") }
                Button { editor.showSensitiveSheet = true } label: { Label("Sensible Daten automatisch finden …", systemImage: "eye.slash") }
                ForEach(editor.settings.masks) { m in
                    itemRow(icon: "square.grid.3x3", title: m.style.rawValue, time: m.start) { editor.selection = .mask(m.id) }
                }
                Text("Verpixelt oder verwischt einen Bereich (z. B. Passwörter); im Vorschaubild verschieben und an den Ecken ziehen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .annotations:
            Section("Markierungen") {
                HStack {
                    ForEach(AnnotationKind.allCases) { kind in
                        Button { editor.addAnnotation(kind) } label: { Label(kind.label, systemImage: kind.icon) }
                    }
                }
                ForEach(editor.settings.annotations) { a in
                    itemRow(icon: a.kind.icon, title: a.kind.label, time: a.start) { editor.selection = .annotation(a.id) }
                }
            }
        case .texts:
            textsSection
            textDesignDefaultsSection
        case .media:
            imagesSection
        case .captions:
            captionSection
            if !editor.settings.captions.isEmpty { CaptionStyleSection(editor: editor) }
        case .logo:
            logoSection
        }
    }

    private func itemRow(icon: String, title: String, time: Double, select: @escaping () -> Void) -> some View {
        Button(action: select) {
            HStack {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(title).lineLimit(1)
                Spacer()
                Text(formatTime(editor.display(time))).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var textDesignDefaultsSection: some View {
        Section("Design aller Texte") {
            Menu {
                ForEach(TextDesignLibrary.all) { d in
                    Button(d.name) { editor.applyDesignToAllTexts(d) }
                }
            } label: {
                Label("Ein Design für alle Texte …", systemImage: "paintbrush")
            }
            .disabled(editor.settings.texts.isEmpty)
            Text("Neue Texte bekommen das zuletzt gewählte Design" + (editor.settings.textDesign.map { " („\($0.name)“)." } ?? ".")
                 + " Einzelne Texte: Text auswählen und im Design-Bereich anpassen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var chaptersSection: some View {
        Section("Kapitel") {
            HStack {
                Button { editor.addChapter() } label: { Label("Kapitel am Abspielkopf (M)", systemImage: "bookmark") }
                Spacer()
                Button { editor.copyChapters() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Kapitel für die YouTube-Beschreibung kopieren")
                    .disabled(editor.settings.chapters.isEmpty)
            }
            ForEach(editor.outputChapters, id: \.time) { item in
                HStack {
                    Text(formatTime(item.time, fractional: false)).monospacedDigit().foregroundStyle(.secondary)
                    Text(item.title).lineLimit(1)
                }
                .font(.callout)
            }
            if let problem = editor.youTubeChapterProblem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            } else if !editor.settings.chapters.isEmpty {
                Text("Mit dem Kopieren-Symbol in die YouTube-Beschreibung übernehmen; der Export legt sie auch als Textdatei neben das Video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Background

    private var backgroundSection: some View {
        Section("Hintergrund") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Backgrounds.presets.indices, id: \.self) { i in
                    let selected = editor.settings.background == .gradient(i)
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Backgrounds.swatch(index: i))
                        .frame(height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Theme.brand : .clear, lineWidth: 2.5))
                        .help(Backgrounds.presets[i].name)
                        .onTapGesture { editor.settings.background = .gradient(i) }
                }
            }
            .padding(.vertical, 4)

            ColorPicker("Einfarbig", selection: solidColor, supportsOpacity: false)

            HStack {
                Button("Bild wählen …") { chooseImage() }
                Button("Schreibtischbild") {
                    if let url = Backgrounds.wallpaperURL() {
                        editor.settings.background = .image(path: url.path)
                    }
                }
            }
            if case .image(let path) = editor.settings.background {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                LabeledSlider(title: "Unschärfe", value: $editor.settings.backgroundBlur, range: 0...1, format: { "\(Int($0 * 100)) %" })
            }
        }
    }

    private var solidColor: Binding<Color> {
        Binding {
            if case .color(let r, let g, let b) = editor.settings.background {
                return Color(red: r, green: g, blue: b)
            }
            return Color(white: 0.12)
        } set: { color in
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
            editor.settings.background = .color(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            editor.settings.background = .image(path: url.path)
        }
    }

    // MARK: Frame

    private var fadeSection: some View {
        Section("Ein- und Ausblenden") {
            LabeledSlider(title: "Am Anfang aus Schwarz", value: $editor.settings.fadeIn, range: 0...3,
                          format: { $0 < 0.05 ? "aus" : String(format: "%.1f s", $0) })
            LabeledSlider(title: "Am Ende nach Schwarz", value: $editor.settings.fadeOut, range: 0...3,
                          format: { $0 < 0.05 ? "aus" : String(format: "%.1f s", $0) })
            Text("Bild und Ton des ganzen Videos. Übergänge an Schnitten: Schnitt auswählen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var frameSection: some View {
        Section("Format & Rahmen") {
            Picker("Format", selection: Binding(get: { editor.settings.aspect }, set: { editor.setAspect($0) })) {
                ForEach(OutputAspect.allCases) { a in Text(a.rawValue).tag(a) }
            }
            .pickerStyle(.segmented)
            .help("Jedes Format behält sein eigenes Layout – im Hochformat steht die Aufnahme oben, die Kamera groß darunter")
            HStack {
                Toggle("Aufnahme mittig", isOn: Binding(get: { editor.settings.contentY == nil },
                                                         set: { editor.settings.contentY = $0 ? nil : 0.3 }))
                Spacer()
                Button("Layout zurücksetzen") { editor.resetLayout() }
                    .buttonStyle(.link)
                    .help("Standard-Layout dieses Formats für Aufnahme, Kamera und Untertitel")
            }
            if let y = editor.settings.contentY {
                LabeledSlider(title: "Höhe der Aufnahme", value: Binding(get: { y }, set: { editor.settings.contentY = $0 }),
                              range: 0.05...0.95, format: { $0 < 0.4 ? "oben" : $0 > 0.6 ? "unten" : "Mitte" })
            }
            LabeledSlider(title: "Abstand", value: $editor.settings.padding, range: 0...0.2, format: { "\(Int($0 * 500)) %" })
            LabeledSlider(title: "Ecken", value: $editor.settings.cornerRadius, range: 0...48, format: { "\(Int($0))" })
            LabeledSlider(title: "Schatten", value: $editor.settings.shadow, range: 0...1, format: { "\(Int($0 * 100)) %" })
        }
    }

    // MARK: Mask

    private var maskSection: some View {
        Section {
            if let mask = editor.selectedMask {
                Picker("Stil", selection: Binding(get: { mask.style },
                                                 set: { v in editor.updateMask(id: mask.id) { $0.style = v } })) {
                    ForEach(BlurMask.Style.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Im Vorschaubild verschieben, die Ecke zieht die Größe. In der Timeline die Dauer ändern.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Captions

    private var captionSection: some View {
        Section("Untertitel") {
            HStack {
                Picker("Sprache", selection: $editor.settings.captionLanguage) {
                    Text("Deutsch").tag("de-DE")
                    Text("Englisch").tag("en-US")
                    Text("Französisch").tag("fr-FR")
                    Text("Spanisch").tag("es-ES")
                    Text("Italienisch").tag("it-IT")
                }
                .labelsHidden()
                Button(editor.settings.captions.isEmpty ? "Erzeugen" : "Neu erzeugen") { editor.generateCaptions() }
                    .disabled(editor.isGeneratingCaptions)
            }
            Picker("Quelle", selection: $editor.settings.captionSource) {
                ForEach(CaptionSource.allCases) { Text($0.label).tag($0) }
            }
            .help("Aus welchem Ton die Untertitel erkannt werden – z. B. eine eigene, eingefügte Sprachaufnahme")
            if editor.isGeneratingCaptions {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(editor.captionStatus ?? "")
                }
                .font(.caption)
            } else if let status = editor.captionStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let error = editor.captionError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if !editor.settings.captions.isEmpty {
                Toggle("Im Video anzeigen", isOn: $editor.settings.showCaptions)
                LabeledSlider(title: "Schriftgröße", value: $editor.settings.captionSize, range: 0.6...1.8,
                              format: { "\(Int($0 * 100)) %" })
                CaptionTranslateRow(editor: editor)
                Button("Als SRT exportieren …") { editor.exportSRT() }
                DisclosureGroup("Texte bearbeiten (\(editor.settings.captions.count))") {
                    ForEach(editor.settings.captions) { caption in
                        VStack(alignment: .leading, spacing: 2) {
                            Button(formatTime(caption.start)) { editor.seek(to: caption.start) }
                                .buttonStyle(.link)
                                .font(.caption.monospacedDigit())
                            TextField("Text", text: Binding(get: { caption.text },
                                                           set: { editor.updateCaption(id: caption.id, text: $0) }),
                                      axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .font(.callout)
                        }
                    }
                }
            } else {
                Text("Erkennung direkt auf dem Mac – nichts wird hochgeladen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Camera

    private var cameraSection: some View {
        Section("Kamera") {
            Toggle("Kamera anzeigen", isOn: $editor.settings.cameraVisible)
            if editor.settings.cameraVisible {
                Picker("Form", selection: $editor.settings.cameraShape) {
                    ForEach(CameraShape.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledSlider(title: "Größe", value: $editor.settings.cameraSize, range: 0.12...0.5, format: { "\(Int($0 * 100)) %" })
                Picker("Ecke", selection: Binding(
                    get: { editor.settings.cameraX == nil ? editor.settings.cameraCorner : nil },
                    set: { (corner: CameraCorner?) in
                        guard let corner else { return }
                        editor.settings.cameraCorner = corner
                        editor.settings.cameraX = nil
                        editor.settings.cameraY = nil
                    })) {
                    if editor.settings.cameraX != nil { Text("Frei").tag(CameraCorner?.none) }
                    ForEach(CameraCorner.allCases) { Text($0.label).tag(Optional($0)) }
                }
                Toggle("Spiegeln", isOn: $editor.settings.cameraMirror)
                Toggle("Schatten", isOn: $editor.settings.cameraShadow)
                Text("Die Blase lässt sich auch im Vorschaubild verschieben.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Audio

    private var audioSection: some View {
        Section("Lautstärke") {
            if editor.project.info.hasMicAudio {
                VolumeRow(title: "Mikrofon", icon: "mic.fill", volume: $editor.settings.micVolume, muted: $editor.settings.micMuted)
            }
            if editor.project.info.hasSystemAudio {
                VolumeRow(title: "Systemaudio", icon: "speaker.wave.2.fill", volume: $editor.settings.systemVolume, muted: $editor.settings.systemMuted)
            }
            VolumeRow(title: "Voice-over", icon: "waveform.badge.mic", volume: $editor.settings.voiceOverVolume, muted: $editor.settings.voiceOverMuted)
            Toggle("Klickgeräusche", isOn: $editor.settings.clickSound)
                .disabled(editor.project.cursor.clicks.isEmpty)
                .help("Spielt bei jedem Mausklick ein kurzes Klick-Geräusch ab")
            if editor.settings.clickSound {
                LabeledSlider(title: "Klick-Lautstärke", value: $editor.settings.clickVolume, range: 0...1, format: { "\(Int($0 * 100)) %" })
            }
            Text("Einzelne Bereiche stummschalten: Rechtsklick auf eine Audiospur.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var voiceOverSection: some View {
        Section("Voice-over") {
            Button {
                editor.toggleVoiceOver()
            } label: {
                Label(editor.voiceOverState == .idle ? "Ab Abspielkopf einsprechen" : "Aufnahme beenden", systemImage: "mic.badge.plus")
            }
            Toggle("Originalton darunter absenken", isOn: $editor.settings.duckUnderVoiceOver)
                .help("Mikrofon und Systemton werden leiser, solange ein Voice-over läuft")
            if editor.settings.duckUnderVoiceOver {
                LabeledSlider(title: "Absenken auf", value: $editor.settings.duckLevel, range: 0...0.8, format: { "\(Int($0 * 100)) %" })
            }
            Toggle("Beim Einsprechen mithören", isOn: $editor.monitorWhileNarrating)
                .help("Nur mit Kopfhörern – sonst nimmt das Mikrofon den Ton aus den Lautsprechern mit auf")
            if let error = editor.voiceOverError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var echoSection: some View {
        Section("Echo") {
            Toggle("Lautsprecher-Echo entfernen", isOn: $editor.settings.removeEcho)
                .help("Entfernt den über die Lautsprecher ins Mikrofon gelangten Systemton (klingt sonst wie ein Chorus).")
            Group {
                switch editor.echoState {
                case .processing:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Echo wird herausgerechnet …")
                    }
                case .ready(let stats):
                    if let stats {
                        Text(String(format: "Echo um %.0f dB reduziert (Verzögerung %.0f ms).", stats.totalReductionDB, stats.delayMs))
                    } else {
                        Text("Echofreie Mikrofonspur vorhanden.")
                    }
                case .failed(let message):
                    Text("Echo-Entfernung fehlgeschlagen: \(message)").foregroundStyle(.red)
                case .notNeeded:
                    EmptyView()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Mit Kopfhörern entsteht das Echo gar nicht erst.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Texts

    private var textsSection: some View {
        Section("Texte") {
            HStack {
                Button {
                    editor.addLowerThird()
                } label: {
                    Label("Bauchbinde", systemImage: "text.below.photo")
                }
                Menu {
                    Button("Über dem Video") { editor.addTitleCard(placement: .overlay) }
                    Button("Vorspann") { editor.addTitleCard(placement: .intro) }
                    Button("Abspann") { editor.addTitleCard(placement: .outro) }
                } label: {
                    Label("Titelkarte", systemImage: "rectangle.inset.filled")
                }
                .fixedSize()
            }
            if editor.settings.texts.isEmpty {
                Text("Neue Texte erscheinen am Abspielkopf. Oder in der Text-Spur der Timeline an eine freie Stelle klicken.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(editor.settings.texts) { text in
                Button {
                    editor.selectedTextID = text.id
                    switch text.placement {
                    case .intro where text.kind == .titleCard: editor.seek(to: editor.timelineStart + min(1, editor.introLead / 2))
                    case .outro where text.kind == .titleCard: editor.seek(to: editor.duration + min(1, editor.outroLead / 2))
                    default: editor.seek(to: text.start + min(0.5, text.length / 2))
                    }
                } label: {
                    HStack {
                        Image(systemName: text.kind == .lowerThird ? "text.below.photo" : "rectangle.inset.filled")
                            .foregroundStyle(.secondary)
                        Text(text.title.isEmpty ? "(ohne Titel)" : text.title).lineLimit(1)
                        Spacer()
                        Text(Self.timing(text)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private static func timing(_ text: TextOverlay) -> String {
        if text.kind == .titleCard && text.placement != .overlay {
            return "\(text.placement.label), \(String(format: "%.1f", text.length)) s"
        }
        return "\(formatTime(text.start)) – \(formatTime(text.end))"
    }

    private func textEditSection(_ text: TextOverlay) -> some View {
        let id = text.id
        func binding<T>(_ key: WritableKeyPath<TextOverlay, T>) -> Binding<T> {
            Binding(get: { editor.settings.texts.first { $0.id == id }?[keyPath: key] ?? text[keyPath: key] },
                    set: { v in editor.updateText(id: id) { $0[keyPath: key] = v } })
        }
        return Group {
            Section("Inhalt") {
                TextField("Titel", text: binding(\.title), axis: .vertical)
                TextField("Untertitel", text: binding(\.subtitle), axis: .vertical)
            }
            Section("Größe") {
                LabeledSlider(title: "Textgröße", value: binding(\.size), range: 0.5...2, format: { "\(Int($0 * 100)) %" })
            }
            TextDesignPanel(editor: editor, text: text)
            if text.kind == .titleCard {
                Section("Platzierung") {
                    Picker("Wo", selection: Binding(get: { text.placement }, set: { editor.setPlacement(id: id, $0) })) {
                        ForEach(TextOverlay.Placement.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if text.placement != .overlay {
                        LabeledSlider(title: "Dauer", value: Binding(get: { text.length }, set: { v in editor.updateText(id: id) { $0.end = $0.start + v } }),
                                      range: 1...10, format: { String(format: "%.1f s", $0) })
                        let isIntro = text.placement == .intro
                        let maxOverlap = editor.maxOverlap(intro: isIntro)
                        if maxOverlap > 0.1 {
                            LabeledSlider(title: "Überblendung mit der Aufnahme",
                                          value: Binding(get: { isIntro ? editor.introOverlapLength : editor.outroOverlapLength },
                                                         set: { editor.setOverlap(intro: isIntro, $0) }),
                                          range: 0...maxOverlap,
                                          format: { $0 < 0.05 ? "keine" : String(format: "%.1f s", $0) })
                        }
                    }
                    Text(text.look.cardBackground == nil ? "Hintergrund wie im Video." : "Eigener Hintergrund für die Titelkarte.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Position") {
                    HStack(alignment: .center, spacing: 14) {
                        AnchorGrid(selected: editor.anchorCell(text)) { column, row in
                            editor.placeLowerThird(id: id, column: column, row: row)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("Textausrichtung", selection: Binding(get: { text.align }, set: { editor.setTextAlign(id: id, $0) })) {
                                Image(systemName: "text.alignleft").tag(TextAlign.left)
                                Image(systemName: "text.aligncenter").tag(TextAlign.center)
                                Image(systemName: "text.alignright").tag(TextAlign.right)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .help("Ausrichtung der Zeilen – die Box bleibt, wo sie ist")
                            Text("Oder im Vorschaubild ziehen – rastet in der Mitte ein.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: Voice-over clip / cut / muted range

    private func voiceOverClipSection(_ clip: VoiceOverClip) -> some View {
        let fade = VoiceOverClip.crossfades(editor.settings.voiceOvers)[clip.id]
        return Section {
            LabeledSlider(title: "Lautstärke des Clips",
                          value: Binding(get: { clip.gain }, set: { v in editor.updateVoiceOver(id: clip.id) { $0.volume = v } }),
                          range: 0...1, format: { "\(Int($0 * 100)) %" })
            if let fade, fade.fadeIn > 0 || fade.fadeOut > 0 {
                LabeledContent("Überblendung") {
                    Text([fade.fadeIn > 0 ? String(format: "%.1f s am Anfang", fade.fadeIn) : nil,
                          fade.fadeOut > 0 ? String(format: "%.1f s am Ende", fade.fadeOut) : nil]
                        .compactMap { $0 }.joined(separator: ", "))
                }
            }
            Text("In der Timeline verschieben, an den Kanten kürzen, mit S am Abspielkopf teilen. "
                 + "Über einen anderen Clip geschoben, blenden beide ineinander über.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func cutSection(_ cut: CutRange) -> some View {
        Section {
            if editor.canDissolve(cut) {
                Picker("Übergang", selection: Binding(get: { cut.transition }, set: { editor.setTransition(cutID: cut.id, $0) })) {
                    ForEach(TransitionStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledSlider(title: "Länge",
                              value: Binding(get: { editor.dissolvesByCut[cut.id]?.length ?? 0 },
                                             set: { editor.setDissolve(cutID: cut.id, $0) }),
                              range: 0...3,
                              format: { $0 < 0.05 ? "harter Schnitt" : String(format: "%.1f s", $0) })
                Text("Schiebt die Teile davor und danach übereinander; Bild und Ton blenden weich über. "
                     + "Auch mit den runden Griffen oben am Schnitt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                editor.deleteSelection()
            } label: {
                Label("Bereich wiederherstellen", systemImage: "arrow.uturn.backward")
            }
        }
    }

    @ViewBuilder
    private var muteSection: some View {
        if let m = editor.selectedMute {
            Section(m.kind == .breath ? "Atemgeräusch" : "Bereich") {
                LabeledSlider(title: "Lautstärke im Bereich",
                              value: Binding(get: { m.level }, set: { v in editor.updateMute(id: m.id) { $0.gain = v < 0.01 ? nil : v } }),
                              range: 0...1, format: { $0 < 0.01 ? "stumm" : "\(Int($0 * 100)) %" })
                if m.lane == .mic, editor.settings.voice.enhancesMic {
                    Toggle("Eigene Stärke der Stimmverbesserung", isOn: Binding(
                        get: { m.enhance != nil },
                        set: { on in editor.updateMute(id: m.id) { $0.enhance = on ? editor.settings.voice.strength : nil } }))
                    if let e = m.enhance {
                        LabeledSlider(title: "Stimmverbesserung hier", value: Binding(get: { e }, set: { v in editor.updateMute(id: m.id) { $0.enhance = v } }),
                                      range: 0...1, format: { $0 < 0.02 ? "aus (Original)" : "\(Int($0 * 100)) %" })
                    }
                }
                Text(m.kind == .breath ? "Automatisch gefunden. ⌫ entfernt die Dämpfung an dieser Stelle; Lautstärke hochziehen macht sie schwächer."
                     : "Kanten in der Timeline ziehen, um den Bereich zu ändern. 0 % schaltet die Spur hier stumm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Cursor

    private func cursorRangeSection(_ r: CursorRange) -> some View {
        Section {
            Picker("In diesem Bereich", selection: Binding(get: { r.effect }, set: { v in editor.updateCursorRange(id: r.id) { $0.effect = v } })) {
                ForEach(CursorEffect.allCases.filter { $0 != .none }) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.inline)
            if r.effect != .hidden {
                LabeledSlider(title: "Größe", value: Binding(get: { r.size }, set: { v in editor.updateCursorRange(id: r.id) { $0.size = v } }),
                              range: 0.5...2.5, format: { "\(Int($0 * 100)) %" })
            }
            Text("Gilt nur hier und blendet an den Rändern weich ein und aus. Länge in der Cursor-Spur ziehen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cursorSection: some View {
        Section("Cursor") {
            Toggle("Cursor anzeigen", isOn: $editor.settings.showCursor)
            if editor.settings.showCursor {
                LabeledSlider(title: "Größe", value: $editor.settings.cursorScale, range: 0.8...3.5, format: { String(format: "%.1f×", $0) })
                LabeledSlider(title: "Glättung", value: $editor.settings.cursorSmoothing, range: 0...1, format: { "\(Int($0 * 100)) %" })
                Toggle("Klick-Effekt", isOn: $editor.settings.clickEffect)
                Toggle("Bei Stillstand ausblenden", isOn: $editor.settings.hideIdleCursor)
                Picker("Hervorhebung im ganzen Video", selection: $editor.settings.cursorEffect) {
                    ForEach(CursorEffect.global) { Text($0.label).tag($0) }
                }
                .help("Leuchtkreis um den Zeiger, Spotlight (alles andere dunkler) oder eine Lupe, die den Bereich um den Zeiger vergrößert")
                if editor.settings.cursorEffect != .none {
                    LabeledSlider(title: "Größe der Hervorhebung", value: $editor.settings.cursorEffectSize, range: 0.5...2.5,
                                  format: { "\(Int($0 * 100)) %" })
                }
            }
            if let keys = editor.project.cursor.keys, !keys.isEmpty {
                Toggle("Tastenkürzel einblenden (\(keys.count))", isOn: $editor.settings.showShortcuts)
            }
            if editor.project.cursor.images.isEmpty {
                Text("Keine Cursor-Bilder aufgezeichnet – es wird ein Standardpfeil verwendet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Zoom

    private var zoomSection: some View {
        Section("Zoom") {
            LabeledSlider(title: "Standard-Stärke", value: $editor.settings.defaultZoom, range: 1.2...3.5, format: { String(format: "%.1f×", $0) })
            LabeledSlider(title: "Bewegungsunschärfe", value: $editor.settings.motionBlur, range: 0...1,
                          format: { $0 < 0.01 ? "aus" : "\(Int($0 * 100)) %" })
            HStack {
                Button {
                    editor.addZoomAtPlayhead()
                } label: {
                    Label("Zoom hinzufügen", systemImage: "plus")
                }
                Button("Auto-Zoom neu") { editor.regenerateAutoZoom() }
                    .help("Erzeugt Zoom-Bereiche aus den aufgenommenen Klicks (\(editor.project.cursor.clicks.count) Klicks)")
            }
            Text("Einen Zoom in der Timeline anklicken, um ihn anzupassen – oder in der Zoom-Spur an eine freie Stelle klicken, um einen neuen anzulegen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var selectedZoomSection: some View {
        if let i = editor.selectedZoomIndex {
            let seg = editor.settings.zoomSegments[i]
            Section {
                LabeledSlider(title: "Stärke",
                              value: Binding(get: { seg.scale },
                                             set: { editor.updateZoom(id: seg.id, scale: $0) }),
                              range: 1.1...4,
                              format: { String(format: "%.1f×", $0) })
                Text("Dauer und Lage in der Timeline ändern. Die Kamera folgt dem Mauszeiger.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 3 × 3 grid of positions in a 16:9 frame (like the anchor control of layout apps).
struct AnchorGrid: View {
    let selected: (column: Int, row: Int)?
    let pick: (Int, Int) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { column in
                        let active = selected?.column == column && selected?.row == row
                        RoundedRectangle(cornerRadius: 3)
                            .fill(active ? Theme.brand : Color.secondary.opacity(0.25))
                            .frame(width: 24, height: 13)
                            .contentShape(Rectangle())
                            .onTapGesture { pick(column, row) }
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.35)))
        .help("Position der Bauchbinde")
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .labelsHidden()
        }
    }
}

struct VolumeRow: View {
    let title: String
    let icon: String
    @Binding var volume: Double
    @Binding var muted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text(muted ? "stumm" : "\(Int(volume * 100)) %")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    muted.toggle()
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(muted ? "Ton einschalten" : "Stummschalten")
                Slider(value: $volume, in: 0...1)
                    .labelsHidden()
                    .disabled(muted)
            }
        }
    }
}
