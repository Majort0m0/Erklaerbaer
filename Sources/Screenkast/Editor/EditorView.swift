import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct EditorView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var editor: EditorModel

    var body: some View {
        EditorWorkspace(editor: editor)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.closeEditor()
                } label: {
                    Label("Aufnahmen", systemImage: "chevron.backward")
                }
                .help("Zurück zu allen Aufnahmen")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    editor.showPalette = true
                } label: {
                    Label("Befehle", systemImage: "command")
                }
                .keyboardShortcut("k", modifiers: .command)
                .help("Befehl suchen (⌘K)")
                Toggle(isOn: $editor.simpleMode) {
                    Label("Einfach", systemImage: "rectangle.compress.vertical")
                }
                .help("Einfach-Modus: weniger Spuren – Masken und Markierungen erscheinen, sobald sie benutzt werden")
                Button {
                    editor.showAISheet = true
                } label: {
                    Label("KI", systemImage: "sparkles")
                }
                .help("KI-Vorschläge: Kapitel, Titel, Beschreibung, Kurzclips")
                HelpButton(topic: "editor")
                Button {
                    editor.showPolishSheet = true
                } label: {
                    Label("Aufpolieren", systemImage: "wand.and.stars")
                }
                .help("Automatisch aufpolieren: Stimme, Untertitel, Füllwörter, Pausen, Zooms, Pegel")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor.pause()
                    editor.exportResult = nil
                    editor.exportError = nil
                    editor.showExportSheet = true
                } label: {
                    Label("Exportieren", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(editor.isExporting)
                .help("Video exportieren (⌘E)")
                .keyboardShortcut("e", modifiers: .command)
            }
        }
        .navigationTitle(editor.project.name)
        .sheet(isPresented: $editor.showExportSheet) {
            ExportSheet(editor: editor, isPresented: $editor.showExportSheet)
        }
        .sheet(isPresented: $editor.showPolishSheet) { PolishSheet(editor: editor) }
        .sheet(isPresented: $editor.showAISheet) { AISheet(editor: editor) }
        .sheet(isPresented: $editor.showSpeechSheet) { SpeechSheet(editor: editor) }
        .sheet(isPresented: $editor.showPalette) { CommandPalette(editor: editor) }
        .sheet(isPresented: $editor.showSensitiveSheet) { SensitiveSheet(editor: editor) }
        .sheet(isPresented: $editor.showGuideSheet) { GuideSheet(editor: editor) }
        .alert("Fehler", isPresented: Binding(get: { editor.loadError != nil }, set: { _ in editor.loadError = nil })) {
            Button("OK") { model.closeEditor() }
        } message: {
            Text(editor.loadError ?? "")
        }
        .background(EditorKeyHandler(onSpace: { editor.togglePlay() },
                                     onDelete: { editor.deleteSelection() },
                                     onCommand: { editor.perform($0) },
                                     onMouseUp: { editor.endInteraction() }))
        .onDisappear { editor.pause() }
    }

}

/// Preview, transport, timeline and inspector (the editor window without its toolbar): three
/// rounded cards on the canvas – the stage with the video, the timeline with its transport bar,
/// and the inspector.
struct EditorWorkspace: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        HStack(spacing: Theme.gap) {
            GeometryReader { geo in
                let maxTimeline = max(160, geo.size.height - 318)
                VStack(spacing: 0) {
                    PreviewArea(editor: editor)
                        .padding(22)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .card(Theme.stage)
                    TimelineResizeHandle(editor: editor, maxHeight: maxTimeline)
                    VStack(spacing: 0) {
                        TransportBar(editor: editor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        Rectangle().fill(Theme.stroke).frame(height: 1)
                        EditToolbar(editor: editor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                        Rectangle().fill(Theme.stroke).frame(height: 1)
                        EditorTimeline(editor: editor)
                            .frame(height: min(editor.timelineHeight, maxTimeline))
                            .padding(.leading, 8)
                            .padding(.trailing, 10)
                            .padding(.top, 6)
                            .padding(.bottom, 6)
                    }
                    .card()
                }
            }
            InspectorView(editor: editor)
                .frame(width: 310)
                .card()
        }
        .padding(Theme.gap)
        .background(Theme.canvas)
    }
}

// MARK: - Preview

/// Files dragged over the preview.
final class PreviewDropState: ObservableObject {
    @Published var targeted = false
    var size: CGSize = .zero
}

