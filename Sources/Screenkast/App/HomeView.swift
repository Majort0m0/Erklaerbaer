import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import ScreenCaptureKit

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var drop = LibraryDropState()

    var body: some View {
        HStack(spacing: Theme.gap) {
            ScrollView(.vertical) { recordPanel }
                .scrollIndicators(.never)
                .frame(width: 360)
                .card()
            libraryPanel
                .card()
        }
        .padding(Theme.gap)
        .background(Theme.canvas)
    }

    // MARK: Record

    private var recordPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Neue Aufnahme").font(.title2.weight(.bold))
                    Text("Bildschirm, Fenster oder Bereich")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Zooms, Cursor und Hintergrund kommen danach automatisch dazu.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem = model.permissionProblem {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Berechtigung fehlt", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(problem).font(.callout)
                    Text("Tipp: Im Hinweis von macOS auf „Systemeinstellungen öffnen“ klicken – dann schließt er sich von selbst.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Systemeinstellungen öffnen") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .padding(12)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            } else if model.permissionGrantedNeedsRestart {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Berechtigung erteilt", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text("macOS übernimmt sie erst nach einem Neustart von Erklärbär (dabei verschwindet auch sein Hinweisfenster).")
                        .font(.callout)
                    Button("Erklärbär neu starten") { model.relaunch() }
                }
                .padding(12)
                .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }

            Form {
                Picker("Quelle", selection: $model.selection) {
                    if case .region(let id, let rect) = model.selection {
                        Section("Bereich") {
                            Text(model.regionName(id, rect)).tag(Optional(SourceSelection.region(id, rect)))
                        }
                    }
                    Section("Bildschirme") {
                        ForEach(model.displays, id: \.displayID) { d in
                            Text(model.displayName(d)).tag(Optional(SourceSelection.display(d.displayID)))
                        }
                    }
                    Section("Fenster") {
                        ForEach(model.windows, id: \.windowID) { w in
                            Text(model.windowName(w)).lineLimit(1).tag(Optional(SourceSelection.window(w.windowID)))
                        }
                    }
                    if !model.otherWindows.isEmpty {
                        Section("Weitere Fenster (Stage Manager, andere Schreibtische)") {
                            ForEach(model.otherWindows, id: \.windowID) { w in
                                Text(model.windowName(w)).lineLimit(1).tag(Optional(SourceSelection.window(w.windowID)))
                            }
                        }
                    }
                }
                .help("Ein gewähltes Fenster wird beim Start automatisch nach vorne geholt")
                Button {
                    Task { await model.chooseRegion() }
                } label: {
                    Label("Bereich des Bildschirms wählen …", systemImage: "rectangle.dashed")
                }
                .buttonStyle(.link)
                Picker("Mikrofon", selection: $model.microphoneID) {
                    Text("Aus").tag("")
                    ForEach(model.microphones, id: \.uniqueID) { mic in
                        Text(mic.localizedName).tag(mic.uniqueID)
                    }
                }
                Toggle("Systemaudio", isOn: $model.systemAudio)
                    .help("Ton von Apps und Browser mit aufnehmen")
                Picker("Zweites Fenster", selection: $model.overlayWindowID) {
                    Text("Aus").tag(CGWindowID?.none)
                    ForEach(model.windows + model.otherWindows, id: \.windowID) { w in
                        Text(model.windowName(w)).lineLimit(1).tag(Optional(w.windowID))
                    }
                }
                .help("Wird gleichzeitig aufgenommen und erscheint im Editor als Bild im Bild – verschiebbar, zeitweise ein- und ausblendbar")
                Toggle("Countdown 3-2-1", isOn: $model.countdown)
                    .help("Zählt vor dem Start herunter – der Countdown wird nicht mit aufgenommen")
                Toggle("Tastenkürzel einblenden", isOn: $model.recordShortcuts)
                    .help("Zeichnet nur Kürzel mit ⌘, ⌃ oder ⌥ auf – normal getippter Text wird nie gespeichert")
                LabeledContent("Speichern in") { ProjectFolderMenu(model: model) }
                Picker("Kamera", selection: $model.cameraID) {
                    Text("Aus").tag("")
                    ForEach(model.cameras, id: \.uniqueID) { cam in
                        Text(cam.localizedName).tag(cam.uniqueID)
                    }
                }
            }
            .formStyle(.columns)

            if model.recordShortcuts && !model.shortcutsTrusted {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Für Tastenkürzel braucht Erklärbär die Bedienungshilfen-Berechtigung.", systemImage: "keyboard.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    HStack {
                        Button("Einstellungen öffnen") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("Erneut prüfen") { model.shortcutsTrusted = KeyShortcuts.isTrusted(prompt: false) }
                    }
                    .controlSize(.small)
                }
            }

            if !model.cameraID.isEmpty {
                if model.cameraDenied {
                    Label("Kein Kamerazugriff – bitte in den Systemeinstellungen erlauben.", systemImage: "video.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    CameraPreviewView(session: model.camera.session)
                        .frame(width: 150, height: 150)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1.5))
                        .background(Circle().fill(.black).shadow(color: .black.opacity(0.3), radius: 8, y: 3))
                        .frame(maxWidth: .infinity)
                }
            }

            DisclosureGroup("Sprechernotizen\(model.notes.isEmpty ? "" : " ✓")") {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $model.notes)
                        .font(.callout)
                        .frame(height: 90)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    Toggle("Während der Aufnahme einblenden", isOn: $model.showNotes)
                        .font(.callout)
                    Text("Ein schwebendes Fenster, das nicht mit aufgenommen wird – mit Schriftgröße und Teleprompter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            RecordButton(title: model.isBusy ? "Startet …" : "Aufnahme starten", shortcut: GlobalHotKey.defaultDisplay) {
                Task { await model.startRecording() }
            }
            .disabled(model.isBusy || model.selection == nil)

            HStack {
                Menu {
                    ScreenshotMenuItems(model: model)
                } label: {
                    Label("Screenshot", systemImage: "camera.viewfinder")
                }
                .fixedSize()
                .help("Bildschirmfoto mit Pfeilen, Text, Markierungen und Hintergrund (\(GlobalHotKey.screenshotDisplay) für einen Bereich)")
                Spacer()
            }

            VStack(spacing: 0) {
                OptionRow(title: "Steuerleiste auf dem Bildschirm", icon: "menubar.dock.rectangle", isOn: $model.showControlBar)
                    .help("Schwebende Leiste mit Quelle, Mikrofon, Kamera, Start, Pause und Stopp – sie wird nie mit aufgenommen")
                Divider().padding(.leading, 34)
                OptionRow(title: "In der Menüleiste anzeigen", icon: "dot.viewfinder", isOn: $model.showInMenuBar)
                    .help("Symbol oben rechts: Aufnahme und Screenshot starten, auch bei geschlossenem Fenster")
                Divider().padding(.leading, 34)
                OptionRow(title: "Beim Anmelden starten", icon: "power",
                          isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .help("Erklärbär startet mit dem Mac – mit Menüleisten-Symbol ohne Fenster")
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "keyboard").foregroundStyle(.tertiary)
                Text("\(GlobalHotKey.defaultDisplay) startet und stoppt von überall – oder über das ●-Symbol in der Menüleiste.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    Task { await model.refreshSources() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(GhostButtonStyle())
                .help("Bildschirme, Fenster, Mikrofone und Kameras neu einlesen")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(22)
        .onAppear { Task { await model.setCameraPreview(active: true) } }
        .onDisappear { Task { await model.setCameraPreview(active: false) } }
    }

    // MARK: Library

    private var libraryPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Projekte").font(.title2.weight(.bold))
                    Text(model.library.isEmpty ? "Noch leer" : model.library.count == 1 ? "1 Projekt" : "\(model.library.count) Projekte")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.creatingProject { ProgressView().controlSize(.small) }
                Button {
                    NSWorkspace.shared.open(Project.libraryURL)
                } label: {
                    Label("Im Finder", systemImage: "folder")
                }
                .buttonStyle(GhostButtonStyle())
                .help("Projektordner ~/Filme/Erklärbär im Finder öffnen")
                HelpButton(topic: "start")
                    .buttonStyle(GhostButtonStyle())
                ProjectFolderMenu(model: model)
                NewProjectMenu()
                    .fixedSize()
                    .disabled(model.creatingProject)
            }
            if model.library.isEmpty {
                ContentUnavailableView("Noch keine Projekte",
                                       systemImage: "film.stack",
                                       description: Text("Starte links eine Aufnahme – oder lege hier ein eigenes Video ab bzw. wähle „Neues Projekt“. Den Speicherort wählst du oben."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 18)], spacing: 22) {
                        ForEach(model.library, id: \.self) { url in
                            ProjectCard(url: url)
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.brand, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .background(Theme.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(Label("Video ablegen – wird zum neuen Projekt", systemImage: "film.stack").font(.title3.bold()))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        // An own video dropped onto the list becomes a project.
        .onDrop(of: [.movie, .fileURL], isTargeted: $drop.targeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) else { return }
                Task { @MainActor in model.newProject(fromVideo: url) }
            }
            return true
        }
    }

    private var dropTargeted: Bool { drop.targeted }
}

