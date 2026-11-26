import SwiftUI
import ScreenCaptureKit

/// Which small window of the start page is open (no @State without macros).
final class HomeSheetState: ObservableObject {
    @Published var open: HomeSheet?
}

enum HomeSheet: String, Identifiable {
    case record, screenshot, newProject
    var id: String { rawValue }
}

/// One of the big tiles of the start page.
struct HomeTile: View {
    let title: String
    let detail: String
    let icon: String
    let color: Color
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @StateObject private var hover = HoverFlag()

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                IconTile(icon: icon, color: color, size: 40)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hover.on && enabled ? color : Theme.stroke, lineWidth: hover.on && enabled ? 2 : 1))
            .shadow(color: .black.opacity(hover.on && enabled ? 0.18 : 0.06), radius: hover.on ? 8 : 3, y: 2)
            .scaleEffect(hover.on && enabled ? 1.015 : 1)
            .animation(.easeOut(duration: 0.12), value: hover.on)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

/// Head of a small window of the start page.
private struct SetupHeader: View {
    let title: String
    let detail: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            IconTile(icon: icon, color: color, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.title3.weight(.bold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

/// "Bildschirm aufnehmen": source, sound, camera and the start.
struct RecordSetupView: View {
    @EnvironmentObject var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SetupHeader(title: "Bildschirm aufnehmen", detail: "Zooms, Cursor und Hintergrund kommen danach automatisch dazu.",
                        icon: "record.circle", color: Theme.record)
            Form {
                HStack(spacing: 6) {
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
                        if !model.deviceChoices.isEmpty {
                            Section("iPad und iPhone am Kabel") {
                                ForEach(model.deviceChoices, id: \.id) { d in
                                    Text(d.name).tag(Optional(SourceSelection.device(d.id)))
                                }
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
                        Task { await model.refreshSources() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .help("Bildschirme, Fenster, Mikrofone und Kameras neu einlesen")
                }
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
                Toggle(model.isDeviceSelected ? "Ton vom iPad" : "Systemaudio", isOn: $model.systemAudio)
                    .help(model.isDeviceSelected ? "Den Ton des iPads über das Kabel mit aufnehmen " : "Ton von Apps und Browser mit aufnehmen")
                if model.isDeviceSelected {
                    Toggle("Am Mac mithören", isOn: $model.hearDevice)
                        .help("Spielt den Ton des iPads während der Aufnahme live am Mac ab. Mit eingeschaltetem Mikrofon am besten Kopfhörer benutzen.")
                    Text("iPad entsperren und vor dem Start so halten, wie es aufgenommen werden soll (hoch oder quer). Während der Aufnahme zeigt ein Fenster das iPad live am Mac. QuickTime Player darf das iPad nicht gleichzeitig benutzen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker("Kamera", selection: $model.cameraID) {
                    Text("Aus").tag("")
                    ForEach(model.cameras, id: \.uniqueID) { cam in
                        Text(cam.localizedName).tag(cam.uniqueID)
                    }
                }
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
                        .frame(width: 120, height: 120)
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
                close()
                Task { await model.startRecording() }
            }
            .disabled(model.isBusy || model.selection == nil)

            HStack {
                Text("\(GlobalHotKey.defaultDisplay) startet und stoppt auch von überall.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen", action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear { Task { await model.setCameraPreview(active: true) } }
        .onDisappear { Task { await model.setCameraPreview(active: false) } }
    }
}

/// "Screenshot": an area, a window or a whole screen.
struct ScreenshotSetupView: View {
    @EnvironmentObject var model: AppModel
    let close: () -> Void
    @StateObject private var choice = ScreenshotChoice()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SetupHeader(title: "Screenshot", detail: "Danach mit Pfeilen, Text, Markierungen und Hintergrund bearbeiten.",
                        icon: "camera.viewfinder", color: .blue)
            VStack(spacing: 10) {
                option(icon: "rectangle.dashed", title: "Bereich", detail: "Mit der Maus aufziehen – auch von überall mit \(GlobalHotKey.screenshotDisplay)") {
                    take(.region)
                }
                HStack(spacing: 10) {
                    option(icon: "macwindow", title: "Fenster", detail: windows.isEmpty ? "Keine Fenster gefunden" : "Wählen und aufnehmen") {
                        if let w = windows.first(where: { $0.windowID == choice.windowID }) ?? windows.first { take(.window(w)) }
                    }
                    .disabled(windows.isEmpty)
                    Picker("Fenster", selection: Binding(get: { choice.windowID ?? windows.first?.windowID }, set: { choice.windowID = $0 })) {
                        ForEach(windows, id: \.windowID) { w in Text(model.windowName(w)).lineLimit(1).tag(Optional(w.windowID)) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .disabled(windows.isEmpty)
                }
                HStack(spacing: 10) {
                    option(icon: "display", title: "Ganzer Bildschirm", detail: model.displays.count > 1 ? "Bildschirm wählen" : "Alles, was zu sehen ist") {
                        if let d = model.displays.first(where: { $0.displayID == choice.displayID }) ?? model.displays.first { take(.display(d)) }
                    }
                    .disabled(model.displays.isEmpty)
                    if model.displays.count > 1 {
                        Picker("Bildschirm", selection: Binding(get: { choice.displayID ?? model.displays.first?.displayID }, set: { choice.displayID = $0 })) {
                            ForEach(model.displays, id: \.displayID) { d in Text(model.displayName(d)).tag(Optional(d.displayID)) }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Abbrechen", action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task { await model.refreshSources() }
    }

    private var windows: [SCWindow] { model.windows + model.otherWindows }

    private func option(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(.blue).frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.raised))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The small window goes first, so that nothing of it is in the picture.
    private func take(_ kind: AppModel.ScreenshotKind) {
        close()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await model.takeScreenshot(kind)
        }
    }
}

final class ScreenshotChoice: ObservableObject {
    @Published var windowID: CGWindowID?
    @Published var displayID: CGDirectDisplayID?
}

/// "Neues Projekt": an empty canvas in a format.
struct NewProjectSetupView: View {
    @EnvironmentObject var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SetupHeader(title: "Neues Projekt", detail: "Eine leere Fläche für Clips, Bilder, Texte und Aufnahmen. Welches Format?",
                        icon: "plus.rectangle.on.rectangle", color: Theme.brand)
            HStack(spacing: 12) {
                format(.wide, "Querformat", "16:9 · YouTube", CGSize(width: 64, height: 36))
                format(.vertical, "Hochformat", "9:16 · Reels, TikTok", CGSize(width: 27, height: 48))
                format(.square, "Quadratisch", "1:1 · Instagram", CGSize(width: 44, height: 44))
                format(.classic, "4:3", "Präsentationen", CGSize(width: 52, height: 39))
            }
            HStack {
                Text("Eigene Videos: Kachel „Video importieren“.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen", action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 580)
    }

    private func format(_ aspect: OutputAspect, _ title: String, _ detail: String, _ size: CGSize) -> some View {
        Button {
            close()
            model.newEmptyProject(aspect: aspect)
        } label: {
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.brand, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.brand.opacity(0.12)))
                    .frame(width: size.width, height: size.height)
                    .frame(height: 52)
                VStack(spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
