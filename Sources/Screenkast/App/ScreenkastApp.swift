import SwiftUI
import AppKit

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") {
            let dir = i + 1 < args.count ? args[i + 1] : NSTemporaryDirectory() + "screenkast-selftest"
            exit(SelfTest.run(outputDirectory: URL(fileURLWithPath: dir)))
        }
        if let i = args.firstIndex(of: "--export"), i + 2 < args.count {
            exit(Analyze.export(projectPath: args[i + 1], outputPath: args[i + 2]))
        }
        if let i = args.firstIndex(of: "--echo"), i + 2 < args.count {
            exit(Analyze.echo(projectPath: args[i + 1], outputPath: args[i + 2]))
        }
        if let i = args.firstIndex(of: "--uisnapshot"), i + 2 < args.count {
            exit(MainActor.assumeIsolated { UISnapshot.run(projectPath: args[i + 1], outputPath: args[i + 2]) })
        }
        if let i = args.firstIndex(of: "--crashrecord"), i + 1 < args.count {
            exit(CrashSelfTest.child(folder: URL(fileURLWithPath: args[i + 1])))   // used by --selftest
        }
        if let i = args.firstIndex(of: "--hangtest") {
            let dir = i + 1 < args.count ? args[i + 1] : NSTemporaryDirectory() + "screenkast-hangtest"
            exit(MainActor.assumeIsolated { HangWatchdog.selfTest(directory: URL(fileURLWithPath: dir)) })
        }
        if let i = args.firstIndex(of: "--breaths"), i + 1 < args.count {
            exit(Analyze.breaths(projectPath: args[i + 1], outputPath: i + 2 < args.count ? args[i + 2] : nil))
        }
        if let i = args.firstIndex(of: "--voice"), i + 1 < args.count {
            exit(Analyze.voice(projectPath: args[i + 1]))
        }
        if let i = args.firstIndex(of: "--newproject"), i + 1 < args.count {
            exit(MainActor.assumeIsolated { ProjectFactory.commandLine(folder: args[i + 1], files: Array(args[(i + 2)...])) })
        }
        if let i = args.firstIndex(of: "--analyze"), i + 1 < args.count {
            exit(Analyze.run(projectPath: args[i + 1]))
        }
        ScreenkastApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Started as a login item with the menu bar entry on: stay in the menu bar, no window.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        guard atLogin, UserDefaults.standard.bool(forKey: "showInMenuBar") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.windows.filter { $0.canBecomeMain }.forEach { $0.close() }
        }
    }
}

