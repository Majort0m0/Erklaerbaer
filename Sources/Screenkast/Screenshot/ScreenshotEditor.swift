import AppKit
import SwiftUI
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - Windows

/// Opens screenshot editor windows (several can be open at once).
@MainActor
enum ScreenshotWindows {
    private static var windows: [NSWindow] = []

    static func open(image: CGImage) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        let doc = ShotDocument(image: image, name: "Screenshot \(formatter.string(from: Date()))")
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = screen?.backingScaleFactor ?? 2
        let wanted = NSSize(width: CGFloat(image.width) / scale + 80, height: CGFloat(image.height) / scale + 170)
        let size = NSSize(width: min(visible.width * 0.9, max(820, wanted.width)), height: min(visible.height * 0.9, max(560, wanted.height)))
        let window = NSWindow(contentRect: NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                                  width: size.width, height: size.height),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = doc.name
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScreenshotEditorView(doc: doc, close: { [weak window] in window?.close() }))
        window.minSize = NSSize(width: 760, height: 480)
        windows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            MainActor.assumeIsolated { windows.removeAll { $0 === note.object as? NSWindow } }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

extension AppModel {
    enum ScreenshotKind { case region, display(SCDisplay), window(SCWindow) }

    /// Takes a screenshot and opens it in the screenshot editor.
    func takeScreenshot(_ kind: ScreenshotKind) async {
        await refreshSources()
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
            errorMessage = permissionProblem ?? "Kein Zugriff auf den Bildschirm."
            return
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var target: CaptureTarget?
        switch kind {
        case .display(let d): target = .display(d)
        case .window(let w):
            WindowFocus.bringToFront(w)
            try? await Task.sleep(for: .milliseconds(450))
            let fresh = (try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false))?.windows
                .first { $0.windowID == w.windowID } ?? w
            target = .window(fresh)
        case .region:
            // The display under the mouse; our windows step aside while the area is dragged.
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else { return }
            let hidden = NSApp.windows.filter { $0.isVisible && $0.level == .normal }
            hidden.forEach { $0.orderOut(nil) }
            try? await Task.sleep(for: .milliseconds(150))
            let rect = await RegionSelector.select(on: display.displayID, initial: nil, title: "Bereich für den Screenshot aufziehen")
            hidden.forEach { $0.orderFront(nil) }
            guard let rect else { return }
            try? await Task.sleep(for: .milliseconds(120))   // the selection overlay is gone
            target = .region(display, rect)
        }
        guard let target else { return }
        do {
            let image = try await ScreenshotCapture.capture(target, excluding: own)
            ScreenshotWindows.open(image: image)
        } catch {
            errorMessage = "Screenshot fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// Opens a picture file in the screenshot editor.
    func openImageInScreenshotEditor() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        ScreenshotWindows.open(image: image)
    }
}

// MARK: - Editor

private final class ShotDragState: ObservableObject {
    @Published var copied = false
    var start: CGPoint?
    var origin: ShotItem?
    var created: UUID?
}