/// Drop highlight of the project list (no @State without macros).
final class LibraryDropState: ObservableObject {
    @Published var targeted = false
}

/// "Neues Projekt": an own video as the main track, or an empty canvas in a format.
struct NewProjectMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            Button("Aus eigenem Video …") { model.newProjectFromVideo() }
            Menu("Leeres Projekt") {
                Button("Querformat 16:9 (YouTube)") { model.newEmptyProject(aspect: .wide) }
                Button("Hochformat 9:16 (Reels, TikTok)") { model.newEmptyProject(aspect: .vertical) }
                Button("Quadratisch 1:1") { model.newEmptyProject(aspect: .square) }
                Button("4:3") { model.newEmptyProject(aspect: .classic) }
            }
        } label: {
            Label("Neues Projekt", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .tint(Theme.brand)
        .help("Eigenes Video schneiden oder mit einer leeren Fläche für Clips, Bilder und Texte beginnen")
    }
}

struct ProjectCard: View {
    @EnvironmentObject var model: AppModel
    let url: URL
    @StateObject private var card = CardModel()
    private var offline: Bool { ProjectLocations.isOffline(url) }
    private var moving: Bool { model.movingProjects.contains(url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                Theme.raised
                if let thumbnail = card.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: card.info?.blank == true ? "rectangle.dashed" : "film")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let info = card.info {
                    Text(formatTime(info.duration, fractional: false))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(8)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(card.hovering ? Theme.brand : Theme.stroke, lineWidth: card.hovering ? 2 : 1))
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised)
                .shadow(color: .black.opacity(card.hovering ? 0.18 : 0.06), radius: card.hovering ? 12 : 4, y: card.hovering ? 6 : 2))
            .scaleEffect(card.hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: card.hovering)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let info = card.info {
                    Text("\(info.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(info.sourceName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { card.hovering = $0 }
        .onTapGesture { if !moving { model.open(url: url) } }
        .opacity(offline ? 0.55 : 1)
        .overlay(alignment: .top) {
            if moving || offline {
                Label(moving ? "Wird verschoben …" : "\(ProjectLocations.volumeName(url) ?? "Laufwerk") nicht verbunden",
                      systemImage: moving ? "arrow.right.circle" : "externaldrive.badge.xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.65)))
                    .padding(.top, 8)
            }
        }
        .contextMenu {
            Button("Öffnen") { model.open(url: url) }
                .disabled(offline || moving)
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .disabled(offline)
            Button("Verschieben nach …") { model.moveProject(url) }
                .disabled(offline || moving)
            Divider()
            if offline {
                Button("Aus der Liste entfernen") {
                    ProjectLocations.forget(url)
                    model.reloadLibrary()
                }
            } else {
                Button("In den Papierkorb", role: .destructive) { model.delete(url: url) }
                    .disabled(moving)
            }
        }
        .task(id: url) { await card.load(url: url) }
    }
}

@MainActor
final class CardModel: ObservableObject {
    @Published var thumbnail: NSImage?
    @Published var info: RecordingInfo?
    @Published var hovering = false

    func load(url: URL) async {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url.appendingPathComponent("recording.json")),
              let info = try? dec.decode(RecordingInfo.self, from: data) else { return }
        self.info = info
        let asset = AVURLAsset(url: url.appendingPathComponent(info.videoFile))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 400)
        if let (cg, _) = try? await gen.image(at: CMTime(seconds: min(0.5, info.duration / 2), preferredTimescale: 600)) {
            thumbnail = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
}

/// Live webcam preview (mirrored like a selfie view).
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        // Mirror via the layer itself: works no matter when the camera connection appears.
        layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The big red record button of the start page.
struct RecordButton: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @StateObject private var hover = HoverFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(.white).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 3).frame(width: 20, height: 20))
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.2)))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.32), Color(red: 0.88, green: 0.15, blue: 0.2)],
                                     startPoint: .top, endPoint: .bottom)))
            .shadow(color: Theme.record.opacity(hover.on && enabled ? 0.45 : 0.25), radius: hover.on ? 10 : 6, y: 3)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .help("Aufnahme starten – auch von überall mit \(shortcut)")
    }
}

/// A switch row in a grouped box (icon, title, switch on the right).
struct OptionRow: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