struct PreviewArea: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var drop = PreviewDropState()

    var body: some View {
        let size = editor.renderer.outputSize
        PlayerLayerView(player: editor.player)
            .aspectRatio(size.width / max(1, size.height), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            // Shadow from a plain shape behind the video (a shadow on the live video itself is
            // re-rendered with every frame).
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8))
            .overlay { CameraDragOverlay(editor: editor) }
            .overlay { PanelHighlight(editor: editor) }
            .overlay { PreviewContextBar(editor: editor) }
            .overlay { MaskOverlay(editor: editor) }
            .overlay { AnnotationHandle(editor: editor) }
            .overlay { ImageHandle(editor: editor) }
            .overlay { ZoomAreaHandle(editor: editor) }
            .overlay { VideoOverlayHandle(editor: editor) }
            .overlay { TextOverlayHandle(editor: editor) }
            .overlay { VoiceOverStatus(editor: editor) }
            // A click selects the element under the mouse (its settings open in the inspector).
            .onTapGesture(coordinateSpace: .local) { location in editor.previewClicked(at: location, viewSize: drop.size) }
            .background(GeometryReader { g in
                Color.clear.onAppear { drop.size = g.size }.onChange(of: g.size) { _, s in drop.size = s }
            })
            // Pictures and videos dropped here are shown on top, centered where they were dropped.
            .onDrop(of: EditorModel.droppableTypes, isTargeted: $drop.targeted) { providers, location in
                let p = CGPoint(x: min(0.95, max(0.05, location.x / max(1, drop.size.width))),
                                y: min(0.95, max(0.05, location.y / max(1, drop.size.height))))
                Task { @MainActor in
                    var urls: [URL] = []
                    for provider in providers { if let url = await provider.loadFileURL() { urls.append(url) } }
                    editor.drop(urls, target: .preview(p), at: editor.currentTime)
                }
                return true
            }
            .overlay {
                if drop.targeted {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(TimelineSelection.color, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                        .overlay(Text("Hier einblenden").font(.headline).padding(8).background(.regularMaterial, in: Capsule()))
                        .allowsHitTesting(false)
                }
            }
            .id("\(editor.settings.aspect.rawValue)-\(editor.settings.exportShortSide)")
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.allowsMagnification = false
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

/// Lets the camera bubble be dragged directly in the preview.
struct CameraDragOverlay: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        GeometryReader { geo in
            if editor.hasCamera && editor.settings.cameraVisible {
                let out = editor.renderer.outputSize
                let s = geo.size.width / max(1, out.width)
                let r = FrameRenderer.cameraRect(settings: editor.settings, out: out, cameraAspect: editor.cameraAspect).rect
                // CI rect (bottom-left origin) → view coordinates (top-left origin)
                let view = CGRect(x: r.minX * s, y: (out.height - r.maxY) * s, width: r.width * s, height: r.height * s)
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: view.width, height: view.height)
                    .position(x: view.midX, y: view.midY)
                    .onHover { inside in
                        if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(coordinateSpace: .global)
                        .onChanged { v in
                            if editor.cameraDragOrigin == nil {
                                editor.cameraDragOrigin = CGPoint(x: view.midX / geo.size.width, y: view.midY / geo.size.height)
                            }
                            guard let o = editor.cameraDragOrigin else { return }
                            editor.settings.cameraX = min(1, max(0, o.x + v.translation.width / geo.size.width))
                            editor.settings.cameraY = min(1, max(0, o.y + v.translation.height / geo.size.height))
                        }
                        .onEnded { _ in editor.cameraDragOrigin = nil })
                    .help("Kamerablase verschieben")
            }
        }
    }
}

/// Start of a drag on a preview handle. A new drag is recognized by its start location, so a
/// lost mouse-up can never leave a stale origin behind (that made handles jump).
final class PreviewDragState: ObservableObject {
    private var startLocation: CGPoint?
    /// Geometry when the drag began (view coordinates).
    var rect: CGRect = .zero
    var a: CGPoint = .zero
    var b: CGPoint = .zero

    /// True for the first event of a new drag.
    func begins(_ v: DragGesture.Value) -> Bool {
        guard startLocation != v.startLocation else { return false }
        startLocation = v.startLocation
        return true
    }

    func end() { startLocation = nil }
}

/// Converts between the preview view and normalized capture coordinates at the playhead (zoom,
/// padding and inserted clips included).
@MainActor
struct PreviewGeometry {
    let editor: EditorModel
    let size: CGSize
    var out: CGSize { editor.renderer.outputSize }
    var scale: CGFloat { size.width / max(1, out.width) }
    var t: Double { editor.currentTime }

    func view(_ p: CGPoint) -> CGPoint {
        let q = editor.renderer.outputPoint(p, at: t)
        return CGPoint(x: q.x * scale, y: q.y * scale)
    }

    func normalized(_ v: CGPoint) -> CGPoint {
        editor.renderer.normalizedPoint(fromOutput: CGPoint(x: v.x / scale, y: v.y / scale), at: t)
    }

