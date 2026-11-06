import AppKit
import SwiftUI

/// Screen of a CoreGraphics display.
@MainActor
func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
}

/// Borderless window that can take keyboard input (Esc/Return in the region selector).
private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: - Region selection

/// Lets the user drag a rectangle on a screen. Returns it in display points (origin top-left).
@MainActor
enum RegionSelector {
    final class Model: ObservableObject {
        @Published var start: CGPoint?
        @Published var end: CGPoint?
        var title = "Bereich aufziehen"
        var finish: (CGRect?) -> Void = { _ in }

        var rect: CGRect? {
            guard let start, let end else { return nil }
            let r = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            return r.width > 20 && r.height > 20 ? r : nil
        }
    }

    static func select(on displayID: CGDirectDisplayID, initial: CGRect? = nil, title: String = "Bereich aufziehen") async -> CGRect? {
        guard let screen = screen(for: displayID) else { return nil }
        let model = Model()
        model.title = title
        if let initial { model.start = initial.origin; model.end = CGPoint(x: initial.maxX, y: initial.maxY) }
        let window = KeyWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.sharingType = .none
        window.contentView = NSHostingView(rootView: RegionView(model: model))
        window.setFrame(screen.frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let result: CGRect? = await withCheckedContinuation { cont in
            model.finish = { rect in
                model.finish = { _ in }
                cont.resume(returning: rect)
            }
        }
        window.orderOut(nil)
        return result.map { $0.integral }
    }

    private struct RegionView: View {
        @ObservedObject var model: Model

        var body: some View {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // Dim everything outside the rectangle.
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: geo.size))
                        if let r = model.rect { p.addRect(r) }
                    }
                    .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                    if let r = model.rect {
                        Rectangle()
                            .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                        Text("\(Int(r.width)) × \(Int(r.height))")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.7), in: Capsule())
                            .foregroundStyle(.white)
                            .offset(x: r.minX, y: max(0, r.minY - 30))
                    }
                    VStack(spacing: 10) {
                        Text(model.rect == nil ? model.title : "Bereich anpassen oder übernehmen")
                            .font(.title3.bold())
                        HStack {
                            Button("Abbrechen") { model.finish(nil) }
                                .keyboardShortcut(.cancelAction)
                            Button("Übernehmen") { model.finish(model.rect) }
                                .keyboardShortcut(.defaultAction)
                                .disabled(model.rect == nil)
                        }
                        .controlSize(.large)
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .position(x: geo.size.width / 2, y: geo.size.height - 90)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if model.start == nil || v.translation == .zero || (abs(v.translation.width) < 2 && abs(v.translation.height) < 2) {
                            model.start = v.startLocation
                        }
                        model.end = v.location
                    })
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Countdown

/// Big 3-2-1 in the middle of the screen before the recording starts (not recorded).
@MainActor
enum Countdown {
    final class Model: ObservableObject { @Published var number = 3 }

    static func run(seconds: Int = 3, on displayID: CGDirectDisplayID?) async {
        guard let screen = displayID.flatMap(screen(for:)) ?? NSScreen.main else { return }
        let model = Model()
        model.number = seconds
        let size: CGFloat = 220
        let frame = NSRect(x: screen.frame.midX - size / 2, y: screen.frame.midY - size / 2, width: size, height: size)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: CountdownView(model: model))
        panel.orderFrontRegardless()
        for n in stride(from: seconds, through: 1, by: -1) {
            model.number = n
            try? await Task.sleep(for: .seconds(1))
        }
        panel.orderOut(nil)
        // Let the window server remove the panel before the first frame is captured.
        try? await Task.sleep(for: .milliseconds(120))
    }

    private struct CountdownView: View {
        @ObservedObject var model: Model
        var body: some View {
            ZStack {
                Circle().fill(.black.opacity(0.72))
                Text("\(model.number)")
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.number)
            }
            .padding(10)
        }
    }
}

// MARK: - Speaker notes

/// Floating notes while recording (never captured: excluded from screen capture).
@MainActor
final class NotesPanel {
    final class Model: ObservableObject {
        @Published var text = ""
        @Published var fontSize: CGFloat = UserDefaults.standard.double(forKey: "notesFontSize") > 0
            ? CGFloat(UserDefaults.standard.double(forKey: "notesFontSize")) : 20 {
            didSet { UserDefaults.standard.set(Double(fontSize), forKey: "notesFontSize") }
        }
        /// Teleprompter: points per second (0 = off).
        @Published var scrollSpeed: Double = 0
    }

    private var panel: NSPanel?
    let model = Model()

    func show(text: String, on displayID: CGDirectDisplayID?) {
        hide()
        model.text = text
        let screen = displayID.flatMap(screen(for:)) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width: CGFloat = 520, height: CGFloat = 240
        let frame = NSRect(x: visible.midX - width / 2, y: visible.maxY - height - 10, width: width, height: height)
        let panel = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Sprechernotizen"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: NotesView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private struct NotesView: View {
        @ObservedObject var model: Model
        @StateObject private var scroller = Scroller()

        final class Scroller: ObservableObject {
            @Published var offset: CGFloat = 0
            var timer: Timer?
        }

        var body: some View {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    ScrollView {
                        Text(model.text)
                            .font(.system(size: model.fontSize, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .offset(y: -scroller.offset)
                            .textSelection(.enabled)
                    }
                    .frame(height: geo.size.height)
                }
                Divider()
                HStack(spacing: 10) {
                    Button { model.fontSize = max(12, model.fontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }
                    Button { model.fontSize = min(48, model.fontSize + 2) } label: { Image(systemName: "textformat.size.larger") }
                    Divider().frame(height: 14)
                    Image(systemName: "arrow.down.to.line").foregroundStyle(.secondary)
                    Slider(value: $model.scrollSpeed, in: 0...60)
                        .frame(width: 120)
                        .help("Teleprompter: Text läuft langsam nach oben")
                    Button { scroller.offset = 0 } label: { Image(systemName: "arrow.uturn.up") }
                        .help("Zum Anfang")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onAppear {
                let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        if model.scrollSpeed > 0.5 { scroller.offset += CGFloat(model.scrollSpeed / 30) }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                scroller.timer = timer
            }
            .onDisappear { scroller.timer?.invalidate() }
        }
    }
}
