import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import ScreenCaptureKit

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var drop = LibraryDropState()
    @StateObject private var sheets = HomeSheetState()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            header
            permissionNotice
            tiles
            libraryPanel
                .card()
        }
        .padding(Theme.gap)
        .background(Theme.canvas)
        .sheet(item: $sheets.open) { sheet in
            switch sheet {
            case .record: RecordSetupView(close: { sheets.open = nil }).environmentObject(model)
            case .screenshot: ScreenshotSetupView(close: { sheets.open = nil }).environmentObject(model)
            case .newProject: NewProjectSetupView(close: { sheets.open = nil }).environmentObject(model)
            }
        }
    }

    // MARK: Start

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("Erklärbär").font(.title2.weight(.bold))
                Text("Was möchtest du tun?").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            HelpButton(topic: "start")
                .buttonStyle(GhostButtonStyle())
            SettingsLink {
                Label("Einstellungen", systemImage: "gearshape")
            }
            .buttonStyle(GhostButtonStyle())
            .help("Steuerleiste, Menüleiste, Start beim Anmelden, Speicherort und Kurzbefehle (⌘,)")
        }
        .padding(.horizontal, 4)
    }

    /// The six things to do, as big tiles.
    private var tiles: some View {
        let busy = model.isBusy || model.isRecording
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
            HomeTile(title: "Bildschirm aufnehmen", detail: "Bildschirm, Fenster, Bereich oder iPad", icon: "record.circle", color: Theme.record) {
                sheets.open = .record
            }
            .disabled(busy || model.live != nil)
            .help("Quelle, Mikrofon und Kamera wählen und aufnehmen – Zooms, Cursor und Hintergrund kommen danach automatisch dazu (\(GlobalHotKey.defaultDisplay) startet von überall)")
            HomeTile(title: "Screenshot", detail: "Bereich, Fenster oder Bildschirm", icon: "camera.viewfinder", color: .blue) {
                sheets.open = .screenshot
            }
            .disabled(model.isRecording)
            .help("Bildschirmfoto mit Pfeilen, Text, Markierungen und Hintergrund (\(GlobalHotKey.screenshotDisplay) für einen Bereich)")
            HomeTile(title: "Live für Meetings", detail: "Zoom, Teams, Meet, ViKo", icon: "dot.radiowaves.left.and.right", color: .pink) {
                Task { await model.startLive() }
            }
            .disabled(busy || model.live != nil)
            .help("Live-Bild für Meetings: Szenen umschalten, Webcam einblenden, Memes, nebenbei aufnehmen")
            HomeTile(title: "Neues Projekt", detail: "Leere Fläche in einem Format", icon: "plus.rectangle.on.rectangle", color: Theme.brand) {
                sheets.open = .newProject
            }
            .disabled(model.creatingProject || model.isRecording)
            .help("Mit einer leeren Fläche für Clips, Bilder und Texte beginnen")
            HomeTile(title: "Video importieren", detail: "Eigene Videodatei schneiden", icon: "square.and.arrow.down", color: .orange) {
                model.newProjectFromVideo()
            }
            .disabled(model.creatingProject || model.isRecording)
            .help("Ein eigenes Video als neues Projekt öffnen – oder einfach auf die Projektliste ziehen")
            HomeTile(title: "Video aus dem Internet", detail: "YouTube, Instagram, Vimeo & Co.", icon: "globe", color: .teal) {
                model.newProjectFromURL()
            }
            .disabled(model.creatingProject || model.isRecording)
            .help("Adresse eines Videos einfügen – es wird geladen und als neues Projekt geöffnet. Ein Link lässt sich auch auf die Projektliste ziehen.")
        }
    }

    @ViewBuilder
    private var permissionNotice: some View {
        if let problem = model.permissionProblem {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Berechtigung fehlt").font(.headline)
                    Text(problem).font(.callout)
                    Text("Tipp: Im Hinweis von macOS auf „Systemeinstellungen öffnen“ klicken – dann schließt er sich von selbst.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Systemeinstellungen öffnen") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        } else if model.permissionGrantedNeedsRestart {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.title3)
                Text("Berechtigung erteilt – macOS übernimmt sie erst nach einem Neustart von Erklärbär.").font(.callout)
                Spacer()
                Button("Erklärbär neu starten") { model.relaunch() }
            }
            .padding(12)
            .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
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
                ProjectFolderMenu(model: model)
            }
            if model.library.isEmpty {
                ContentUnavailableView("Noch keine Projekte",
                                       systemImage: "film.stack",
                                       description: Text("Starte oben eine Aufnahme oder lade ein Video – oder lege hier ein eigenes Video bzw. einen Link ab. Den Speicherort wählst du rechts oben."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 28, alignment: .top)], spacing: 30) {
                        ForEach(model.library, id: \.self) { url in
                            ProjectCard(url: url)
                        }
                    }
                    // Room for the hover zoom and shadow at the edges.
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
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
                    .overlay(Label("Video oder Link ablegen – wird zum neuen Projekt", systemImage: "film.stack").font(.title3.bold()))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        // An own video dropped onto the list becomes a project – a link (from the browser's
        // address bar) is loaded from the internet first.
        .onDrop(of: [.movie, .fileURL, .url], isTargeted: $drop.targeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                if url.isFileURL {
                    guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) else { return }
                    Task { @MainActor in model.newProject(fromVideo: url) }
                } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    Task { @MainActor in model.newProjectFromURL(url.absoluteString) }
                }
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

struct ProjectCard: View {
    @EnvironmentObject var model: AppModel
    let url: URL
    @StateObject private var card = CardModel()
    private var offline: Bool { ProjectLocations.isOffline(url) }
    private var moving: Bool { model.movingProjects.contains(url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // The frame sets the size; the picture fills it and is cut off at its edges (a picture
            // filling a ZStack would make the card as large as the picture and overlap its neighbors).
            Theme.raised
                .aspectRatio(16 / 10, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
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
            Button("Umbenennen …") { model.renameProject(url) }
                .disabled(offline || moving)
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