    /// View rectangle of a normalized rectangle.
    func view(_ r: CGRect) -> CGRect {
        let p0 = view(CGPoint(x: r.minX, y: r.minY)), p1 = view(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
    }

    func normalized(_ r: CGRect) -> CGRect {
        let p0 = normalized(CGPoint(x: r.minX, y: r.minY)), p1 = normalized(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
    }
}

/// A rectangle on the preview: drag inside to move it, any corner to resize it.
struct PreviewRectEditor: View {
    let editor: EditorModel
    let rect: CGRect
    let color: Color
    /// Keep width/height (pictures).
    var aspect: CGFloat? = nil
    var dashed = false
    /// Only moving, no corner handles (captions).
    var movesOnly = false
    var help = ""
    let onChange: (CGRect) -> Void
    @StateObject private var drag = PreviewDragState()

    var body: some View {
        ZStack {
            Rectangle()
                .fill(color.opacity(0.1))
                .overlay(Rectangle().strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [6, 4] : [])))
                .frame(width: max(6, rect.width), height: max(6, rect.height))
                .contentShape(Rectangle())
                .pointerStyle(.grabIdle)
                .gesture(gesture { start, d in start.offsetBy(dx: d.width, dy: d.height) })
                .help(help)
                .position(x: rect.midX, y: rect.midY)
            ForEach(movesOnly ? [] : [0, 1, 2, 3], id: \.self) { corner in
                let p = Self.corner(corner, of: rect)
                Circle()
                    .fill(color)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .frame(width: 13, height: 13)
                    .contentShape(Circle().inset(by: -4))
                    .pointerStyle(.frameResize(position: corner == 0 ? .topLeading : corner == 1 ? .topTrailing : corner == 2 ? .bottomTrailing : .bottomLeading))
                    .gesture(gesture { start, d in resized(start, corner: corner, by: d) })
                    .position(p)
            }
        }
    }

    static func corner(_ i: Int, of r: CGRect) -> CGPoint {
        switch i {
        case 0: return CGPoint(x: r.minX, y: r.minY)
        case 1: return CGPoint(x: r.maxX, y: r.minY)
        case 2: return CGPoint(x: r.maxX, y: r.maxY)
        default: return CGPoint(x: r.minX, y: r.maxY)
        }
    }

    /// `start` with one corner moved; the opposite corner stays put.
    private func resized(_ start: CGRect, corner: Int, by d: CGSize) -> CGRect {
        let fixed = Self.corner((corner + 2) % 4, of: start)
        let moved = Self.corner(corner, of: start)
        var p = CGPoint(x: moved.x + d.width, y: moved.y + d.height)
        if let aspect, aspect > 0 {
            // Follow the larger movement, keep the picture's proportions.
            let w = max(abs(p.x - fixed.x), abs(p.y - fixed.y) * aspect, 12)
            p = CGPoint(x: fixed.x + (moved.x >= fixed.x ? w : -w), y: fixed.y + (moved.y >= fixed.y ? w / aspect : -w / aspect))
        }
        var r = CGRect(x: min(fixed.x, p.x), y: min(fixed.y, p.y), width: abs(p.x - fixed.x), height: abs(p.y - fixed.y))
        r.size.width = max(8, r.width); r.size.height = max(8, r.height)
        return r
    }

    private func gesture(_ change: @escaping (CGRect, CGSize) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { v in
                if drag.begins(v) {
                    drag.rect = rect
                    editor.beginInteraction()
                }
                onChange(change(drag.rect, v.translation))
            }
            .onEnded { _ in
                drag.end()
                editor.endInteraction()
            }
    }
}

/// Outline of the camera bubble or the logo while their settings are open; the captions can be
/// dragged to a new position.
struct PanelHighlight: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        GeometryReader { geo in
            let out = editor.renderer.outputSize
            let s = geo.size.width / max(1, out.width)
            let toView = { (r: CGRect) in CGRect(x: r.minX * s, y: (out.height - r.maxY) * s, width: r.width * s, height: r.height * s) }
            switch editor.selection {
            case .panel(.camera) where editor.hasCamera:
                let cam = FrameRenderer.cameraState(at: editor.currentTime, settings: editor.settings)
                let r = cam.full > 0.5 ? CGRect(origin: .zero, size: out)
                    : FrameRenderer.cameraRect(settings: editor.settings, out: out, cameraAspect: editor.cameraAspect, scale: cam.scale).rect
                outline(toView(r), round: editor.settings.cameraShape == .circle && cam.full <= 0.5)
            case .panel(.logo):
                if let w = editor.settings.watermark, let r = editor.renderer.watermarkFrame(w, out: out) { outline(toView(r), round: false) }
            case .panel(.captions):
                if let r = editor.renderer.captionFrame(at: editor.currentTime) {
                    PreviewRectEditor(editor: editor, rect: toView(r), color: TimelineSelection.color, movesOnly: true,
                                      help: "Untertitel verschieben – jedes Format merkt sich die Position") { n in
                        editor.settings.captionStyle.x = min(0.95, max(0.05, n.midX / geo.size.width))
                        editor.settings.captionStyle.y = min(0.97, max(0.03, n.midY / geo.size.height))
                    }
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func outline(_ r: CGRect, round: Bool) -> some View {
        Group {
            if round {
                Circle().strokeBorder(TimelineSelection.color, lineWidth: 2.5)
            } else {
                RoundedRectangle(cornerRadius: 6).strokeBorder(TimelineSelection.color, lineWidth: 2.5)
            }
        }
        .frame(width: r.width + 6, height: r.height + 6)
        .position(x: r.midX, y: r.midY)
        .allowsHitTesting(false)
    }
}

/// Rectangle of the selected mask on top of the preview: drag to move, corners to resize.
struct MaskOverlay: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        GeometryReader { geo in
            if let mask = editor.selectedMask, editor.currentTime >= mask.start, editor.currentTime <= mask.end {
                let g = PreviewGeometry(editor: editor, size: geo.size)
                let at = mask.rect(at: editor.currentTime)
                PreviewRectEditor(editor: editor, rect: g.view(at), color: .orange,
                                  help: mask.track == nil ? "Maske verschieben – Ecken ziehen ändert die Größe"
                                      : "Keyframe an dieser Stelle setzen oder ändern – mit ⌥ wandert der ganze Weg mit") { r in
                    editor.moveMask(mask.id, shownAt: at, to: g.normalized(r), wholePath: NSEvent.modifierFlags.contains(.option))
                }
            }
        }
    }
}

