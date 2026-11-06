import SwiftUI

// MARK: - Colors

extension RGBAColor {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

private func colorBinding(_ get: @escaping () -> RGBAColor, _ set: @escaping (RGBAColor) -> Void) -> Binding<Color> {
    Binding(get: { get().color }, set: { set(RGBAColor($0)) })
}

// MARK: - Text designs

extension TextDesign {
    var swiftUIDesign: Font.Design {
        switch font {
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        case .system, .condensed: return .default
        }
    }

    var swiftUIWeight: Font.Weight {
        switch weight {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }
}

/// Small preview of a text design (gallery tile).
struct TextDesignSwatch: View {
    let design: TextDesign
    let selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing))
                HStack(spacing: 0) {
                    if let accent = design.accent {
                        Rectangle().fill(accent.color).frame(width: 3)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(design.uppercaseTitle ? "TITEL" : "Titel")
                            .font(.system(size: 11, weight: design.swiftUIWeight, design: design.swiftUIDesign))
                            .fontWidth(design.font == .condensed ? .condensed : .standard)
                            .foregroundStyle(design.titleColor.color)
                        Text("Untertitel")
                            .font(.system(size: 7.5, design: design.swiftUIDesign))
                            .foregroundStyle(design.subtitleColor.color)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                }
                .background(design.box.color, in: RoundedRectangle(cornerRadius: min(8, CGFloat(design.cornerRadius) * 11)))
                .clipShape(RoundedRectangle(cornerRadius: min(8, CGFloat(design.cornerRadius) * 11)))
                .shadow(color: design.shadow ? .black.opacity(0.5) : .clear, radius: 2, y: 1)
            }
            .frame(height: 44)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Theme.brand : Color.clear, lineWidth: 2.5))
            Text(design.name)
                .font(.caption2)
                .foregroundStyle(selected ? Theme.brand : .secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// Gallery of built-in and saved designs plus an editor for the selected text's design.
struct TextDesignPanel: View {
    @ObservedObject var editor: EditorModel
    let text: TextOverlay

    var body: some View {
        let look = text.look
        Section("Design") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 8) {
                ForEach(TextDesignLibrary.all) { d in
                    TextDesignSwatch(design: d, selected: d.key == look.key)
                        .onTapGesture { editor.setTextDesign(id: text.id, d) }
                        .contextMenu {
                            if !TextDesign.presets.contains(where: { $0.id == d.id }) {
                                Button("Design löschen", role: .destructive) {
                                    TextDesignLibrary.remove(d.id)
                                    editor.objectWillChange.send()
                                }
                            }
                        }
                        .help(d.name)
                }
            }
            .padding(.vertical, 2)
            HStack {
                Button {
                    editor.applyDesignToAllTexts(look)
                } label: {
                    Label("Auf alle Texte anwenden", systemImage: "square.on.square")
                }
                .help("Alle Bauchbinden und Titelkarten bekommen dieses Design")
                Spacer()
                Button {
                    editor.saveTextDesign(look)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Als eigenes Design sichern (für alle Projekte)")
            }
        }
        Section {
            DisclosureGroup("Design bearbeiten") {
                designEditor(look)
            }
        }
        Section("Bild im Text") {
            if let image = text.image {
                HStack {
                    Label(URL(fileURLWithPath: image).deletingPathExtension().lastPathComponent, systemImage: "photo")
                        .lineLimit(1)
                    Spacer()
                    Button("Ändern …") { editor.chooseTextImage(id: text.id) }
                    Button(role: .destructive) {
                        editor.updateText(id: text.id) { $0.image = nil }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            } else {
                Button {
                    editor.chooseTextImage(id: text.id)
                } label: {
                    Label("Bild oder Logo hinzufügen …", systemImage: "photo.badge.plus")
                }
                Text(text.kind == .lowerThird ? "Steht in der Box neben dem Text – z. B. ein Logo oder Porträt."
                     : "Steht über dem Titel – z. B. ein Logo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func set(_ change: @escaping (inout TextDesign) -> Void) { editor.editTextDesign(id: text.id, change) }

    private func designEditor(_ d: TextDesign) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Schrift", selection: Binding(get: { d.font }, set: { v in set { $0.font = v } })) {
                ForEach(TextFont.allCases) { Text($0.label).tag($0) }
            }
            Picker("Stärke", selection: Binding(get: { d.weight }, set: { v in set { $0.weight = v } })) {
                ForEach(TextWeight.allCases) { Text($0.label).tag($0) }
            }
            ColorPicker("Titel", selection: colorBinding({ d.titleColor }, { v in set { $0.titleColor = v } }), supportsOpacity: false)
            ColorPicker("Untertitel", selection: colorBinding({ d.subtitleColor }, { v in set { $0.subtitleColor = v } }))
            if text.kind == .lowerThird {
                Toggle("Box", isOn: Binding(get: { d.hasBox }, set: { on in set { $0.box = on ? RGBAColor(r: 0, g: 0, b: 0, a: 0.86) : .clear } }))
                if d.hasBox {
                    ColorPicker("Boxfarbe", selection: colorBinding({ d.box }, { v in set { $0.box = v.a < 0.02 ? v.with(alpha: 0.02) : v } }))
                }
                Toggle("Akzentbalken", isOn: Binding(get: { d.accent != nil }, set: { on in set { $0.accent = on ? TextDesign.accentBlue : nil } }))
                if let accent = d.accent {
                    ColorPicker("Balkenfarbe", selection: colorBinding({ accent }, { v in set { $0.accent = v } }), supportsOpacity: false)
                }
                LabeledSlider(title: "Ecken", value: Binding(get: { d.cornerRadius }, set: { v in set { $0.cornerRadius = v } }),
                              range: 0...1, format: { $0 < 0.02 ? "eckig" : "\(Int($0 * 100)) %" })
                LabeledSlider(title: "Innenabstand", value: Binding(get: { d.padding }, set: { v in set { $0.padding = v } }),
                              range: 0.5...1.8, format: { "\(Int($0 * 100)) %" })
            } else {
                Toggle("Eigener Hintergrund", isOn: Binding(get: { d.cardBackground != nil },
                                                           set: { on in set { $0.cardBackground = on ? RGBAColor(r: 0.06, g: 0.06, b: 0.08) : nil } }))
                if let bg = d.cardBackground {
                    ColorPicker("Hintergrund", selection: colorBinding({ bg }, { v in set { $0.cardBackground = v.with(alpha: 1) } }),
                                supportsOpacity: false)
                }
            }
            Toggle("Schatten", isOn: Binding(get: { d.shadow }, set: { v in set { $0.shadow = v } }))
            Toggle("Titel in Großbuchstaben", isOn: Binding(get: { d.uppercaseTitle }, set: { v in set { $0.uppercaseTitle = v } }))
        }
        .padding(.top, 6)
    }
}

// MARK: - Pictures and video overlays

struct PictureStyleRows: View {
    let frame: PictureFrame
    let shadow: Bool
    let setFrame: (PictureFrame) -> Void
    let setShadow: (Bool) -> Void
    let applyToAll: () -> Void

    var body: some View {
        Picker("Rahmen", selection: Binding(get: { frame }, set: setFrame)) {
            ForEach(PictureFrame.allCases) { Text($0.label).tag($0) }
        }
        Toggle("Schatten", isOn: Binding(get: { shadow }, set: setShadow))
        Button {
            applyToAll()
        } label: {
            Label("Rahmen auf alle Bilder und Videos anwenden", systemImage: "square.on.square")
        }
        .buttonStyle(.link)
    }
}

struct VideoOverlaySection: View {
    @ObservedObject var editor: EditorModel
    let overlay: VideoOverlay

    var body: some View {
        let o = overlay
        let id = o.id
        Section("Bild im Bild") {
            LabeledSlider(title: "Größe", value: Binding(get: { o.width }, set: { v in editor.updateVideoOverlay(id: id) { $0.width = v } }),
                          range: 0.08...1, format: { "\(Int($0 * 100)) %" })
            LabeledSlider(title: "Deckkraft", value: Binding(get: { o.opacity }, set: { v in editor.updateVideoOverlay(id: id) { $0.opacity = v } }),
                          range: 0.05...1, format: { "\(Int($0 * 100)) %" })
            PictureStyleRows(frame: o.frame, shadow: o.shadow,
                             setFrame: { v in editor.updateVideoOverlay(id: id) { $0.frame = v } },
                             setShadow: { v in editor.updateVideoOverlay(id: id) { $0.shadow = v } },
                             applyToAll: { editor.applyFrameToAllImages(o.frame, shadow: o.shadow) })
        }
        if !o.synced {
            Section("Ton und Länge") {
                VolumeRow(title: "Lautstärke", icon: "speaker.wave.2.fill",
                          volume: Binding(get: { o.volume }, set: { v in editor.updateVideoOverlay(id: id) { $0.volume = v } }),
                          muted: Binding(get: { o.muted }, set: { v in editor.updateVideoOverlay(id: id) { $0.muted = v } }))
                LabeledSlider(title: "Beginn im Video", value: Binding(get: { o.fileOffset }, set: { v in editor.updateVideoOverlay(id: id) { $0.fileOffset = v } }),
                              range: 0...max(0.1, o.fileDuration - 0.2), format: { String(format: "%.1f s", $0) })
                Text("Läuft ab seinem Beginn in Echtzeit. Im Vorschaubild verschieben, Ecken ziehen; Länge in der Medien-Spur an der Kante ziehen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                Text("Das zweite Fenster wurde mit der Aufnahme aufgezeichnet und läuft synchron mit ihr. Mit S in der Medien-Spur teilen, um es nur zeitweise zu zeigen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Color grading

struct ColorGradeSection: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        let g = editor.settings.color
        Section("Farbkorrektur") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(ColorGrade.presets) { p in
                    let active = abs(g.exposure - p.exposure) < 0.01 && abs(g.contrast - p.contrast) < 0.01
                        && abs(g.saturation - p.saturation) < 0.01 && abs(g.temperature - p.temperature) < 0.01
                        && abs(g.vibrance - p.vibrance) < 0.01
                    Text(p.name)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(active ? Theme.brand.opacity(0.25) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Theme.brand : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editor.commitUndoStep()
                            editor.settings.color.apply(p)
                            editor.commitUndoStep()
                        }
                }
            }
            LabeledSlider(title: "Belichtung", value: $editor.settings.color.exposure, range: -2...2, format: { String(format: "%+.1f", $0) })
            LabeledSlider(title: "Kontrast", value: $editor.settings.color.contrast, range: 0.5...1.5, format: { "\(Int(($0 - 1) * 100)) %" })
            LabeledSlider(title: "Sättigung", value: $editor.settings.color.saturation, range: 0...2, format: { "\(Int($0 * 100)) %" })
            LabeledSlider(title: "Wärme", value: $editor.settings.color.temperature, range: -1...1,
                          format: { $0 > 0.02 ? "wärmer" : $0 < -0.02 ? "kühler" : "neutral" })
            LabeledSlider(title: "Lebendigkeit", value: $editor.settings.color.vibrance, range: -1...1, format: { "\(Int($0 * 100)) %" })
            VStack(alignment: .leading, spacing: 4) {
                Text("Anwenden auf").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Toggle("Bildschirm", isOn: $editor.settings.color.applyToScreen)
                    if editor.hasCamera { Toggle("Kamera", isOn: $editor.settings.color.applyToCamera) }
                    Toggle("Videos", isOn: $editor.settings.color.applyToMedia)
                }
                .toggleStyle(.checkbox)
            }
        }
    }
}

// MARK: - Audio mixer

struct MixerSection: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        Section("Mischpult") {
            if editor.project.info.hasMicAudio {
                VolumeRow(title: "Mikrofon", icon: "mic.fill", volume: $editor.settings.micVolume, muted: $editor.settings.micMuted)
            }
            if editor.project.info.hasSystemAudio {
                VolumeRow(title: "Systemton", icon: "speaker.wave.2.fill", volume: $editor.settings.systemVolume, muted: $editor.settings.systemMuted)
            }
            VolumeRow(title: "Voice-over", icon: "waveform.badge.mic", volume: $editor.settings.voiceOverVolume, muted: $editor.settings.voiceOverMuted)
            if editor.settings.music != nil {
                VolumeRow(title: "Musik", icon: "music.note",
                          volume: Binding(get: { editor.settings.music?.volume ?? 0 }, set: { editor.settings.music?.volume = $0 }),
                          muted: Binding(get: { editor.settings.music?.muted ?? false }, set: { editor.settings.music?.muted = $0 }))
            }
            Toggle("Klickgeräusche", isOn: $editor.settings.clickSound)
                .disabled(editor.project.cursor.clicks.isEmpty)
                .help("Spielt bei jedem Mausklick ein kurzes Klick-Geräusch ab")
            if editor.settings.clickSound {
                LabeledSlider(title: "Klick-Lautstärke", value: $editor.settings.clickVolume, range: 0...1, format: { "\(Int($0 * 100)) %" })
            }
            Toggle("Soundeffekte bei Zooms und Übergängen", isOn: $editor.settings.soundEffects)
                .help("Ein leises „Wusch“, wenn ein Zoom beginnt und an Übergängen")
            if editor.settings.soundEffects {
                LabeledSlider(title: "Effekt-Lautstärke", value: $editor.settings.soundEffectVolume, range: 0...1, format: { "\(Int($0 * 100)) %" })
            }
            HStack {
                Button {
                    Task { await editor.autoLevel() }
                } label: {
                    Label("Pegel angleichen", systemImage: "slider.horizontal.3")
                }
                .disabled(editor.levelState == .measuring)
                .help("Misst die Lautheit jeder Spur und stellt die Regler so, dass Sprache vorne liegt, Systemton und Musik darunter")
                if editor.levelState == .measuring { ProgressView().controlSize(.small) }
            }
            if case .done(let note) = editor.levelState {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Text("Einzelne Bereiche einer Spur leiser oder stumm: Spur-Menü (…) oder Rechtsklick in der Timeline; den Bereich auswählen und die Lautstärke einstellen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("Gesamtlautstärke") {
            Toggle("Beim Export auf Ziel-Lautheit bringen", isOn: $editor.settings.masterNormalize)
            if editor.settings.masterNormalize {
                Picker("Ziel", selection: $editor.settings.masterTargetLUFS) {
                    Text("−14 LUFS (YouTube, laut)").tag(-14.0)
                    Text("−16 LUFS (Standard)").tag(-16.0)
                    Text("−19 LUFS (ruhig)").tag(-19.0)
                }
            }
            Text("Misst nach dem Export die Lautheit des fertigen Videos und gleicht sie an – ohne zu übersteuern.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Audio lane

/// A whole audio lane: volume, mute, voice enhancement and ranges with their own volume.
struct AudioLaneSection: View {
    @ObservedObject var editor: EditorModel
    let lane: AudioLane

    var body: some View {
        Section("Spur") {
            VolumeRow(title: lane.label, icon: lane.icon,
                      volume: Binding(get: { editor.volume(of: lane) }, set: { editor.setVolume($0, of: lane) }),
                      muted: Binding(get: { editor.isMuted(lane) }, set: { editor.setMuted($0, lane) }))
            if lane == .mic || lane == .voiceOver {
                Toggle("Stimme verbessern (Rauschen, Lautheit)", isOn: Binding(
                    get: { lane == .mic ? editor.settings.voice.enhancesMic : editor.settings.voice.enhancesVoiceOver },
                    set: { on in
                        if on { editor.settings.voice.enabled = true }
                        if lane == .mic { editor.settings.voice.mic = on } else { editor.settings.voice.voiceOver = on }
                    }))
            }
        }
        Section("Bereiche") {
            HStack {
                Button {
                    editor.splitLane(lane, at: editor.currentTime)
                } label: {
                    Label("Am Abspielkopf schneiden (S)", systemImage: "scissors")
                }
                Spacer()
            }
            HStack {
                Button("Leiser ab hier") { editor.addMute(lane: lane, gain: 0.4) }
                Button("Stumm ab hier") { editor.addMute(lane: lane) }
            }
            let ranges = editor.settings.audioMutes.filter { $0.lane == lane }.sorted { $0.start < $1.start }
            ForEach(ranges) { m in
                Button {
                    editor.selectedMuteID = m.id
                    editor.seek(to: m.start)
                } label: {
                    HStack {
                        Image(systemName: m.isMute ? "speaker.slash" : "speaker.wave.1").foregroundStyle(.secondary)
                        Text("\(formatTime(editor.display(m.start))) – \(formatTime(editor.display(m.end)))").monospacedDigit()
                        Spacer()
                        Text(m.isMute ? "stumm" : "\(Int(m.level * 100)) %").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("Schneiden legt ab dem Abspielkopf einen Bereich mit eigener Lautstärke an (bis zum Ende des Teils). Bereich anklicken und die Lautstärke einstellen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Caption style

struct CaptionStyleSection: View {
    @ObservedObject var editor: EditorModel

    private var style: Binding<CaptionStyle> { $editor.settings.captionStyle }

    var body: some View {
        let s = editor.settings.captionStyle
        Section("Untertitel-Stil") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(CaptionStyle.presets) { p in
                    Text(p.name)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editor.commitUndoStep()
                            p.apply(&editor.settings.captionStyle)
                            editor.commitUndoStep()
                        }
                }
            }
            Picker("Anzeige", selection: style.mode) {
                ForEach(CaptionMode.allCases) { Text($0.label).tag($0) }
            }
            LabeledSlider(title: "Schriftgröße", value: $editor.settings.captionSize, range: 0.6...2.2, format: { "\(Int($0 * 100)) %" })
            Picker("Schrift", selection: style.font) {
                ForEach(TextFont.allCases) { Text($0.label).tag($0) }
            }
            Picker("Stärke", selection: style.weight) {
                ForEach(TextWeight.allCases) { Text($0.label).tag($0) }
            }
            ColorPicker("Textfarbe", selection: Binding(get: { s.textColor.color }, set: { editor.settings.captionStyle.textColor = RGBAColor($0) }),
                        supportsOpacity: false)
            if s.mode == .highlight || s.mode == .chunks {
                ColorPicker("Gesprochenes Wort", selection: Binding(get: { s.highlightColor.color },
                                                                    set: { editor.settings.captionStyle.highlightColor = RGBAColor($0) }),
                            supportsOpacity: false)
            }
            Toggle("Hintergrund", isOn: Binding(get: { s.box.a > 0.01 },
                                                set: { editor.settings.captionStyle.box = $0 ? RGBAColor(r: 0, g: 0, b: 0, a: 0.86) : .clear }))
            if s.box.a > 0.01 {
                ColorPicker("Hintergrundfarbe", selection: Binding(get: { s.box.color },
                                                                   set: { editor.settings.captionStyle.box = RGBAColor($0).a < 0.05 ? RGBAColor($0).with(alpha: 0.05) : RGBAColor($0) }))
            }
            Toggle("Kontur um die Buchstaben", isOn: style.outline)
            Toggle("Großbuchstaben", isOn: style.uppercase)
            if s.mode == .chunks || s.mode == .word {
                Toggle("Wörter springen hinein", isOn: style.pop)
            }
        }
        Section("Position der Untertitel") {
            LabeledSlider(title: "Höhe", value: style.y, range: 0.05...0.95, format: { $0 < 0.35 ? "oben" : $0 > 0.65 ? "unten" : "Mitte" })
            LabeledSlider(title: "Seitlich", value: style.x, range: 0.15...0.85, format: { abs($0 - 0.5) < 0.02 ? "Mitte" : $0 < 0.5 ? "links" : "rechts" })
            Text("Oder im Vorschaubild auf die Untertitel klicken und sie ziehen. Jedes Format (16:9, 9:16 …) merkt sich seine Position.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}


// MARK: - Automatic edits

/// Everything the automatic steps changed, to review, adjust or take back.
struct AutoEditsSection: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        let fillers = editor.automaticCuts(.filler).count
        let pauses = editor.automaticCuts(.pause).count
        let words = editor.automaticCuts(.transcript).count
        let breaths = editor.breathRegions.count
        if fillers + pauses + words + breaths > 0 {
            Section("Automatische Änderungen") {
                if fillers > 0 { row("Füllwörter herausgeschnitten", fillers, review: { editor.reviewNext(cuts: .filler) }, undo: { editor.restoreCuts(.filler) }) }
                if pauses > 0 { row("Pausen gekürzt", pauses, review: { editor.reviewNext(cuts: .pause) }, undo: { editor.restoreCuts(.pause) }) }
                if words > 0 { row("Über den Text geschnitten", words, review: { editor.reviewNext(cuts: .transcript) }, undo: { editor.restoreCuts(.transcript) }) }
                if breaths > 0 { row("Atemgeräusche gedämpft", breaths, review: { editor.reviewNext(breaths: true) }, undo: { editor.removeBreathRegions() }) }
                Text("„Prüfen“ springt zur nächsten Stelle und wählt sie aus: Leertaste spielt sie ab, ⌫ nimmt nur diese Änderung zurück, die Kanten in der Timeline passen sie an.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: String, _ count: Int, review: @escaping () -> Void, undo: @escaping () -> Void) -> some View {
        HStack {
            Text("\(title): \(count)")
            Spacer()
            Button("Prüfen", action: review).help("Zur nächsten Stelle springen")
            Button(role: .destructive, action: undo) { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless)
                .help("Alle zurücknehmen")
        }
    }
}
