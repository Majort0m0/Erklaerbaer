import SwiftUI
import AppKit

/// Shows the live picture in the control window.
private struct LivePreview: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The control window: never part of the picture that is shared.
struct LiveControlView: View {
    @ObservedObject var live: LiveModel
    @ObservedObject var app: AppModel
    @AppStorage("liveExtrasOpen") private var extrasOpen = false

    private let width: CGFloat = 400
    private var previewHeight: CGFloat { (width - 28) * 9 / 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            preview
            scenes
            sourceRows
            extras
            effects
            memes
            recording
            if let message = live.message {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("In Zoom, Teams oder Meet: Bildschirm teilen und das Fenster „\(LiveProgramWindow.title)“ wählen. Dieses Steuerfenster ist im geteilten Bild nie zu sehen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: width)
        .tint(Theme.brand)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.record).frame(width: 9, height: 9)
            Text("Live").font(.headline)
            Text("\(live.framesPerSecond) Bilder/s").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Button { live.collapse() } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .keyboardShortcut("h", modifiers: [])
            .help("Steuerung an den Bildschirmrand einklappen (Taste H), das Live-Bild läuft weiter")
            Button("Beenden") { Task { await live.end() } }
                .help("Live-Modus beenden und beide Fenster schließen")
        }
    }