/// Selected arrow, frame or spotlight on the preview: drag to move, handles to resize or aim.
struct AnnotationHandle: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var drag = PreviewDragState()

    var body: some View {
        GeometryReader { geo in
            if let a = editor.selectedAnnotation, editor.isVisibleNow(start: a.start, end: a.end) {
                let g = PreviewGeometry(editor: editor, size: geo.size)
                if a.isPoint {
                    let at = g.view(CGPoint(x: a.x, y: a.y))
                    let (r, gr, b) = a.color.rgb
                    endpoint(at: at, color: Color(red: r, green: gr, blue: b))
                        .gesture(arrowDrag(a, g, tail: at, head: g.view(CGPoint(x: a.x + a.width, y: a.y + a.height))) { t, h, d in
                            (CGPoint(x: t.x + d.width, y: t.y + d.height), CGPoint(x: h.x + d.width, y: h.y + d.height))
                        })
                        .help(a.kind == .step ? "Schritt verschieben" : "Stelle der Berührung")
                } else if a.hasTwoPoints {
                    let tail = g.view(CGPoint(x: a.x, y: a.y)), head = g.view(CGPoint(x: a.x + a.width, y: a.y + a.height))
                    let (r, gr, b) = a.color.rgb
                    ZStack {
                        // The shaft moves the whole arrow.
                        Path { p in p.move(to: tail); p.addLine(to: head) }
                            .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .contentShape(Path { p in p.move(to: tail); p.addLine(to: head) }
                                .strokedPath(StrokeStyle(lineWidth: 16, lineCap: .round)))
                            .pointerStyle(.grabIdle)
                            .gesture(arrowDrag(a, g, tail: tail, head: head) { t, h, d in
                                (CGPoint(x: t.x + d.width, y: t.y + d.height), CGPoint(x: h.x + d.width, y: h.y + d.height))
                            })
                            .help(a.kind == .arrow ? "Pfeil verschieben" : "Geste verschieben")
                        endpoint(at: tail, color: .white)
                            .gesture(arrowDrag(a, g, tail: tail, head: head) { t, h, d in (CGPoint(x: t.x + d.width, y: t.y + d.height), h) })
                            .help(a.kind == .arrow ? "Anfang des Pfeils" : a.touchGesture.isPinch ? "Mitte zwischen den Fingern" : "Hier beginnt die Geste")
                        endpoint(at: head, color: Color(red: r, green: gr, blue: b))
                            .gesture(arrowDrag(a, g, tail: tail, head: head) { t, h, d in (t, CGPoint(x: h.x + d.width, y: h.y + d.height)) })
                            .help(a.kind == .arrow ? "Spitze des Pfeils" : a.touchGesture.isPinch ? "Abstand der Finger" : "Hier endet die Geste")
                    }
                } else {
                    PreviewRectEditor(editor: editor, rect: g.view(CGRect(x: a.x, y: a.y, width: a.width, height: a.height)),
                                      color: .white, dashed: true, help: "\(a.kind.label) verschieben – Ecken ziehen ändert die Größe") { r in
                        let n = g.normalized(r)
                        editor.updateAnnotation(id: a.id) { $0.x = n.minX; $0.y = n.minY; $0.width = n.width; $0.height = n.height }
                    }
                }
            }
        }
    }

    private func endpoint(at p: CGPoint, color: Color) -> some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.45), lineWidth: 1))
            .frame(width: 14, height: 14)
            .contentShape(Circle().inset(by: -5))
            .pointerStyle(.grabIdle)
            .position(p)
    }

    /// Moves tail and/or head from where they were when the drag began.
    private func arrowDrag(_ a: Annotation, _ g: PreviewGeometry, tail: CGPoint, head: CGPoint,
                           _ change: @escaping (CGPoint, CGPoint, CGSize) -> (CGPoint, CGPoint)) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { v in
                if drag.begins(v) {
                    drag.a = tail; drag.b = head
                    editor.beginInteraction()
                }
                let (t, h) = change(drag.a, drag.b, v.translation)
                let nt = g.normalized(t), nh = g.normalized(h)
                editor.updateAnnotation(id: a.id) { $0.x = nt.x; $0.y = nt.y; $0.width = nh.x - nt.x; $0.height = nh.y - nt.y }
            }
            .onEnded { _ in
                drag.end()
                editor.endInteraction()
            }
    }
}