struct ScreenshotEditorView: View {
    @ObservedObject var doc: ShotDocument
    let close: () -> Void
    @StateObject private var drag = ShotDragState()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 14)
                .padding(.top, 30)
                .padding(.bottom, 8)
            Divider()
            canvas
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            bottomBar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 760, minHeight: 480)
    }

    private var editing: Bool { doc.editingTextID != nil }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            ForEach(ShotTool.allCases) { tool in
                Button {
                    if doc.tool == .crop, tool != .crop { doc.crop = nil }
                    doc.tool = tool
                } label: {
                    Image(systemName: tool.icon)
                        .font(.system(size: 14))
                        .frame(width: 30, height: 26)
                        .foregroundStyle(doc.tool == tool ? Color.white : Color.primary)
                        .background(doc.tool == tool ? Theme.brand : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(editing ? nil : KeyboardShortcut(KeyEquivalent(Character(tool.key)), modifiers: []))
                .help("\(tool.label) (\(tool.key.uppercased()))")
            }
            Divider().frame(height: 20).padding(.horizontal, 6)
            ForEach(AnnotationColor.allCases) { c in
                let (r, g, b) = c.rgb
                Circle()
                    .fill(Color(red: r, green: g, blue: b))
                    .overlay(Circle().strokeBorder(doc.color == c ? Theme.brand : Color.secondary.opacity(0.4), lineWidth: doc.color == c ? 2.5 : 1))
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
                    .onTapGesture {
                        doc.color = c
                        if let id = doc.selectedID { doc.checkpoint(); doc.update(id) { $0.color = c } }
                    }
            }
            Divider().frame(height: 20).padding(.horizontal, 6)
            Image(systemName: "lineweight").foregroundStyle(.secondary)
            Slider(value: Binding(get: { doc.lineWidth }, set: { v in
                doc.lineWidth = v
                if let id = doc.selectedID { doc.update(id) { $0.width = v } }
            }), in: 0.5...3)
                .frame(width: 90)
                .help("Strichstärke / Textgröße")
            Spacer()
            if doc.tool == .crop, doc.crop != nil {
                Button("Zuschneiden") { doc.applyCrop() }
                    .keyboardShortcut(.defaultAction)
                Button("Abbrechen") { doc.crop = nil }
                    .keyboardShortcut(.cancelAction)
            }
            Button { doc.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!doc.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("Widerrufen (⌘Z)")
            Button { doc.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!doc.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Wiederholen (⇧⌘Z)")
            Button { doc.deleteSelected() } label: { Image(systemName: "trash") }
                .disabled(doc.selectedID == nil)
                .keyboardShortcut(editing ? nil : KeyboardShortcut(.delete, modifiers: []))
                .help("Auswahl löschen (⌫)")
        }
        .buttonStyle(.borderless)
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let (out, imageRect) = doc.layout
            let k = max(0.01, min((geo.size.width - 40) / out.width, (geo.size.height - 40) / out.height))
            let shown = CGSize(width: out.width * k, height: out.height * k)
            let origin = CGPoint(x: (geo.size.width - shown.width) / 2, y: (geo.size.height - shown.height) / 2)
            /// View point → image pixel.
            let toImage = { (p: CGPoint) in CGPoint(x: (p.x - origin.x) / k - imageRect.minX, y: (p.y - origin.y) / k - imageRect.minY) }
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    context.withCGContext { cg in
                        cg.translateBy(x: origin.x, y: origin.y)
                        cg.scaleBy(x: k, y: k)
                        doc.drawBackground(in: cg, out: out, imageRect: imageRect)
                        cg.translateBy(x: imageRect.minX, y: imageRect.minY)
                        cg.clip(to: CGRect(x: -imageRect.minX, y: -imageRect.minY, width: out.width, height: out.height))
                        for item in doc.items where item.id != doc.editingTextID {
                            ShotDocument.draw(item, in: cg, imageWidth: doc.size.width)
                        }
                        // Selection and effect outlines.
                        for item in doc.items where item.id == doc.selectedID || item.isEffect {
                            let frame = item.kind == .text || item.kind == .number
                                ? ShotDocument.textFrame(item, imageWidth: doc.size.width) : item.rect
                            cg.setStrokeColor(item.id == doc.selectedID ? NSColor.controlAccentColor.cgColor : CGColor(gray: 1, alpha: 0.6))
                            cg.setLineWidth(1.5 / k)
                            cg.setLineDash(phase: 0, lengths: [5 / k, 4 / k])
                            if item.kind == .arrow {
                                cg.stroke(CGRect(x: min(item.a.x, item.b.x), y: min(item.a.y, item.b.y),
                                                 width: abs(item.b.x - item.a.x), height: abs(item.b.y - item.a.y)).insetBy(dx: -6 / k, dy: -6 / k))
                            } else {
                                cg.stroke(frame.insetBy(dx: -4 / k, dy: -4 / k))
                            }
                            cg.setLineDash(phase: 0, lengths: [])
                        }
                        if let crop = doc.crop {
                            let all = CGRect(origin: .zero, size: doc.size)
                            cg.setFillColor(CGColor(gray: 0, alpha: 0.5))
                            let path = CGMutablePath()
                            path.addRect(all); path.addRect(crop)
                            cg.addPath(path)
                            cg.fillPath(using: .evenOdd)
                            cg.setStrokeColor(CGColor(gray: 1, alpha: 1))
                            cg.setLineWidth(1.5 / k)
                            cg.stroke(crop)
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in changed(v, toImage: toImage) }
                    .onEnded { v in ended(v, toImage: toImage) })
                .pointerStyle(doc.tool == .select ? .default : doc.tool == .text ? .horizontalText : .rectSelection)

                if let id = doc.editingTextID, let item = doc.items.first(where: { $0.id == id }) {
                    let frame = ShotDocument.textFrame(item, imageWidth: doc.size.width)
                    let font = ShotDocument.textFont(item, imageWidth: doc.size.width)
                    TextField("Text", text: Binding(get: { item.text }, set: { t in doc.update(id) { $0.text = t } }), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: max(9, font.pointSize * k), weight: .bold))
                        .foregroundStyle(Color(red: item.color.rgb.r, green: item.color.rgb.g, blue: item.color.rgb.b))
                        .frame(minWidth: 120, alignment: .leading)
                        .fixedSize()
                        .padding(3)
                        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.brand, lineWidth: 1.5))
                        .offset(x: origin.x + (imageRect.minX + frame.minX) * k - 3, y: origin.y + (imageRect.minY + frame.minY) * k - 3)
                        .onSubmit { finishText() }
                        .onExitCommand { finishText() }
                }
            }
        }
    }

    private func finishText() {
        guard let id = doc.editingTextID else { return }
        doc.editingTextID = nil
        if doc.items.first(where: { $0.id == id })?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            doc.items.removeAll { $0.id == id }
        }
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), doc.size.width), y: min(max(0, p.y), doc.size.height))
    }

    private func changed(_ v: DragGesture.Value, toImage: (CGPoint) -> CGPoint) {
        let p = toImage(v.location)
        let isNew = drag.start != v.startLocation
        if isNew {
            drag.start = v.startLocation
            drag.origin = nil
            drag.created = nil
            if editing { finishText() }
            let s = toImage(v.startLocation)
            switch doc.tool {
            case .select:
                let hit = doc.item(at: s)
                doc.selectedID = hit?.id
                if let hit {
                    doc.checkpoint()
                    drag.origin = hit
                    if hit.kind == .text, v.translation == .zero, NSApp.currentEvent?.clickCount == 2 { doc.editingTextID = hit.id }
                }
            case .crop:
                doc.crop = CGRect(origin: clamp(s), size: .zero)
            case .text:
                if let hit = doc.item(at: s), hit.kind == .text {
                    doc.selectedID = hit.id
                    doc.editingTextID = hit.id
                    return
                }
                doc.checkpoint()
                let item = ShotItem(kind: .text, a: s, b: s, color: doc.color, width: doc.lineWidth)
                doc.items.append(item)
                doc.selectedID = item.id
                doc.editingTextID = item.id
                return
            case .number:
                doc.checkpoint()
                let item = ShotItem(kind: .number, a: s, b: s, color: doc.color, width: doc.lineWidth, number: doc.nextNumber)
                doc.items.append(item)
                doc.selectedID = item.id
                drag.origin = item
            default:
                doc.checkpoint()
                let item = ShotItem(kind: doc.tool, a: clamp(s), b: clamp(s), color: doc.color, width: doc.lineWidth)
                doc.items.append(item)
                doc.selectedID = item.id
                drag.created = item.id
            }
        }
        let s = toImage(v.startLocation)
        let delta = CGPoint(x: p.x - s.x, y: p.y - s.y)
        switch doc.tool {
        case .crop:
            let a = clamp(s), b = clamp(p)
            doc.crop = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        case .select, .number:
            guard let o = drag.origin else { return }
            doc.update(o.id) {
                $0.a = CGPoint(x: o.a.x + delta.x, y: o.a.y + delta.y)
                $0.b = CGPoint(x: o.b.x + delta.x, y: o.b.y + delta.y)
            }
        case .text:
            break
        default:
            guard let id = drag.created else { return }
            var end = clamp(p)
            if NSEvent.modifierFlags.contains(.shift) {
                let a = clamp(s)
                if doc.tool == .arrow {
                    // 45° steps
                    let angle = (atan2(end.y - a.y, end.x - a.x) / (.pi / 4)).rounded() * (.pi / 4)
                    let length = hypot(end.x - a.x, end.y - a.y)
                    end = CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
                } else {
                    let side = max(abs(end.x - a.x), abs(end.y - a.y))
                    end = CGPoint(x: a.x + (end.x >= a.x ? side : -side), y: a.y + (end.y >= a.y ? side : -side))
                }
            }
            doc.update(id) { $0.b = end }
        }
    }

    private func ended(_ v: DragGesture.Value, toImage: (CGPoint) -> CGPoint) {
        defer { drag.start = nil; drag.origin = nil; drag.created = nil }
        if let id = drag.created, let item = doc.items.first(where: { $0.id == id }) {
            let small = item.kind == .arrow ? hypot(item.b.x - item.a.x, item.b.y - item.a.y) < 6 : item.rect.width < 4 || item.rect.height < 4
            if small {
                doc.items.removeAll { $0.id == id }
                doc.selectedID = nil
                doc.discardCheckpoint()   // the empty item was no step
            }
        }
        if doc.tool == .crop, let c = doc.crop, c.width < 8 || c.height < 8 { doc.crop = nil }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Toggle("Hintergrund", isOn: $doc.styled)
                .toggleStyle(.switch)
                .controlSize(.small)
            if doc.styled {
                HStack(spacing: 4) {
                    ForEach(Backgrounds.presets.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Backgrounds.swatch(index: i))
                            .frame(width: 22, height: 16)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(doc.background == i ? Theme.brand : .clear, lineWidth: 2))
                            .onTapGesture { doc.background = i }
                            .help(Backgrounds.presets[i].name)
                    }
                }
                Slider(value: $doc.padding, in: 0.02...0.2).frame(width: 70).help("Abstand")
                Slider(value: $doc.cornerRadius, in: 0...40).frame(width: 60).help("Ecken")
                Toggle("Schatten", isOn: $doc.shadow).controlSize(.small)
            }
            Spacer()
            Text("\(Int(doc.layout.out.width)) × \(Int(doc.layout.out.height))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            // Drag the shot into another app (a PNG file).
            Image(systemName: "hand.draw")
                .font(.system(size: 15))
                .frame(width: 30, height: 26)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .onDrag {
                    if let url = doc.savedFile() { return NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                    return NSItemProvider()
                }
                .help("Hier anfassen und in eine andere App oder den Finder ziehen")
            Button {
                doc.copyToPasteboard()
                drag.copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [drag] in drag.copied = false }
            } label: {
                Label(drag.copied ? "Kopiert" : "Kopieren", systemImage: drag.copied ? "checkmark" : "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)
            .help("In die Zwischenablage (⌘C)")
            Button {
                doc.saveAs()
            } label: {
                Label("Sichern …", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            Button {
                doc.copyToPasteboard()
                close()
            } label: {
                Text("Kopieren & schließen")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}
