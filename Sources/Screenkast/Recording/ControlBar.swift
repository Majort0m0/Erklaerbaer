import AppKit
import SwiftUI
import ScreenCaptureKit

/// Floating bar with the most important recording controls (source, microphone, camera, start,
/// pause, stop). It is excluded from every capture.
@MainActor
final class ControlBar {
    private var panel: NSPanel?
    var isVisible: Bool { panel?.isVisible ?? false }

    func show(model: AppModel) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let size = NSSize(width: 520, height: 52)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let saved = UserDefaults.standard.string(forKey: "controlBarOrigin").map(NSPointFromString)
        let origin = saved.flatMap { p in NSScreen.screens.contains { $0.visibleFrame.contains(p) } ? p : nil }
            ?? NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.sharingType = .none   // never in a recording
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: ControlBarView(model: model, close: { [weak model] in model?.showControlBar = false }))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak panel] _ in
            MainActor.assumeIsolated {
                if let p = panel?.frame.origin { UserDefaults.standard.set(NSStringFromPoint(p), forKey: "controlBarOrigin") }
            }
        }
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ControlBarView: View {
    @ObservedObject var model: AppModel
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Ziehen, um die Leiste zu verschieben")
            if model.isRecording {
                recordingControls
            } else {
                setupControls
            }
            Divider().frame(height: 22)
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Steuerleiste ausblenden (wieder einblenden: Startseite oder Menü „Fenster“)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .fixedSize()
        .onHover { model.controlBarHover($0) }
    }

    private var sourceLabel: String {
        switch model.selection {
        case .display(let id): return model.displays.first { $0.displayID == id }.map(model.displayName) ?? "Bildschirm"
        case .window(let id): return (model.windows + model.otherWindows).first { $0.windowID == id }.map(model.windowName) ?? "Fenster"
        case .region(let id, let r): return model.regionName(id, r)
        case nil: return "Quelle wählen"
        }
    }

    @ViewBuilder
    private var setupControls: some View {
        Menu {
            Section("Bildschirme") {
                ForEach(model.displays, id: \.displayID) { d in
                    Button(model.displayName(d)) { model.selection = .display(d.displayID) }
                }
            }
            Button("Bereich wählen …") { Task { await model.chooseRegion() } }
            Section("Fenster") {
                ForEach(model.windows, id: \.windowID) { w in
                    Button(model.windowName(w)) { model.selection = .window(w.windowID) }
                }
            }
            if !model.otherWindows.isEmpty {
                Menu("Weitere Fenster") {
                    ForEach(model.otherWindows, id: \.windowID) { w in
                        Button(model.windowName(w)) { model.selection = .window(w.windowID) }
                    }
                }
            }
            Divider()
            Button("Quellen aktualisieren") { Task { await model.refreshSources() } }
        } label: {
            Label(sourceLabel, systemImage: "rectangle.dashed")
                .lineLimit(1)
                .frame(maxWidth: 170)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Was aufgenommen wird")

        Menu {
            Button("Kein Mikrofon") { model.microphoneID = "" }
            ForEach(model.microphones, id: \.uniqueID) { mic in
                Button(mic.localizedName) { model.microphoneID = mic.uniqueID }
            }
        } label: {
            Image(systemName: model.microphoneID.isEmpty ? "mic.slash" : "mic.fill")
                .foregroundStyle(model.microphoneID.isEmpty ? Color.secondary : Color.green)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.microphones.first { $0.uniqueID == model.microphoneID }?.localizedName ?? "Mikrofon aus")

        Menu {
            Button("Keine Kamera") { model.cameraID = "" }
            ForEach(model.cameras, id: \.uniqueID) { cam in
                Button(cam.localizedName) { model.cameraID = cam.uniqueID }
            }
        } label: {
            Image(systemName: model.cameraID.isEmpty ? "video.slash" : "video.fill")
                .foregroundStyle(model.cameraID.isEmpty ? Color.secondary : Color.green)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.cameras.first { $0.uniqueID == model.cameraID }?.localizedName ?? "Kamera aus")

        Button {
            model.systemAudio.toggle()
        } label: {
            Image(systemName: model.systemAudio ? "speaker.wave.2.fill" : "speaker.slash")
                .foregroundStyle(model.systemAudio ? Color.green : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(model.systemAudio ? "Systemton wird aufgenommen" : "Systemton aus")

        Menu {
            ScreenshotMenuItems(model: model)
        } label: {
            Image(systemName: "camera.viewfinder")
        } primaryAction: {
            Task { await model.takeScreenshot(.region) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Klick: Screenshot eines Bereichs (\(GlobalHotKey.screenshotDisplay)) – Pfeil: Fenster oder ganzer Bildschirm")

        Button {
            Task { await model.startRecording() }
        } label: {
            Label(model.isBusy ? "Startet …" : "Aufnehmen", systemImage: "record.circle")
                .font(.callout.bold())
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(model.isBusy || model.selection == nil)
        .help("Aufnahme starten (\(GlobalHotKey.defaultDisplay))")
    }

    @ViewBuilder
    private var recordingControls: some View {
        Circle()
            .fill(model.isPaused ? Color.orange : Color.red)
            .frame(width: 10, height: 10)
        Text(formatTime(model.elapsed, fractional: false))
            .font(.callout.monospacedDigit().bold())
            .frame(minWidth: 44, alignment: .leading)
        Button {
            model.togglePause()
        } label: {
            Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
        }
        .buttonStyle(.borderless)
        .help(model.isPaused ? "Fortsetzen" : "Pausieren")
        Button {
            Task { await model.stopRecording(fromControlBar: true) }
        } label: {
            Label("Stoppen", systemImage: "stop.fill")
                .font(.callout.bold())
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .help("Stoppen und bearbeiten (\(GlobalHotKey.defaultDisplay))")
        Button(role: .destructive) {
            Task { await model.cancelRecording() }
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("Aufnahme verwerfen")
    }
}