/// The part a zoom with a fixed point shows, as a frame on the not yet zoomed preview: dragging
/// moves the point, the corners change the strength.
struct ZoomAreaHandle: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        GeometryReader { geo in
            if let i = editor.selectedZoomIndex, let focus = editor.settings.zoomSegments[i].focus,
               AutoZoom.zoom(at: editor.currentTime, segments: editor.settings.zoomSegments) < 1.01 {
                let seg = editor.settings.zoomSegments[i]
                let g = PreviewGeometry(editor: editor, size: geo.size)
                let area = editor.renderer.zoomArea(focus: focus, scale: seg.scale, at: editor.currentTime)
                let view = g.view(area)
                PreviewRectEditor(editor: editor, rect: view, color: .purple, aspect: view.height > 0 ? view.width / view.height : nil, dashed: true,
                                  help: "Zoom-Ausschnitt: verschieben legt die Stelle fest, an den Ecken ziehen ändert die Stärke") { r in
                    editor.setZoomArea(seg.id, area: g.normalized(r))
                }
            }
        }
    }
}

/// Selected picture on the preview: drag to move, corners to resize (keeps its proportions).
struct ImageHandle: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        GeometryReader { geo in
            if let o = editor.selectedImage, editor.isVisibleNow(image: o),
               let r = editor.renderer.imageFrame(editor.keyedImage(o), out: editor.renderer.outputSize) {
                let out = editor.renderer.outputSize
                let s = geo.size.width / max(1, out.width)
                let view = CGRect(x: r.minX * s, y: (out.height - r.maxY) * s, width: r.width * s, height: r.height * s)
                PreviewRectEditor(editor: editor, rect: view, color: .mint, aspect: view.height > 0 ? view.width / view.height : nil,
                                  help: "Bild verschieben – Ecken ziehen ändert die Größe") { n in
                    editor.place(.image(o.id), x: n.midX / geo.size.width, y: n.midY / geo.size.height, width: n.width / geo.size.width)
                }
            }
        }
    }
}

/// Selected video overlay on the preview: drag to move, corners to resize.
struct VideoOverlayHandle: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        GeometryReader { geo in
            if let o = editor.selectedVideoOverlay, editor.isVisibleNow(videoOverlay: o) {
                let out = editor.renderer.outputSize
                let s = geo.size.width / max(1, out.width)
                let r = FrameRenderer.videoOverlayFrame(editor.keyedVideo(o), out: out)
                let view = CGRect(x: r.minX * s, y: (out.height - r.maxY) * s, width: r.width * s, height: r.height * s)
                PreviewRectEditor(editor: editor, rect: view, color: .yellow, aspect: view.height > 0 ? view.width / view.height : nil,
                                  help: "Video verschieben – Ecken ziehen ändert die Größe") { n in
                    editor.place(.video(o.id), x: n.midX / geo.size.width, y: n.midY / geo.size.height, width: n.width / geo.size.width)
                }
            }
        }
    }
}

// MARK: - Transport