struct ScreenkastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Erklärbär", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 660)
                // The canvas color also behind the toolbar: one calm surface with the cards on it.
                .containerBackground(Theme.canvas, for: .window)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            // Undo/redo of the editor; while a text field is being edited, the field's own undo.
            CommandGroup(replacing: .undoRedo) {
                Button("Widerrufen") {
                    if model.editor == nil || EditorKeyHandlerView.isEditingText(in: NSApp.keyWindow) {
                        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                    } else {
                        model.editor?.undo()
                    }
                }
                .keyboardShortcut("z")
                Button("Wiederholen") {
                    if model.editor == nil || EditorKeyHandlerView.isEditingText(in: NSApp.keyWindow) {
                        NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                    } else {
                        model.editor?.redo()
                    }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .windowList) {
                Toggle("Steuerleiste", isOn: $model.showControlBar)
            }
            CommandGroup(replacing: .newItem) {
                // ⌘⇧2 is handled by the global hot key, so no menu shortcut here (it would fire twice).
                Button(model.isRecording ? "Aufnahme stoppen (\(GlobalHotKey.defaultDisplay))" : "Neue Aufnahme (\(GlobalHotKey.defaultDisplay))") {
                    model.toggleRecording()
                }
                Button("Neues Projekt aus eigenem Video …") { model.newProjectFromVideo() }
                Menu("Neues leeres Projekt") {
                    Button("Querformat 16:9") { model.newEmptyProject(aspect: .wide) }
                    Button("Hochformat 9:16") { model.newEmptyProject(aspect: .vertical) }
                    Button("Quadratisch 1:1") { model.newEmptyProject(aspect: .square) }
                    Button("4:3") { model.newEmptyProject(aspect: .classic) }
                }
                Divider()
                Menu("Screenshot") {
                    Button("Bereich … (\(GlobalHotKey.screenshotDisplay))") { Task { await model.takeScreenshot(.region) } }
                    Menu("Fenster") {
                        ForEach(model.windows + model.otherWindows, id: \.windowID) { w in
                            Button(model.windowName(w)) { Task { await model.takeScreenshot(.window(w)) } }
                        }
                    }
                    Menu("Ganzer Bildschirm") {
                        ForEach(model.displays, id: \.displayID) { d in
                            Button(model.displayName(d)) { Task { await model.takeScreenshot(.display(d)) } }
                        }
                    }
                    Divider()
                    Button("Bild bearbeiten …") { model.openImageInScreenshotEditor() }
                }
            }
        }

        MenuBarExtra(isInserted: Binding(get: { model.isRecording || model.showInMenuBar }, set: { _ in })) {
            Group {
                if model.isRecording { RecordingPanel() } else { MenuBarPanel() }
            }
            .environmentObject(model)
        } label: {
            if model.isRecording {
                Text("\(model.isPaused ? "❚❚" : "●") \(formatTime(model.elapsed, fractional: false))")
            } else {
                Image(systemName: "dot.viewfinder")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            AppSettingsView()
                .environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let editor = model.editor {
                EditorView(editor: editor)
                    .id(ObjectIdentifier(editor))
            } else {
                HomeView()
            }
        }
        .tint(Theme.brand)
        .background(Theme.canvas)
        .task {
            await model.refreshSources()
            model.updateControlBar()
        }
        .alert("Erklärbär", isPresented: Binding(get: { model.errorMessage != nil },
                                                  set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// Menu bar panel when not recording: start, screenshot, control bar, open the app.
struct MenuBarPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "dot.viewfinder").foregroundStyle(.secondary)
                Text("Erklärbär").font(.headline)
            }
            Button {
                Task { await model.startRecording() }
            } label: {
                Label("Aufnahme starten (\(GlobalHotKey.defaultDisplay))", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(model.isBusy || model.selection == nil)
            Button {
                Task { await model.takeScreenshot(.region) }
            } label: {
                Label("Screenshot eines Bereichs (\(GlobalHotKey.screenshotDisplay))", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Steuerleiste auf dem Bildschirm", isOn: $model.showControlBar)
            Divider()
            Button("Erklärbär öffnen") {
                openWindow(id: "main")
                NSApp.activate()
            }
            Button("Einstellungen …") {
                NSApp.activate()
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Button("Beenden") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding(14)
        .frame(width: 280)
    }
}

/// App settings (⌘,): menu bar, login item, control bar.
struct AppSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Toggle("In der Menüleiste anzeigen", isOn: $model.showInMenuBar)
            Text("Ein Symbol oben rechts startet Aufnahmen und Screenshots, auch wenn das Fenster geschlossen ist.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Beim Anmelden starten", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Text("Mit Menüleisten-Symbol startet Erklärbär dann ohne Fenster.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Steuerleiste auf dem Bildschirm", isOn: $model.showControlBar)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.vertical, 8)
    }
}

/// Small panel shown from the menu bar while recording.
struct RecordingPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(model.isPaused ? .orange : .red).frame(width: 10, height: 10)
                Text(model.isPaused ? "Pausiert" : "Aufnahme läuft").font(.headline)
                Spacer()
                Text(formatTime(model.elapsed, fractional: false)).monospacedDigit()
            }
            Button {
                Task { await model.stopRecording() }
            } label: {
                Label("Stoppen & bearbeiten", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            Button {
                model.togglePause()
            } label: {
                Label(model.isPaused ? "Fortsetzen" : "Pausieren",
                      systemImage: model.isPaused ? "play.circle" : "pause.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            Button("Verwerfen", role: .destructive) {
                Task { await model.cancelRecording() }
            }
            .frame(maxWidth: .infinity)
            Text("Stoppen auch mit \(GlobalHotKey.defaultDisplay)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 260)
        .onAppear { model.menuOpened() }
    }
}

func formatTime(_ t: Double, fractional: Bool = true) -> String {
    let total = max(0, t)
    let m = Int(total) / 60
    let s = Int(total) % 60
    if fractional {
        let cs = Int((total - floor(total)) * 10)
        return String(format: "%d:%02d.%d", m, s, cs)
    }
    return String(format: "%d:%02d", m, s)
}