    private var preview: some View {
        let size = CGSize(width: width - 28, height: previewHeight)
        return ZStack(alignment: .topLeading) {
            LivePreview(layer: live.previewLayer)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if live.config.scene == .source, live.config.bubble {
                bubbleHandles(size)
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "livePreview")
    }

    /// Drag the bubble to move it, its handle to change the size.
    private func bubbleHandles(_ size: CGSize) -> some View {
        let rect = LiveCompositor.bubbleRect(live.config)
        let scale = size.width / LiveCompositor.canvas.width
        let d = rect.width * scale
        // The ring lies on the white edge the live picture draws around the webcam.
        let ring = (rect.width + 2 * LiveCompositor.bubbleRim) * scale
        let center = CGPoint(x: rect.midX * scale, y: size.height - rect.midY * scale)
        let handle = CGPoint(x: center.x + ring / 2 * 0.707, y: center.y + ring / 2 * 0.707)
        return ZStack(alignment: .topLeading) {
            Circle()
                .stroke(Theme.focus, lineWidth: 1.5)
                .contentShape(Circle())
                .frame(width: max(d, ring), height: max(d, ring))
                .pointerStyle(.grabIdle)
                .position(center)
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("livePreview"))
                    .onChanged { v in
                        let origin = live.dragStart ?? live.config
                        live.dragStart = origin
                        var new = live.config
                        new.bubbleX = min(1, max(0, origin.bubbleX + Double(v.translation.width / size.width)))
                        new.bubbleY = min(1, max(0, origin.bubbleY + Double(v.translation.height / size.height)))
                        live.config = new
                    }
                    .onEnded { _ in live.dragStart = nil })
                .help("Ziehen verschiebt die Webcam")
            Circle()
                .fill(Theme.focus)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                .frame(width: 13, height: 13)
                .contentShape(Circle().inset(by: -5))
                .position(handle)
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("livePreview"))
                    .onChanged { v in
                        let origin = live.dragStart ?? live.config
                        live.dragStart = origin
                        let delta = Double((v.translation.width + v.translation.height) / size.height)
                        live.config.bubbleSize = min(0.9, max(0.12, origin.bubbleSize + delta))
                    }
                    .onEnded { _ in live.dragStart = nil })
                .help("Ziehen ändert die Größe der Webcam")
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func sceneButton(_ title: String, icon: String, active: Bool, key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 17))
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(active ? Theme.brand.opacity(0.35) : Theme.lane))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(active ? Theme.brand : Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
    }

    private var scenes: some View {
        HStack(spacing: 8) {
            sceneButton("Nur Webcam", icon: "person.crop.rectangle", active: live.config.scene == .webcam, key: "q") { live.config.scene = .webcam }
                .help("Nur die Webcam zeigen (Taste Q)")
            sceneButton("Quelle", icon: "macwindow", active: live.config.scene == .source && !live.config.bubble, key: "w") {
                live.config.scene = .source
                live.config.bubble = false
            }
            .help("Nur Bildschirm, Fenster oder iPad zeigen (Taste W)")
            sceneButton("Quelle + Webcam", icon: "pip", active: live.config.scene == .source && live.config.bubble, key: "e") {
                live.config.scene = .source
                live.config.bubble = true
            }
            .help("Bildschirm, Fenster oder iPad mit Webcam-Bubble (Taste E)")
        }
    }

    private var sourceRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Quelle", selection: $live.source) {
                Section("Bildschirme") {
                    ForEach(app.displays, id: \.displayID) { d in
                        Text(app.displayName(d)).tag(Optional(SourceSelection.display(d.displayID)))
                    }
                }
                if !app.deviceChoices.isEmpty {
                    Section("iPad und iPhone am Kabel") {
                        ForEach(app.deviceChoices, id: \.id) { d in Text(d.name).tag(Optional(SourceSelection.device(d.id))) }
                    }
                }
                Section("Fenster") {
                    ForEach(app.windows + app.otherWindows, id: \.windowID) { w in
                        Text(app.windowName(w)).lineLimit(1).tag(Optional(SourceSelection.window(w.windowID)))
                    }
                }
            }
            Picker("Webcam", selection: $live.cameraID) {
                Text("Aus").tag("")
                ForEach(app.cameras, id: \.uniqueID) { c in Text(c.localizedName).tag(c.uniqueID) }
            }
            if live.config.scene == .source, live.config.bubble {
                LabeledSlider(title: "Größe der Webcam", value: $live.config.bubbleSize, range: 0.12...0.9, format: { "\(Int($0 * 100)) %" })
            }
        }
    }

    /// Less often changed things, folded away so that the window stays small.
    private var extras: some View {
        DisclosureGroup(isExpanded: $extrasOpen) {
            VStack(alignment: .leading, spacing: 8) {
                if live.config.scene == .source {
                    Picker("Rahmen", selection: $live.config.mockup) {
                        Text("Ohne").tag(MockupKind?.none)
                        ForEach(MockupKind.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                    .help("Zeigt die Quelle auf einem Laptop, Tablet, Fernseher, im Theater, Kino oder Bilderrahmen")
                }
                HStack {
                    Toggle("Virtueller Hintergrund", isOn: Binding(get: { live.config.background == true }, set: { on in
                        if on && live.backgroundFile == nil { live.chooseBackground() } else { live.config.background = on }
                    }))
                    .help("Stellt dich ohne Greenscreen frei und zeigt ein Bild hinter dir")
                    Spacer()
                    Button(live.backgroundFile == nil ? "Bild wählen …" : "Anderes Bild …") { live.chooseBackground() }
                }
                if live.config.background == true {
                    HStack(spacing: 14) {
                        LabeledSlider(title: "Kante", value: Binding(get: { live.config.backgroundEdge ?? 0.5 }, set: { live.config.backgroundEdge = $0 }),
                                      range: 0.1...0.9, format: { "\(Int($0 * 100)) %" })
                            .help("Höher: Der Rand liegt enger an dir, weniger vom Zimmer bleibt stehen. Niedriger: Mehr von Haaren und Rand bleibt erhalten.")
                        LabeledSlider(title: "Beruhigen", value: Binding(get: { live.config.backgroundCalm ?? 0.5 }, set: { live.config.backgroundCalm = $0 }),
                                      range: 0...0.9, format: { "\(Int($0 * 100)) %" })
                            .help("Höher: Der Rand flackert weniger, zieht bei schnellen Bewegungen aber etwas nach.")
                    }
                }
                HStack {
                    Toggle("Logo", isOn: Binding(get: { live.config.logoOn == true }, set: { on in
                        if on && live.config.logo == nil { live.chooseLogo() } else { live.config.logoOn = on }
                    }))
                    Spacer()
                    Button(live.config.logo == nil ? "Logo wählen …" : "Anderes Logo …") { live.chooseLogo() }
                }
                if live.config.logoOn == true, live.config.logo != nil {
                    Picker("Ecke", selection: Binding(get: { live.config.logo?.corner ?? .topRight }, set: { live.config.logo?.corner = $0 })) {
                        ForEach(CameraCorner.allCases) { Text($0.label).tag($0) }
                    }
                    LabeledSlider(title: "Größe des Logos", value: Binding(get: { live.config.logo?.size ?? 0.14 }, set: { live.config.logo?.size = $0 }),
                                  range: 0.05...0.4, format: { "\(Int($0 * 100)) %" })
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Rahmen, Hintergrund und Logo").font(.subheadline.weight(.semibold))
        }
    }

    @ViewBuilder
    private var effects: some View {
        if live.isDeviceSource {
            Toggle("iPad-Ton am Mac hören", isOn: $live.hearDevice)
                .help("Spielt den Ton des iPads am Mac ab. So kann ihn auch das Meeting-Programm mitsenden, wenn dort „Computerton teilen“ an ist.")
        } else {
            HStack(spacing: 16) {
                Toggle("Klick-Effekte", isOn: $live.config.clicks)
                Toggle("Mausspur", isOn: $live.config.trail)
                Toggle("Tastenkürzel", isOn: Binding(get: { live.config.keys == true }, set: { live.setKeys($0) }))
                    .help("Zeigt gedrückte Tastenkombinationen mit ⌘, ⌃ oder ⌥ im Bild. Normales Tippen wird nie angezeigt.")
            }
        }
    }

    private var memes: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Memes").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Position", selection: $live.config.memeSpot) {
                    ForEach(MemeSpot.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Wo die Memes erscheinen")
            }
            MemeBoardView(usesKeys: true) { live.playMeme($0) }
        }
    }

    private var recording: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic").foregroundStyle(.secondary).help("Mikrofon für die Aufnahme")
            Picker("Mikrofon", selection: $live.microphoneID) {
                Text("Aus").tag("")
                ForEach(app.microphones, id: \.uniqueID) { m in Text(m.localizedName).tag(m.uniqueID) }
            }
            .labelsHidden()
            .disabled(live.isRecording)
            .help("Mikrofon für die Aufnahme (das Meeting-Programm benutzt sein eigenes)")
            Button { live.toggleRecording() } label: {
                Label(live.isRecording ? formatTime(live.recordingTime) : "Aufnehmen", systemImage: live.isRecording ? "stop.circle.fill" : "record.circle")
                    .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .tint(live.isRecording ? Theme.record : Theme.brand)
            .keyboardShortcut("r", modifiers: [])
            .help("Das Live-Bild als neues Projekt aufnehmen (Taste R)")
        }
    }
}

/// What stays at the edge of the screen while the control window is folded away.
struct LiveDrawerHandle: View {
    @ObservedObject var live: LiveModel
    let atRight: Bool

    var body: some View {
        Button { live.expand() } label: {
            VStack(spacing: 7) {
                Circle().fill(live.isRecording ? Theme.record : Theme.record.opacity(0.55)).frame(width: 8, height: 8)
                Image(systemName: atRight ? "chevron.left" : "chevron.right").font(.system(size: 12, weight: .bold))
                Text("Live").font(.system(size: 10, weight: .semibold)).fixedSize().rotationEffect(.degrees(atRight ? -90 : 90)).frame(height: 24)
            }
            .foregroundStyle(.white)
            .frame(width: LiveDrawer.handleSize.width, height: LiveDrawer.handleSize.height)
            .background(UnevenRoundedRectangle(topLeadingRadius: atRight ? 11 : 0, bottomLeadingRadius: atRight ? 11 : 0,
                                               bottomTrailingRadius: atRight ? 0 : 11, topTrailingRadius: atRight ? 0 : 11, style: .continuous)
                .fill(Theme.brandDeep))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Live-Steuerung wieder ausklappen")
    }
}