/// Bar between preview and timeline: position on the left, playback in the middle, adding on
/// the right. The editing tools are in `EditToolbar` right below.
struct TransportBar: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        // Narrow windows: icons only.
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
        }
        .buttonStyle(GhostButtonStyle())
        .controlSize(.regular)
        .disabled(editor.voiceOverState == .saving)
    }

    private func bar(compact: Bool) -> some View {
        HStack(spacing: 0) {
            position
                .frame(maxWidth: .infinity, alignment: .leading)
            playback(compact: compact)
                .fixedSize()
                .padding(.horizontal, 8)
            adding(compact: compact)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var position: some View {
        HStack(spacing: 4) {
            Text(formatTime(editor.outputTime)).foregroundStyle(.primary).fontWeight(.semibold)
            Text("/").foregroundStyle(.tertiary)
            Text(formatTime(editor.outputDuration)).foregroundStyle(.secondary)
        }
        .font(.system(size: 12.5, design: .rounded).monospacedDigit())
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(Theme.lane))
        .help("Position und Länge des fertigen Videos")
    }

    private func playback(compact: Bool) -> some View {
        HStack(spacing: compact ? 2 : 4) {
            ToolButton(icon: "backward.end.fill", help: "Zum Anfang (Pos1)") { editor.perform(.home) }
            if !compact {
                ToolButton(icon: "backward.frame.fill", help: "Ein Bild zurück (←)") { editor.perform(.step(frames: -1)) }
            }
            Button {
                editor.togglePlay()
            } label: {
                Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: editor.isPlaying ? 0 : 1.5)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.brand.gradient))
                    .shadow(color: Theme.brand.opacity(0.35), radius: 6, y: 2)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .help("Abspielen/Pause (Leertaste)")
            if !compact {
                ToolButton(icon: "forward.frame.fill", help: "Ein Bild vor (→)") { editor.perform(.step(frames: 1)) }
                ToolButton(icon: "forward.end.fill", help: "Zum Ende (Ende)") { editor.perform(.end) }
            }
        }
    }

    private func adding(compact: Bool) -> some View {
        HStack(spacing: 6) {
            Menu {
                Button { editor.addZoomAtPlayhead() } label: { Label("Zoom", systemImage: "plus.magnifyingglass") }
                Button { editor.addLowerThird() } label: { Label("Bauchbinde", systemImage: "text.below.photo") }
                Menu {
                    Button("Über dem Video") { editor.addTitleCard(placement: .overlay) }
                    Button("Vorspann (vor der Aufnahme)") { editor.addTitleCard(placement: .intro) }
                    Button("Abspann (nach der Aufnahme)") { editor.addTitleCard(placement: .outro) }
                } label: {
                    Label("Titelkarte", systemImage: "rectangle.inset.filled")
                }
                Button { editor.addMaskAtPlayhead() } label: { Label("Maske (verpixeln)", systemImage: "square.grid.3x3") }
                Menu {
                    ForEach(AnnotationKind.allCases) { kind in
                        Button { editor.addAnnotation(kind) } label: { Label(kind.label, systemImage: kind.icon) }
                    }
                } label: {
                    Label("Markierung", systemImage: "arrow.up.right")
                }
                if editor.hasCamera {
                    Menu {
                        ForEach(CameraLayout.allCases.filter { $0 != .normal }) { layout in
                            Button { editor.addCameraLayout(start: min(max(0, editor.currentTime), editor.duration), layout: layout) } label: {
                                Label(layout.label, systemImage: layout.icon)
                            }
                        }
                    } label: {
                        Label("Kamera-Layout", systemImage: "web.camera")
                    }
                }
                Divider()
                Button { editor.insertFreeze() } label: { Label("Standbild (⌥F)", systemImage: "snowflake") }
                Button { editor.addInsertClip() } label: { Label("Videoclip einfügen …", systemImage: "film.stack") }
                Button { editor.addVideoOverlay() } label: { Label("Video als Bild im Bild …", systemImage: "pip") }
                Button { editor.addNarrationFile() } label: { Label("Sprachaufnahme (Audiodatei) …", systemImage: "waveform.badge.plus") }
                Button { editor.showSpeechSheet = true } label: { Label("Text sprechen lassen …", systemImage: "text.bubble") }
                Divider()
                Button { editor.showSensitiveSheet = true } label: { Label("Sensible Daten verpixeln …", systemImage: "eye.slash") }
                Button { editor.showGuideSheet = true } label: { Label("Anleitung aus Klicks …", systemImage: "list.number") }
                Button { editor.addImage() } label: { Label("Bild …", systemImage: "photo") }
                Button { editor.chooseWatermark(); editor.inspectorTab = .media; editor.selection = nil } label: {
                    Label("Logo als Wasserzeichen …", systemImage: "seal")
                }
                Button { editor.chooseMusic() } label: { Label(editor.settings.music == nil ? "Hintergrundmusik …" : "Andere Musik …", systemImage: "music.note") }
                Button { editor.addChapter() } label: { Label("Kapitelmarke (M)", systemImage: "bookmark") }
                Menu {
                    Button("Mit Rahmen") { editor.highlightClicks(with: .frame) }
                    Button("Mit Pfeilen") { editor.highlightClicks(with: .arrow) }
                    Button("Mit Finger") { editor.highlightClicks(with: .touch) }
                    Button("Mit nummerierten Schritten") { editor.highlightClicks(with: .step) }
                } label: {
                    Label("Klicks hervorheben", systemImage: "cursorarrow.click.2")
                }
                .disabled(editor.project.cursor.clicks.isEmpty)
                Divider()
                Button { editor.setTrim(start: editor.currentTime) } label: { Label("Anfang hierher kürzen", systemImage: "arrow.right.to.line") }
                Button { editor.setTrim(end: editor.currentTime) } label: { Label("Ende hierher kürzen", systemImage: "arrow.left.to.line") }
            } label: {
                Label("Hinzufügen", systemImage: "plus")
                    .labelStyle(VariableLabelStyle(compact: compact))
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .tint(Theme.brand)
            .fixedSize()
            .help("Zoom, Text, Maske oder Standbild am Abspielkopf einfügen")
        }
    }
}

/// Title and icon, or only the icon in narrow windows.
struct VariableLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            HStack(spacing: 5) {
                configuration.icon
                configuration.title
            }
        }
    }
}

/// Icon button with a tooltip (optionally with a title).
struct ToolButton: View {
    let icon: String
    var title: String? = nil
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let title {
                    Label(title, systemImage: icon).labelStyle(.titleAndIcon)
                } else {
                    Image(systemName: icon)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
        }
        .help(help)
    }
}

