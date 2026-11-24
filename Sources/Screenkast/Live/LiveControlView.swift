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

/// The measured height of the control window's content.
final class LivePanelHeight: ObservableObject {
    @Published var content: CGFloat = 700

    struct Key: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    /// The visible height of the screen minus the title bar and a margin.
    @MainActor static var most: CGFloat { ((NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900) - 28 - 24 }
}

/// The control window: never part of the picture that is shared.
struct LiveControlView: View {
    @ObservedObject var live: LiveModel
    @ObservedObject var app: AppModel
    @ObservedObject private var meetingCamera = VirtualCamera.shared
    @ObservedObject private var meetingMic = VirtualMicrophone.shared
    @AppStorage("liveExtrasOpen") private var extrasOpen = false

    private let width: CGFloat = 400
    private var previewHeight: CGFloat { (width - 28) * 9 / 16 }

    @StateObject private var height = LivePanelHeight()

    /// Never taller than the screen: then the content scrolls.
    var body: some View {
        ScrollView(.vertical) {
            content
                .background(GeometryReader { g in Color.clear.preference(key: LivePanelHeight.Key.self, value: g.size.height) })
        }
        .scrollIndicators(.automatic)
        .frame(width: width, height: min(height.content, LivePanelHeight.most))
        .onPreferenceChange(LivePanelHeight.Key.self) { value in
            MainActor.assumeIsolated { if abs(height.content - value) > 0.5 { height.content = value } }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            preview
            if let lost = live.sourceLost {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(lost).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Wieder aufnehmen") { live.restartSource() }
                        .controlSize(.small)
                        .help("Die gewählte Quelle wieder aufnehmen")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.14)))
            }
            scenes
            sourceRows
            extras
            effects
            LiveOverlayStrip(live: live, library: live.overlays)
            memes
            recording
            LiveSoundStrip(live: live, audio: live.audio)
            meetingSection
            LiveRemoteSection(remote: live.remote)
            if let message = live.message {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if meetingCamera.status != .ready {
                Text("Oder im Meeting den Bildschirm teilen mit dem Fenster „\(LiveProgramWindow.title)“. Dieses Steuerfenster ist nie zu sehen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            }
            .padding(.top, 6)
        } label: {
            Text("Rahmen und Hintergrund").font(.subheadline.weight(.semibold))
        }
    }

    /// The iPad's sound is in the mixer (Ton): there it gets its volume for the meeting and the ear.
    @ViewBuilder
    private var effects: some View {
        if !live.isDeviceSource {
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
            .help("Mikrofon für die Aufnahme und für das Mikrofon „\(VirtualCameraIDs.cameraName)“ im Meeting")
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

extension LiveControlView {
    /// Camera and microphone "Erklärbär" for meeting programs: each set up once, then switched on and off here.
    @ViewBuilder
    var meetingSection: some View {
        let cameraShown: Bool = { if case .unavailable = meetingCamera.status { return false } else { return true } }()
        let micShown: Bool = { if case .unavailable = meetingMic.status { return false } else { return true } }()
        if cameraShown || micShown {
            VStack(alignment: .leading, spacing: 5) {
                Text("In Meetings als „\(VirtualCameraIDs.cameraName)“").font(.subheadline.weight(.semibold))
                if cameraShown {
                    meetingRow(icon: "web.camera", title: "Kamera", running: meetingCamera.status == .ready && meetingCamera.sending
                               && live.meetingCameraState == .connected) { meetingCameraControl }
                }
                if micShown {
                    meetingRow(icon: "mic", title: "Mikrofon", running: meetingMic.status == .ready && meetingMic.sending
                               && live.meetingMicState == .running) { meetingMicControl }
                }
                ForEach(meetingDetails, id: \.text) { detail in
                    Text(detail.text)
                        .font(.caption)
                        .foregroundStyle(detail.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.lane))
        }
    }

    private func meetingRow<Control: View>(icon: String, title: String, running: Bool, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            Text(title)
            if running {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                    .help("Läuft: Im Meeting-Programm „\(VirtualCameraIDs.cameraName)“ wählen.")
            }
            Spacer()
            control()
        }
        .frame(minHeight: 22)
    }

    @ViewBuilder
    private var meetingCameraControl: some View {
        switch meetingCamera.status {
        case .checking, .installing:
            ProgressView().controlSize(.small)
        case .notInstalled:
            Button("Einrichten …") { meetingCamera.install() }
                .help("Richtet die Kamera „\(VirtualCameraIDs.cameraName)“ ein. macOS fragt einmal nach deiner Erlaubnis.")
        case .needsApproval:
            Button("Systemeinstellungen …") { meetingCamera.openSettings() }
        case .failed:
            Button("Erneut versuchen") { meetingCamera.install() }
        case .ready:
            switchAndMenu(isOn: $meetingCamera.sending, help: "Das Live-Bild an die Kamera „\(VirtualCameraIDs.cameraName)“ senden",
                          remove: "Kamera „\(VirtualCameraIDs.cameraName)“ entfernen …") { meetingCamera.remove() }
        case .unavailable:
            EmptyView()
        }
    }

    @ViewBuilder
    private var meetingMicControl: some View {
        switch meetingMic.status {
        case .checking, .installing:
            ProgressView().controlSize(.small)
        case .notInstalled:
            Button("Einrichten …") { meetingMic.install() }
                .help("Richtet das Mikrofon „\(VirtualCameraIDs.cameraName)“ ein. macOS fragt einmal nach dem Administrator-Passwort, der Ton setzt dabei kurz aus.")
        case .outdated:
            Button("Aktualisieren …") { meetingMic.install() }
        case .failed:
            Button("Erneut einrichten …") { meetingMic.install() }
        case .ready:
            switchAndMenu(isOn: $meetingMic.sending, help: "Den Ton aus dem Mischpult an das Mikrofon „\(VirtualCameraIDs.cameraName)“ senden",
                          remove: "Mikrofon „\(VirtualCameraIDs.cameraName)“ entfernen …") { meetingMic.remove() }
        case .unavailable:
            EmptyView()
        }
    }

    private func switchAndMenu(isOn: Binding<Bool>, help: String, remove: String, removeAction: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Toggle("Senden", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(help)
            Menu {
                Button(remove, action: removeAction)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// Notes below the rows; only what needs attention.
    private var meetingDetails: [(text: String, warning: Bool)] {
        let name = "„\(VirtualCameraIDs.cameraName)“"
        var result: [(String, Bool)] = []
        switch meetingCamera.status {
        case .notInstalled where meetingMic.status == .notInstalled:
            result.append(("Ohne Bildschirm teilen: Erklärbär wird zu Kamera und Mikrofon \(name), die du in Zoom, Teams oder Meet auswählst.", false))
        case .needsApproval:
            result.append(("Kamera erlauben: Systemeinstellungen › Allgemein › Anmeldeobjekte & Erweiterungen › Kameraerweiterungen › Erklärbär einschalten.", true))
        case .failed(let text):
            result.append((text, true))
        case .ready where meetingCamera.sending && live.meetingCameraState == .missing:
            result.append(("Die Kamera \(name) meldet sich nicht. Nach einem Update startet macOS sie manchmal erst nach einem Neustart des Macs.", true))
        default:
            break
        }
        switch meetingMic.status {
        case .outdated:
            result.append(("Eine neuere Fassung des Mikrofons liegt bei. Aktualisieren braucht das Administrator-Passwort.", false))
        case .failed(let text):
            result.append((text, true))
        case .ready where meetingMic.sending:
            switch live.meetingMicState {
            case .missing: result.append(("Das Mikrofon \(name) meldet sich nicht. Ein Neustart des Macs hilft meist.", true))
            case .failed: break   // shown with the sound
            default:
                if live.microphoneID.isEmpty {
                    result.append(("Kein Mikrofon gewählt (neben „Aufnehmen“): Ins Meeting geht nur, was im Mischpult eingeschaltet ist.", true))
                }
            }
        default:
            break
        }
        return result
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