/// Overview of the editor's keyboard shortcuts.
struct ShortcutHelp: View {
    private let groups: [(String, [(String, String)])] = [
        ("Abspielen", [("Leertaste", "Abspielen / Pause"), ("← →", "Ein Bild zurück / vor"), ("⇧← ⇧→", "Eine Sekunde"),
                       ("Pos1 / Ende", "Zum Anfang / Ende"),
                       ("J  /  K  /  L", "Rückwärts / Stopp / Vorwärts (mehrfach: schneller)")]),
        ("Bearbeiten", [("S  oder  ⌘B", "Am Abspielkopf teilen"), ("⌫", "Auswahl löschen / Teil entfernen"),
                        ("Q  /  W", "Anfang / Ende hierher kürzen"), ("⌥F", "Standbild (Ende des ausgewählten Teils)"),
                        ("⌘T", "Überblendung an der Schnittstelle"), ("⌥↑  /  ⌥↓", "Teil schneller / langsamer"),
                        ("⌘Z  /  ⇧⌘Z", "Widerrufen / Wiederholen"), ("⌘C  /  ⌘V", "Element kopieren / am Abspielkopf einfügen"),
                        ("⇧⌘→", "Alles rechts vom Abspielkopf auswählen"), ("Y", "Schnittmodus: Normal, Rollen, Slip"), ("Esc", "Auswahl aufheben")]),
        ("Hinzufügen", [("Z", "Zoom"), ("T", "Text"), ("X", "Maske"), ("A  /  R  /  P", "Pfeil / Rahmen / Spotlight"), ("F", "Finger-Geste"), ("B", "Nummerierter Schritt"), ("E", "Meme-Board"), ("1 … 0", "Meme einsetzen"),
                        ("C", "Mauszeiger-Bereich"), ("I  /  O", "Bild / Video"), ("V", "Einsprechen"), ("M", "Kapitelmarke")]),
        ("Timeline", [("N", "Einrasten an/aus"), ("G", "Clips zusammenkleben an/aus"),
                      ("⌘+  /  ⌘−", "Hinein- / Herauszoomen"), ("⇧Z", "Alles zeigen"),
                      ("⌥ + Scrollen, Zwei-Finger-Zoom", "Zoomen um den Mauszeiger"), ("Seitlich wischen", "Verschieben")]),
        ("Export", [("⌘E", "Exportieren")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups, id: \.0) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.0).font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(group.1, id: \.0) { item in
                        HStack {
                            Text(item.0).font(.system(size: 12, weight: .medium).monospaced())
                                .frame(width: 170, alignment: .leading)
                            Text(item.1).font(.system(size: 12))
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 400)
        .safeAreaInset(edge: .bottom) {
            HelpButton(topic: "shortcuts", title: "Alle Tastenkürzel in der Hilfe")
                .buttonStyle(.link)
                .padding(.bottom, 12)
        }
    }
}

/// Drag bar between preview and timeline: changes the timeline height.
struct TimelineResizeHandle: View {
    @ObservedObject var editor: EditorModel
    let maxHeight: CGFloat
    @StateObject private var drag = DragStart()

    final class DragStart: ObservableObject { var height: CGFloat? }

    @StateObject private var hover = HoverFlag()

    var body: some View {
        ZStack {
            Capsule().fill(Color.secondary.opacity(hover.on ? 0.7 : 0.35)).frame(width: hover.on ? 52 : 36, height: 4)
                .animation(.easeOut(duration: 0.15), value: hover.on)
        }
        .frame(height: Theme.gap)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hover.on = inside
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { v in
                if drag.height == nil { drag.height = min(editor.timelineHeight, maxHeight) }
                editor.timelineHeight = min(maxHeight, max(160, (drag.height ?? 0) - v.translation.height))
            }
            .onEnded { _ in drag.height = nil })
        .help("Ziehen, um die Timeline größer oder kleiner zu machen")
    }
}

/// Countdown and recording indicator for voice-over recording.
struct VoiceOverStatus: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        switch editor.voiceOverState {
        case .countdown(let n):
            Text("\(n)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(radius: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.35))
                .allowsHitTesting(false)
        case .recording:
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 10, height: 10)
                Text("Voice-over").font(.callout.bold())
                LevelMeter(level: editor.voiceOverLevel).frame(width: 80, height: 6)
                Text("Leertaste stoppt").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
        case .saving:
            ProgressView().controlSize(.small).padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .idle:
            EmptyView()
        }
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(level > 0.9 ? Color.red : Color.green)
                    .frame(width: geo.size.width * CGFloat(min(1, sqrt(level))))
            }
        }
    }
}

/// Frame of the selected lower third on the preview: drag to move it.
struct TextOverlayHandle: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        GeometryReader { geo in
            if let text = editor.selectedText, text.kind == .lowerThird {
                let out = editor.renderer.outputSize
                let s = geo.size.width / max(1, out.width)
                let r = editor.renderer.lowerThirdFrame(text)
                let view = CGRect(x: r.minX * s, y: (out.height - r.maxY) * s, width: r.width * s, height: r.height * s)
                let active = editor.currentTime >= text.start && editor.currentTime <= text.end
                Rectangle()
                    .fill(Color.teal.opacity(0.1))
                    .overlay(Rectangle().strokeBorder(Color.teal, style: StrokeStyle(lineWidth: 2, dash: active ? [] : [6, 4])))
                    .frame(width: max(8, view.width), height: max(8, view.height))
                    .position(x: view.midX, y: view.midY)
                    .onHover { inside in
                        if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(coordinateSpace: .global)
                        .onChanged { v in
                            if editor.textDragOrigin?.id != text.id {
                                editor.textDragOrigin = text
                                editor.beginInteraction()
                            }
                            guard let o = editor.textDragOrigin else { return }
                            editor.moveLowerThird(id: text.id, from: o, dx: v.translation.width / geo.size.width,
                                                  dy: v.translation.height / geo.size.height)
                        }
                        .onEnded { _ in editor.endInteraction() })
                    .help("Text verschieben – rastet in der Mitte ein")
                if editor.textCenterGuide {
                    Rectangle()
                        .fill(Color.yellow)
                        .frame(width: 1, height: geo.size.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

// MARK: - Export sheet

/// Ready-made export settings.
enum ExportPreset: String, CaseIterable, Identifiable {
    case youtube, youtube4K, vertical, square, small, gif, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .youtube: return "YouTube (1080p, 60 fps)"
        case .youtube4K: return "YouTube 4K"
        case .vertical: return "Hochformat – Shorts, Reels, TikTok"
        case .square: return "Quadratisch – Instagram, LinkedIn"
        case .small: return "Klein (720p, HEVC) – zum Verschicken"
        case .gif: return "Animiertes GIF – kurze Clips"
        case .custom: return "Eigene Einstellungen"
        }
    }

    func apply(to s: inout EditSettings) {
        switch self {
        case .youtube: s.exportShortSide = 1080; s.exportFPS = 60; s.exportHEVC = false
            if s.aspect == .vertical || s.aspect == .square { s.switchAspect(to: .wide) }
        case .youtube4K: s.exportShortSide = 2160; s.exportFPS = 60; s.exportHEVC = true
            if s.aspect == .vertical || s.aspect == .square { s.switchAspect(to: .wide) }
        case .vertical: s.switchAspect(to: .vertical); s.exportShortSide = 1080; s.exportFPS = 30; s.exportHEVC = false
        case .square: s.switchAspect(to: .square); s.exportShortSide = 1080; s.exportFPS = 30; s.exportHEVC = false
        case .small: s.exportShortSide = 720; s.exportFPS = 30; s.exportHEVC = true
        case .gif: s.exportShortSide = 720; s.exportFPS = 30
        case .custom: break
        }
    }
}

/// Export dialog: settings first, then progress and result.
struct ExportSheet: View {
    @ObservedObject var editor: EditorModel
    @Binding var isPresented: Bool
    @AppStorage("exportPreset") private var presetRaw = ExportPreset.youtube.rawValue

    private var preset: ExportPreset { ExportPreset(rawValue: presetRaw) ?? .youtube }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if editor.isExporting {
                Text("Exportiere …").font(.headline)
                ProgressView(value: editor.exportProgress)
                Text("\(Int(editor.exportProgress * 100)) %").monospacedDigit().foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Abbrechen") { editor.cancelExport() }
                }
            } else if let url = editor.exportResult {
                Label("Export fertig", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text(url.lastPathComponent).foregroundStyle(.secondary)
                HStack {
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Abspielen") { NSWorkspace.shared.open(url) }
                    Spacer()
                    Button("Fertig") { isPresented = false }.keyboardShortcut(.defaultAction)
                }
            } else if let error = editor.exportError {
                Label("Export fehlgeschlagen", systemImage: "xmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(error).font(.callout)
                HStack {
                    Spacer()
                    Button("Schließen") { isPresented = false }.keyboardShortcut(.defaultAction)
                }
            } else {
                settings
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Video exportieren").font(.title3.bold())
            Form {
                Picker("Vorlage", selection: Binding(get: { preset }, set: { p in
                    presetRaw = p.rawValue
                    var s = editor.settings
                    p.apply(to: &s)
                    editor.settings = s
                })) {
                    ForEach(ExportPreset.allCases) { Text($0.label).tag($0) }
                }
                if preset == .vertical || preset == .square {
                    Text("Ändert das Format des Projekts – im Vorschaubild prüfen, ob alles Wichtige im Bild ist (Zooms helfen).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if preset == .gif {
                    Text("12 Bilder pro Sekunde, höchstens 720 Pixel breit, ohne Ton. Für kurze Ausschnitte gedacht.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Auflösung", selection: $editor.settings.exportShortSide) {
                    Text("720p").tag(720)
                    Text("1080p").tag(1080)
                    Text("1440p").tag(1440)
                    Text("4K").tag(2160)
                }
                .pickerStyle(.segmented)
                Picker("Bildrate", selection: $editor.settings.exportFPS) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)
                Toggle("HEVC (kleinere Dateien)", isOn: $editor.settings.exportHEVC)
                    .disabled(preset == .gif)
                LabeledContent("Format") {
                    let size = editor.renderer.outputSize
                    Text("\(editor.settings.aspect.rawValue) · \(Int(size.width)) × \(Int(size.height)) · \(preset == .gif ? "GIF" : "MP4")")
                }
                if !editor.settings.chapters.isEmpty && preset != .gif {
                    LabeledContent("Kapitel", value: "\(editor.outputChapters.count) – als Textdatei daneben")
                }
                LabeledContent("Länge", value: formatTime(editor.outputDuration))
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Abbrechen") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Exportieren …") { chooseFileAndExport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func chooseFileAndExport() {
        let panel = NSSavePanel()
        let gif = preset == .gif
        panel.allowedContentTypes = [gif ? .gif : .mpeg4Movie]
        panel.nameFieldStringValue = gif ? editor.project.name + ".gif" : editor.suggestedExportName
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await editor.export(to: url) }
    }
}
