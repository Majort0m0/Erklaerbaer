import SwiftUI
import AppKit

/// Vertical layout of the timeline lanes. Audio lanes share the remaining height.
struct TimelineLayout {
    let ruler: CGFloat = 20
    let gap: CGFloat = 4
    let clipH: CGFloat = 40
    /// Camera layouts (0 without a camera).
    let cameraH: CGFloat
    let zoomH: CGFloat = 24
    /// Pointer highlights per range (0 when hidden in the simple mode).
    let cursorH: CGFloat
    /// Masks and markings (0 when hidden in the simple mode).
    let maskH: CGFloat
    let annotationH: CGFloat
    let textH: CGFloat = 24
    /// Pictures and video overlays.
    let mediaH: CGFloat = 24
    let mediaRows: Int
    let audioH: CGFloat
    let audioCount: Int

    init(available: CGFloat, audioCount: Int, hasCamera: Bool = false, showMasks: Bool = true, showAnnotations: Bool = true,
         showCursor: Bool = true, mediaRows: Int = 1) {
        self.audioCount = audioCount
        self.mediaRows = mediaRows
        cameraH = hasCamera ? 20 : 0
        cursorH = showCursor ? 20 : 0
        maskH = showMasks ? 20 : 0
        annotationH = showAnnotations ? 20 : 0
        let fixed = ruler + gap + clipH + gap + (hasCamera ? 20 + gap : 0) + zoomH + gap + (showCursor ? 20 + gap : 0) + (showMasks ? 20 + gap : 0)
            + (showAnnotations ? 20 + gap : 0) + textH + gap + CGFloat(mediaRows) * 24 + CGFloat(mediaRows - 1) * 2 + gap
        let free = available - fixed - CGFloat(audioCount) * gap
        audioH = audioCount == 0 ? 0 : min(110, max(30, free / CGFloat(audioCount)))
    }

    var clipY: CGFloat { ruler + gap }
    var cameraY: CGFloat { clipY + clipH + gap }
    var zoomY: CGFloat { cameraY + (cameraH > 0 ? cameraH + gap : 0) }
    var cursorY: CGFloat { zoomY + zoomH + gap }
    var maskY: CGFloat { cursorY + (cursorH > 0 ? cursorH + gap : 0) }
    var annotationY: CGFloat { maskY + (maskH > 0 ? maskH + gap : 0) }
    var textY: CGFloat { annotationY + (annotationH > 0 ? annotationH + gap : 0) }
    var mediaY: CGFloat { textY + textH + gap }
    var mediaPitch: CGFloat { mediaH + 2 }
    var mediaTotal: CGFloat { CGFloat(mediaRows) * mediaH + CGFloat(mediaRows - 1) * 2 }
    /// The higher a lane, the further up it is (and in the picture).
    func mediaRowY(_ lane: Int) -> CGFloat { mediaY + CGFloat(mediaRows - 1 - min(lane, mediaRows - 1)) * mediaPitch }
    func audioY(_ i: Int) -> CGFloat { mediaY + mediaTotal + gap + CGFloat(i) * (audioH + gap) }
    var total: CGFloat { audioY(audioCount) }
}

/// Maps timeline time to x in the lanes (zoomed and scrolled).
struct TimelineScale {
    /// Time at x = 0.
    let start: Double
    let span: Double
    let width: CGFloat

    var pps: CGFloat { width / CGFloat(max(1e-6, span)) }
    var end: Double { start + span }
    func x(_ t: Double) -> CGFloat { CGFloat(t - start) * pps }
    func time(_ x: CGFloat) -> Double { start + Double(x / pps) }

    /// The on-screen part of a time range.
    struct Visible {
        let lo: Double
        let hi: Double
        let x: CGFloat
        let width: CGFloat
        /// The range continues off screen on this side.
        let clippedLeft: Bool
        let clippedRight: Bool
    }

    /// Visible part of `lo…hi`, nil if it is off screen. Only the visible part is laid out, so a
    /// long clip at a close zoom never becomes a huge view.
    func visible(_ lo: Double, _ hi: Double) -> Visible? {
        let a = max(lo, start), b = min(hi, end)
        guard b > a else { return nil }
        return Visible(lo: a, hi: b, x: x(a), width: CGFloat(b - a) * pps,
                       clippedLeft: a > lo + 1e-9, clippedRight: b < hi - 1e-9)
    }
}

/// Timeline: ruler, clip track (intro/outro, trim, cuts, dissolves, clicks), zoom, mask and text
/// lanes, one lane per audio track (waveform, muted ranges, voice-over clips with crossfades),
/// the playhead and, below, zoom controls with an overview of the visible part.
struct EditorTimeline: View {
    @ObservedObject var editor: EditorModel
    static let headerWidth: CGFloat = 186
    static let footerHeight: CGFloat = 24

    var body: some View {
        GeometryReader { outer in
            let lanes = editor.audioLanes
            let layout = TimelineLayout(available: outer.size.height - Self.footerHeight, audioCount: lanes.count, hasCamera: editor.hasCamera,
                                        showMasks: !editor.simpleMode || !editor.settings.masks.isEmpty,
                                        showAnnotations: !editor.simpleMode || !editor.settings.annotations.isEmpty,
                                        showCursor: !editor.simpleMode || !editor.settings.cursorRanges.isEmpty, mediaRows: editor.mediaRows)
            let laneWidth = max(1, outer.size.width - Self.headerWidth)
            let scale = TimelineScale(start: editor.visibleStart, span: editor.visibleSpan, width: laneWidth)
            VStack(spacing: 0) {
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        LaneHeaders(editor: editor, layout: layout, lanes: lanes)
                            .frame(width: Self.headerWidth, height: layout.total, alignment: .topLeading)
                        TimelineContent(editor: editor, layout: layout, lanes: lanes, scale: scale)
                            .frame(width: laneWidth, height: layout.total)
                    }
                }
                .scrollIndicators(layout.total > outer.size.height - Self.footerHeight + 1 ? .visible : .hidden)
                HStack(spacing: 0) {
                    ZoomControls(editor: editor)
                        .frame(width: Self.headerWidth, alignment: .leading)
                    OverviewBar(editor: editor)
                        .frame(width: laneWidth)
                }
                .frame(height: Self.footerHeight)
            }
            .background(TimelineScrollCatcher(editor: editor, laneLeft: Self.headerWidth))
            .onAppear { editor.timelineWidth = laneWidth }
            .onChange(of: laneWidth) { _, width in editor.timelineWidth = width }
        }
    }
}

// MARK: - Lane headers

private struct LaneHeaders: View {
    @ObservedObject var editor: EditorModel
    let layout: TimelineLayout
    let lanes: [AudioLane]

    var body: some View {
        ZStack(alignment: .topLeading) {
            // A click on an empty part of the header column ends the selection.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { editor.selection = nil }
            row("Video", icon: "film", panel: .video, y: layout.clipY, height: layout.clipH)
            if layout.cameraH > 0 { row("Kamera", icon: "web.camera", panel: .camera, y: layout.cameraY, height: layout.cameraH, lock: "camera") }
            row("Zoom", icon: "plus.magnifyingglass", panel: .zoom, y: layout.zoomY, height: layout.zoomH, lock: "zoom")
            if layout.cursorH > 0 { row("Cursor", icon: "cursorarrow.rays", panel: .cursor, y: layout.cursorY, height: layout.cursorH, lock: "cursor") }
            if layout.maskH > 0 { row("Masken", icon: "square.grid.3x3", panel: .masks, y: layout.maskY, height: layout.maskH, lock: "masks") }
            if layout.annotationH > 0 {
                row("Markierung", icon: "arrow.up.right", panel: .annotations, y: layout.annotationY, height: layout.annotationH, lock: "annotations")
            }
            row("Text", icon: "textformat", panel: .texts, y: layout.textY, height: layout.textH, link: .texts, lock: "texts")
            row("Medien", icon: "photo.on.rectangle.angled", panel: .media, y: layout.mediaY, height: layout.mediaTotal, link: .media, lock: "media")
            ForEach(Array(lanes.enumerated()), id: \.element) { i, lane in
                audioHeader(lane)
                    .frame(height: layout.audioH)
                    .offset(y: layout.audioY(i))
            }
        }
        .padding(.trailing, 8)
    }

    /// Lane name; a click selects the lane and opens its settings.
    private func row(_ title: String, icon: String, panel: EditorPanel, y: CGFloat, height: CGFloat,
                     link: EditorModel.LinkableLane? = nil, lock: String? = nil) -> some View {
        LaneHeaderRow(title: title, icon: icon, color: Theme.color(panel), height: height, selected: editor.selection == .panel(panel),
                      select: { editor.selection = .panel(panel) }) {
            HStack(spacing: 0) {
                if let lock, editor.isLocked(lock) { lockMark(lock) }
                if let link { linkButton(link) }
            }
        }
        .contextMenu { if let lock { lockMenu(lock) } }
        .help("\(title)-Spur auswählen – ihre Einstellungen erscheinen rechts. Rechtsklick: Spur sperren")
        .offset(y: y)
    }

    private func lockMark(_ lane: String) -> some View {
        Button { editor.toggleLock(lane) } label: {
            Image(systemName: "lock.fill").font(.system(size: 9.5)).foregroundStyle(.secondary).frame(width: 18, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Spur ist gesperrt – klicken entsperrt sie")
    }

    @ViewBuilder
    private func lockMenu(_ lane: String) -> some View {
        Button(editor.isLocked(lane) ? "Spur entsperren" : "Spur sperren") { editor.toggleLock(lane) }
    }

    /// Chain symbol: is this lane tied to the video?
    private func linkButton(_ lane: EditorModel.LinkableLane) -> some View {
        let free = editor.isFree(lane)
        return Button {
            editor.setLane(lane, free: !free)
        } label: {
            LinkSymbol(free: free)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(free ? "Frei: Clips dieser Spur bleiben stehen, wenn das Video geschnitten oder umgestellt wird. Klicken koppelt die Spur ans Video."
                   : "Ans Video gekoppelt: Clips dieser Spur werden mitgeschnitten und wandern mit. Klicken macht die Spur frei.")
    }

    private func audioHeader(_ lane: AudioLane) -> some View {
        let muted = editor.isMuted(lane)
        return LaneHeaderRow(title: lane.label, icon: lane.icon, color: TimelineContent.color(lane), height: layout.audioH,
                             selected: editor.selection == .audioLane(lane), dimmed: muted,
                             select: { editor.selection = .audioLane(lane) }) {
            HStack(spacing: 0) {
                if editor.isLocked(lane.role) { lockMark(lane.role) }
                if lane == .voiceOver { linkButton(.voiceOver) }
                Button {
                    editor.toggleMute(lane)
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(muted ? Theme.record : Color.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(muted ? "\(lane.label) wieder einschalten" : "\(lane.label) stummschalten")
                Menu {
                    if lane == .music {
                        Button("Am Abspielkopf schneiden") { editor.splitLane(.music, at: editor.currentTime) }
                        Button("Weiteren Clip einfügen …") { editor.chooseMusicClip() }
                        Button("Andere Musik …") { editor.chooseMusic() }
                        Button("Musik entfernen", role: .destructive) { editor.removeMusic() }
                    } else {
                        Button("Ab Abspielkopf stummschalten") { editor.addMute(lane: lane) }
                        Button("Ab Abspielkopf leiser") { editor.addMute(lane: lane, gain: 0.4) }
                        Button("Am Abspielkopf schneiden") { editor.splitLane(lane, at: editor.currentTime) }
                    }
                    Button("Spur auswählen") { editor.selection = .audioLane(lane) }
                    if lane == .voiceOver {
                        Button("Voice-over einsprechen") { editor.toggleVoiceOver() }
                        Button("Audiodatei einfügen …") { editor.addNarrationFile() }
                    }
                    if editor.canDetachSound(lane) {
                        Button("Ton vom Video lösen") { editor.detachSound(lane) }
                    }
                    Divider()
                    lockMenu(lane.role)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
                .fixedSize()
                .help("Bereich dieser Spur stummschalten, schneiden …")
            }
        }
        .help("Spur auswählen: Lautstärke, Stimme verbessern, am Abspielkopf schneiden")
    }
}

/// Header of one lane: a rounded row as tall as the lane with a colored symbol tile and the name;
/// hovering lightens it, the selected lane gets the yellow outline.
private struct LaneHeaderRow<Trailing: View>: View {
    let title: String
    let icon: String
    let color: Color
    let height: CGFloat
    let selected: Bool
    var dimmed = false
    let select: () -> Void
    @ViewBuilder let trailing: () -> Trailing
    @StateObject private var hover = HoverFlag()

    var body: some View {
        let tall = height >= 34
        HStack(spacing: 7) {
            IconTile(icon: icon, color: color, size: tall ? 20 : min(16, height - 4), active: !dimmed)
            Text(title)
                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(dimmed ? Color.secondary.opacity(0.6) : selected ? Color.primary : Color.primary.opacity(0.78))
                .lineLimit(1)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.leading, tall ? 7 : 5)
        .padding(.trailing, 4)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.laneRadius, style: .continuous)
            .fill(selected ? TimelineSelection.color.opacity(0.14) : hover.on ? Theme.laneHover : Theme.lane))
        .overlay(RoundedRectangle(cornerRadius: Theme.laneRadius, style: .continuous)
            .strokeBorder(selected ? TimelineSelection.color : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture(perform: select)
    }
}

// MARK: - Content

private struct TimelineContent: View {
    @ObservedObject var editor: EditorModel
    let layout: TimelineLayout
    let lanes: [AudioLane]
    let scale: TimelineScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: scale.width, height: layout.total)
                .contentShape(Rectangle())
                .onTapGesture { editor.selection = nil }
            laneHighlight
            videoLane
            if layout.cameraH > 0 { locked("camera") { cameraLane } }
            locked("zoom") { zoomLane }
            if layout.cursorH > 0 { locked("cursor") { cursorLane } }
            if layout.maskH > 0 { locked("masks") { maskLane } }
            if layout.annotationH > 0 { locked("annotations") { annotationLane } }
            locked("texts") { textLane }
            locked("media") { mediaLane }
            ForEach(Array(lanes.enumerated()), id: \.element) { i, lane in
                locked(lane.role) { audioLane(lane, y: layout.audioY(i)) }
            }
            removedBands
            ruler
            chapterMarkers
            snapGuide
            playhead
            if let box = editor.marquee {
                Rectangle()
                    .fill(TimelineSelection.color.opacity(0.14))
                    .overlay(Rectangle().strokeBorder(TimelineSelection.color, lineWidth: 1))
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: scale.width, height: layout.total, alignment: .topLeading)
        .clipped()
        .coordinateSpace(name: "timeline")
        .onDrop(of: EditorModel.droppableTypes, delegate: TimelineDropDelegate(editor: editor, layout: layout, scale: scale,
                                                                              lanes: lanes, highlight: dropHighlight))
        .overlay(alignment: .topLeading) { DropHighlightView(highlight: dropHighlight, width: scale.width) }
    }

    /// A locked lane can't be changed with the mouse.
    private func locked<Content: View>(_ lane: String, @ViewBuilder content: () -> Content) -> some View {
        let isLocked = editor.isLocked(lane)
        return content().allowsHitTesting(!isLocked).opacity(isLocked ? 0.5 : 1)
    }

    /// Lane that files are dragged over (drawn as a highlight).
    @StateObject private var dropHighlight = DropHighlight()

    /// Where something was cut out the timeline has closed up: a thin line through all lanes.
    @ViewBuilder
    private var removedBands: some View {
        let top = layout.clipY + layout.clipH
        let height = layout.total - top
        ForEach(editor.settings.cuts) { cut in
            let x = scale.x(T(cut.start))
            if x > 0, x < scale.width {
                Path { p in p.move(to: CGPoint(x: 0.5, y: 0)); p.addLine(to: CGPoint(x: 0.5, y: height)) }
                    .stroke((cut.origin == nil ? Color.red : Color.orange).opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 1, height: height)
                    .offset(x: x, y: top)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Outline of the selected lane.
    @ViewBuilder
    private var laneHighlight: some View {
        let row: (y: CGFloat, h: CGFloat)? = {
            switch editor.selection {
            case .panel(.video): return (layout.clipY, layout.clipH)
            case .panel(.camera): return layout.cameraH > 0 ? (layout.cameraY, layout.cameraH) : nil
            case .panel(.zoom): return (layout.zoomY, layout.zoomH)
            case .panel(.cursor): return layout.cursorH > 0 ? (layout.cursorY, layout.cursorH) : nil
            case .panel(.masks): return (layout.maskY, layout.maskH)
            case .panel(.annotations): return (layout.annotationY, layout.annotationH)
            case .panel(.texts): return (layout.textY, layout.textH)
            case .panel(.media): return (layout.mediaY, layout.mediaTotal)
            case .audioLane(let lane): return lanes.firstIndex(of: lane).map { (layout.audioY($0), layout.audioH) }
            default: return nil
            }
        }()
        if let row {
            RoundedRectangle(cornerRadius: 8)
                .fill(TimelineSelection.color.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TimelineSelection.color.opacity(0.9), lineWidth: 2))
                .frame(width: scale.width, height: row.h + 4)
                .offset(y: row.y - 2)
                .allowsHitTesting(false)
        }
    }

    /// Lane of the hover ghost → panel of that lane.
    private func panel(_ lane: TimelineHover.Lane) -> EditorPanel {
        switch lane {
        case .zoom: return .zoom
        case .mask: return .masks
        case .text: return .texts
        case .annotation: return .annotations
        case .camera: return .camera
        case .media: return .media
        case .cursor: return .cursor
        }
    }

    /// Adding in an empty lane only while nothing else is selected (else the click ends the selection).
    private func addsOnClick(_ lane: TimelineHover.Lane) -> Bool {
        editor.selection == nil || editor.selection == .panel(panel(lane))
    }

    /// Click or drag: moves the playhead to the mouse (snapping to edges).
    private var scrub: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { v in scrub(to: v.location.x) }
    }

    private func scrub(to x: CGFloat) {
        guard editor.voiceOverState == .idle else { return }
        if editor.isPlaying { editor.pause() }
        editor.seek(to: S(editor.snapTime(scale.time(x), tolerance: snapTolerance, includePlayhead: false)))
    }

    /// 8 points in seconds.
    private var snapTolerance: Double { Double(8 / scale.pps) }

    // Items are stored in source time; the timeline shows timeline time (speed, freeze frames).
    private func T(_ source: Double) -> Double { editor.display(source) }
    private func S(_ timeline: Double) -> Double { editor.sourceTime(timeline) }
    /// Visible part of a source range.
    private func vis(_ lo: Double, _ hi: Double) -> TimelineScale.Visible? {
        editor.displayRun(lo, hi).flatMap { scale.visible($0.lowerBound, $0.upperBound) }
    }
    /// The whole length of the edited timeline.
    private var laneVisible: TimelineScale.Visible? { scale.visible(0, editor.timeMap.total) }

    /// New source range of an item dragged by `dt` timeline seconds (snapped, kept on the recording).
    private func dragged(_ kind: RangeBlock.DragKind, _ dt: Double, start: Double, end: Double, minLength: Double,
                         id: UUID) -> (start: Double, end: Double) {
        let run = editor.displayRun(start, end)
        let a = run?.lowerBound ?? T(start), b = run?.upperBound ?? T(end)
        let dt = snapped(kind, dt, a, b, id)
        let r = RangeBlock.apply(kind, dt: dt, start: a, end: b, duration: editor.timeMap.total, minLength: minLength)
        return (S(r.start), editor.timeMap.sourceEnd(r.end))
    }

    /// The same for an item that is not tied to the video (its times are timeline times).
    private func draggedFree(_ kind: RangeBlock.DragKind, _ dt: Double, start: Double, end: Double, minLength: Double,
                             id: UUID) -> (start: Double, end: Double) {
        let dt = snapped(kind, dt, start, end, id)
        let r = RangeBlock.apply(kind, dt: dt, start: start, end: end, duration: editor.timeMap.total, minLength: minLength)
        return (r.start, r.end)
    }

    /// `dt` of a block drag adjusted for snapping.
    private func snapped(_ kind: RangeBlock.DragKind, _ dt: Double, _ start: Double, _ end: Double, _ id: UUID) -> Double {
        let edge: EditorModel.SnapEdge = kind == .move ? .move : kind == .start ? .start : .end
        if let glued = editor.magnetDelta(edge, dt: dt, start: start, end: end, id: id, tolerance: Double(18 / scale.pps)) { return glued }
        return editor.snapDelta(edge, dt: dt, start: start, end: end, tolerance: snapTolerance, excluding: id)
    }

    @ViewBuilder
    private var snapGuide: some View {
        if let t = editor.snapGuide, t >= scale.start, t <= scale.end {
            Rectangle()
                .fill(Color.yellow)
                .frame(width: 1, height: layout.total - layout.ruler)
                .offset(x: scale.x(t), y: layout.ruler)
                .allowsHitTesting(false)
        }
    }

    private var ruler: some View {
        RulerCanvas(scale: scale, duration: editor.timeMap.total)
            .frame(width: scale.width, height: layout.ruler)
            .contentShape(Rectangle())
            .gesture(scrub)
            .help("Klicken oder ziehen setzt den Abspielkopf")
    }

    @ViewBuilder
    private var playhead: some View {
        let px = scale.x(T(editor.currentTime))
        if px >= -8 && px <= scale.width + 8 {
            PlayheadView(rulerHeight: layout.ruler, height: layout.total)
                .frame(width: PlayheadView.width, height: layout.total)
                .contentShape(PlayheadView.HitShape(rulerHeight: layout.ruler))
                .gesture(scrub)
                .pointerStyle(.columnResize)
                .help("Abspielkopf – ziehen zum Verschieben, ←/→ für einzelne Bilder")
                .offset(x: px - PlayheadView.width / 2)
        }
    }

    // MARK: Video lane

    @ViewBuilder
    private var videoLane: some View {
        let h = layout.clipH
        let y = layout.clipY
        let parts = editor.clipParts
        let drag = editor.clipDrag

        // The parts of the video: move by dragging, edges trim and the gap closes.
        ForEach(parts, id: \.key) { part in
            if !isInsert(part), let run = editor.clipRun(part), let v = scale.visible(run.lowerBound, run.upperBound) {
                clipBlock(part, visible: v, height: h)
                    .offset(x: v.x, y: y)
            }
        }
        if let v = laneVisible {
            ClickDots(clicks: editor.project.cursor.clicks, scale: scale, map: editor.timeMap, left: v.x)
                .padding(.bottom, 6)
                .frame(width: v.width, height: h)
                .offset(x: v.x, y: y)
        }

        // Faster/slower parts: tint and badge
        ForEach(editor.settings.speeds) { speed in
            if let v = vis(speed.start, speed.end) {
                SpeedBadge(rate: speed.rate, visible: v, height: h)
                    .offset(x: v.x, y: y)
                    .allowsHitTesting(false)
            }
        }
        let moving = drag.map { editor.clipDragKeys($0.key) } ?? []
        ForEach(parts.filter { editor.selection == .segment($0.range.lowerBound) || editor.isInGroup(.segment($0.range.lowerBound)) }, id: \.key) { part in
            if let v = vis(part.range.lowerBound, part.range.upperBound) {
                BlockShape(visible: v, radius: 7)
                    .fill(TimelineSelection.color.opacity(0.12))
                    .timelineSelection(true, shape: BlockShape(visible: v, radius: 7))
                    .frame(width: v.width, height: h)
                    .allowsHitTesting(false)
                    .offset(x: v.x + (moving.contains(part.key) ? CGFloat(drag?.dt ?? 0) * scale.pps : 0), y: y)
            }
        }

        // Where something was cut out, with its transition
        let dissolves = editor.dissolvesByCut
        ForEach(editor.settings.cuts) { cut in
            let x = scale.x(T(cut.start))
            if x >= -9, x <= scale.width + 9 {
                CutSeam(editor: editor, cut: cut, height: h)
                    .offset(x: x - CutSeam.width / 2, y: y)
            }
            if let dissolve = dissolves[cut.id] {
                dissolveCurves(dissolve, y: y, height: h)
            }
        }

        // Where two parts meet without a cut: a transition can be set there
        ForEach(parts.indices.dropFirst(), id: \.self) { i in
            if i < parts.count, !editor.joinHasCut(after: parts[i - 1], before: parts[i]), let run = editor.clipRun(parts[i]),
               case let x = scale.x(run.lowerBound), x >= -9, x <= scale.width + 9 {
                JoinMark(editor: editor, key: parts[i].key, height: h)
                    .offset(x: x - JoinMark.width / 2, y: y)
            }
        }
        ForEach(editor.settings.joinTransitions) { t in
            if let dissolve = dissolves[t.id] { dissolveCurves(dissolve, y: y, height: h) }
        }

        // Intro / outro title cards, and the part pushed over the recording
        if let intro = editor.settings.intro {
            if let v = scale.visible(-editor.introLead, 0) {
                cardBlock(intro, label: "Vorspann", visible: v).offset(x: v.x, y: y)
            }
            let overlap = editor.introOverlapLength
            if overlap > 0, let v = scale.visible(0, overlap) {
                cardOverlap(intro, visible: v, range: 0...overlap, fadingOut: true).offset(x: v.x, y: y)
            }
        }
        if let outro = editor.settings.outro {
            let total = editor.timeMap.total
            if let v = scale.visible(total, total + editor.outroLead) {
                cardBlock(outro, label: "Abspann", visible: v).offset(x: v.x, y: y)
            }
            let overlap = editor.outroOverlapLength
            if overlap > 0, let v = scale.visible(total - overlap, total) {
                cardOverlap(outro, visible: v, range: (total - overlap)...total, fadingOut: false).offset(x: v.x, y: y)
            }
        }

        // Freeze frames: own block, drag the right edge to change the duration
        ForEach(editor.settings.freezes) { freeze in
            if let v = vis(freeze.sourceRange.lowerBound, freeze.at) {
                FreezeBlock(editor: editor, freeze: freeze, visible: v, pps: scale.pps, height: h,
                            snap: { dt in snapped(.end, dt, v.lo, v.hi, freeze.id) })
                    .offset(x: v.x, y: y)
            }
        }

        // Inserted clips: own block, drag the right edge to shorten, drag the clip to move it
        ForEach(editor.settings.inserts) { clip in
            if let v = vis(clip.sourceRange.lowerBound, clip.at) {
                let part = parts.first { abs($0.range.lowerBound - clip.sourceRange.lowerBound) < 1e-6 }
                InsertBlock(editor: editor, clip: clip, visible: v, pps: scale.pps, height: h,
                            snap: { dt in snapped(.end, dt, v.lo, v.hi, clip.id) })
                    .gesture(part.map { moveGesture($0) })
                    .offset(x: v.x + (part != nil && drag?.key == part?.key ? CGFloat(drag?.dt ?? 0) * scale.pps : 0), y: y)
                    .zIndex(part != nil && drag?.key == part?.key ? 5 : 0)
            }
        }

        // Dissolve handles of the selected cut (drawn above everything in the clip lane)
        if let id = editor.selectedCutID, let cut = editor.settings.cuts.first(where: { $0.id == id }), editor.canDissolve(cut) {
            dissolveHandles(cut, dissolve: dissolves[cut.id], y: y)
        }

        // Where a dragged part would land
        if let drag, let overlap = editor.clipDragOverlap(drag, minimum: overlapMinimum) {
            // Pushed onto its neighbor: the two will dissolve.
            Text(String(format: "Überblendung %.1f s", overlap.length))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(TimelineSelection.color))
                .fixedSize()
                .offset(x: scale.x(overlap.at) - 44, y: y + h / 2 - 11)
                .allowsHitTesting(false)
                .zIndex(6)
        } else if let drag, let t = editor.clipDropPosition(drag) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(TimelineSelection.color)
                .frame(width: 3, height: h + 8)
                .offset(x: scale.x(t) - 1.5, y: y - 4)
                .allowsHitTesting(false)
                .zIndex(6)
        }

        // The ends of the video
        if let first = parts.first, !isInsert(first) {
            TrimHandle(isStart: true, height: h)
                .gesture(edgeGesture(first, isStart: true))
                .offset(x: scale.x(0) - 5, y: y)
        }
        if let last = parts.last, !isInsert(last) {
            TrimHandle(isStart: false, height: h)
                .gesture(edgeGesture(last, isStart: false))
                .offset(x: scale.x(editor.timeMap.total) - 5, y: y)
        }
    }

    private func isInsert(_ part: EditSettings.ClipPart) -> Bool {
        editor.settings.inserts.contains { abs($0.sourceRange.lowerBound - part.range.lowerBound) < 1e-6 }
    }

    private func edgeGesture(_ part: EditSettings.ClipPart, isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
            .onChanged { v in
                if editor.isPlaying { editor.pause() }
                if editor.trimMode == .roll {
                    editor.rollEdge(of: part, isStart: isStart, dt: Double(v.translation.width / scale.pps))
                } else {
                    editor.dragEdge(of: part, isStart: isStart, dt: Double(v.translation.width / scale.pps))
                }
            }
            .onEnded { _ in if editor.trimMode == .roll { editor.finishTrimDrag() } else { editor.endInteraction() } }
    }

    /// Dragging across empty lanes draws a rectangle; what it touches is selected.
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("timeline"))
            .onChanged { v in
                editor.timelineHover.lane = nil
                editor.marquee = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                        width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
            }
            .onEnded { _ in
                defer { editor.marquee = nil }
                guard let box = editor.marquee else { return }
                let time = scale.time(box.minX)...scale.time(box.maxX)
                let lanes = editor.audioLanes
                func row(_ name: String) -> ClosedRange<CGFloat>? {
                    func band(_ y: CGFloat, _ h: CGFloat) -> ClosedRange<CGFloat>? { h > 0 ? y...(y + h) : nil }
                    switch name {
                    case "clip": return band(layout.clipY, layout.clipH)
                    case "zoom": return band(layout.zoomY, layout.zoomH)
                    case "cursor": return band(layout.cursorY, layout.cursorH)
                    case "mask": return band(layout.maskY, layout.maskH)
                    case "annotation": return band(layout.annotationY, layout.annotationH)
                    case "text": return band(layout.textY, layout.textH)
                    case "media": return band(layout.mediaY, layout.mediaTotal)
                    default: return AudioLane(rawValue: name).flatMap { lane in lanes.firstIndex(of: lane).flatMap { band(layout.audioY($0), layout.audioH) } }
                    }
                }
                let vertical = box.minY...box.maxY
                editor.selectGroup(editor.timelineItems().filter { item in
                    item.range.overlaps(time) && (row(item.row)?.overlaps(vertical) ?? false) && !editor.isLocked(item.row == "mask" ? "masks" : item.row == "annotation" ? "annotations" : item.row == "text" ? "texts" : item.row)
                }.map(\.item))
            }
    }

    /// A part must be pushed at least this far onto its neighbor to dissolve (a slip of the mouse does nothing).
    private var overlapMinimum: Double { max(0.12, Double(14 / scale.pps)) }

    /// Drag: moves the part to another place (with a single part: moves the playhead).
    /// Click: selects the part and puts the playhead there.
    private func moveGesture(_ part: EditSettings.ClipPart) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { v in
                let dx = v.translation.width
                if editor.clipDrag == nil, abs(dx) < 4 { return }
                if editor.trimMode == .slip {
                    if editor.isPlaying { editor.pause() }
                    editor.slipPart(part, dt: Double(dx / scale.pps))
                    return
                }
                if editor.clipParts.count < 2 { scrub(to: v.location.x); return }
                if editor.isPlaying { editor.pause() }
                editor.clipDrag = EditorModel.ClipDrag(key: part.key, dt: Double(dx / scale.pps))
            }
            .onEnded { v in
                if editor.trimMode == .slip, editor.slipOrigin != nil {
                    editor.finishTrimDrag()
                } else if let drag = editor.clipDrag {
                    editor.finishClipDrag(drag, minimum: overlapMinimum)
                } else if abs(v.translation.width) < 4 {
                    guard editor.voiceOverState == .idle else { return }
                    if editor.isPlaying { editor.pause() }
                    editor.seek(to: S(editor.snapTime(scale.time(v.location.x), tolerance: snapTolerance, includePlayhead: false)))
                    if let clip = editor.settings.inserts.first(where: { abs($0.sourceRange.lowerBound - part.range.lowerBound) < 1e-6 }) {
                        editor.click(.insert(clip.id))
                    } else {
                        editor.click(.segment(part.range.lowerBound))
                    }
                }
            }
    }

    /// One part of the video in the lane.
    private func clipBlock(_ part: EditSettings.ClipPart, visible v: TimelineScale.Visible, height h: CGFloat) -> some View {
        let shape = BlockShape(visible: v, radius: Theme.laneRadius + 2)
        let dragged = editor.clipDrag.map { editor.clipDragKeys($0.key).contains(part.key) } ?? false
        let width = max(2, v.width - 1.5)
        return ZStack(alignment: .topLeading) {
            shape.fill(Theme.color(.video).opacity(dragged ? 0.4 : 0.16))
            shape.strokeBorder(Theme.color(.video).opacity(0.45), lineWidth: 1)
            if width > 90 && !v.clippedLeft {
                Text(editor.project.info.sourceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 10)
                    .padding(.trailing, 10)
                    .padding(.top, 6)
            }
        }
        .frame(width: width, height: h)
        .contentShape(Rectangle())
        .gesture(moveGesture(part))
        .overlay(alignment: .leading) {
            if !v.clippedLeft, width > 30 {
                Color.white.opacity(0.001)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(edgeGesture(part, isStart: true))
                    .help("Kante ziehen: kürzt den Teil, die Lücke schließt sich – zurückziehen holt das Entfernte wieder")
            }
        }
        .overlay(alignment: .trailing) {
            if !v.clippedRight, width > 30 {
                Color.white.opacity(0.001)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(edgeGesture(part, isStart: false))
                    .help("Kante ziehen: kürzt den Teil, die Lücke schließt sich – zurückziehen holt das Entfernte wieder")
            }
        }
        .contextMenu { partMenu(part) }
        .help("Teil des Videos: klicken wählt aus, ziehen verschiebt ihn an eine andere Stelle, S teilt am Abspielkopf, ⇧S verbindet geteilte Teile wieder")
        .offset(x: dragged ? CGFloat(editor.clipDrag?.dt ?? 0) * scale.pps : 0)
        .shadow(color: dragged ? .black.opacity(0.35) : .clear, radius: dragged ? 8 : 0, y: dragged ? 3 : 0)
        .zIndex(dragged ? 5 : 0)
    }

    /// Right click on a part of the video.
    @ViewBuilder
    private func partMenu(_ part: EditSettings.ClipPart) -> some View {
        let n = editor.joinNeighbors(of: part)
        if let previous = n.previous { Button("Mit dem Teil davor verbinden") { editor.join([previous]) } }
        if let next = n.next { Button("Mit dem Teil danach verbinden") { editor.join([next]) } }
        Button("Am Abspielkopf teilen") { editor.perform(.split) }
        Button("Teil entfernen") {
            editor.removeSegment(part.range)
        }
    }

    /// Fade curves of a dissolve at a cut: the part before the cut fades out, the part after it fades in.
    @ViewBuilder
    private func dissolveCurves(_ d: Dissolve, y: CGFloat, height: CGFloat) -> some View {
        if let v = vis(d.aStart, d.aEnd) {
            FadeCurve(kind: .videoOut, visible: v, range: T(d.aStart)...T(d.aEnd), pps: scale.pps)
                .frame(width: v.width, height: height)
                .allowsHitTesting(false)
                .offset(x: v.x, y: y)
        }
        if let v = vis(d.bStart, d.resume) {
            FadeCurve(kind: .videoIn, visible: v, range: T(d.bStart)...T(d.resume), pps: scale.pps)
                .frame(width: v.width, height: height)
                .allowsHitTesting(false)
                .offset(x: v.x, y: y)
        }
    }

    /// Two knobs at the top of the clip lane: drag them away from the cut to push the parts
    /// over each other (cross dissolve), back to the cut for a hard cut.
    @ViewBuilder
    private func dissolveHandles(_ cut: CutRange, dissolve: Dissolve?, y: CGFloat) -> some View {
        let length = dissolve?.length ?? 0
        let left = T(dissolve?.aEnd ?? cut.start) - length
        let right = T(dissolve?.bStart ?? cut.end) + length
        ForEach([true, false], id: \.self) { isLeft in
            DissolveKnob()
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                    .onChanged { v in
                        if editor.dissolveDragOrigin?.id != cut.id {
                            editor.dissolveDragOrigin = cut
                            editor.overlapDragOrigin = length
                            editor.beginInteraction()
                        }
                        let dt = Double(v.translation.width / scale.pps)
                        editor.setDissolve(cutID: cut.id, (editor.overlapDragOrigin ?? 0) + (isLeft ? -dt : dt))
                    }
                    .onEnded { _ in editor.endInteraction() })
                .help("Überblendung: vom Schnitt wegziehen, um die Teile übereinanderzuschieben")
                .offset(x: scale.x(isLeft ? left : right) - DissolveKnob.size / 2, y: y - DissolveKnob.size / 2 + 2)
        }
    }

    private func cardBlock(_ card: TextOverlay, label: String, visible v: TimelineScale.Visible) -> some View {
        let selected = editor.selectedTextID == card.id
        let isIntro = card.placement == .intro
        return BlockShape(visible: v, radius: 8)
            .fill(Color.indigo.opacity(selected ? 0.85 : 0.6))
            .timelineSelection(selected, shape: BlockShape(visible: v, radius: 8))
            .overlay(alignment: .leading) {
                if v.width > 50 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label).font(.caption2.bold())
                        Text(card.title).font(.caption2).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                }
            }
            .frame(width: max(8, v.width), height: layout.clipH)
            .contentShape(Rectangle())
            .onTapGesture {
                editor.selectedTextID = card.id
                editor.seek(to: isIntro ? editor.timelineStart + min(1, editor.introLead / 2) : editor.duration + min(1, editor.outroLead / 2))
            }
            .gesture(overlapDrag(card))
            .pointerStyle(.grabIdle)
            .help("\(label): über den \(isIntro ? "Anfang" : "Schluss") der Aufnahme ziehen für eine Überblendung; Text und Länge im Inspektor")
    }

    /// The part of an intro/outro card that lies over the recording, with both dissolve curves.
    private func cardOverlap(_ card: TextOverlay, visible v: TimelineScale.Visible, range: ClosedRange<Double>,
                             fadingOut: Bool) -> some View {
        let selected = editor.selectedTextID == card.id
        return BlockShape(visible: v, radius: 6)
            .fill(Color.indigo.opacity(selected ? 0.55 : 0.4))
            .overlay(FadeCurve(kind: fadingOut ? .videoOut : .videoIn, visible: v, range: range, pps: scale.pps, color: .white))
            .overlay(FadeCurve(kind: fadingOut ? .videoIn : .videoOut, visible: v, range: range, pps: scale.pps,
                               color: Theme.brand, shade: false))
            .frame(width: max(4, v.width), height: layout.clipH)
            .contentShape(Rectangle())
            .onTapGesture { editor.selectedTextID = card.id }
            .gesture(overlapDrag(card))
            .pointerStyle(.grabIdle)
            .help("Überblendung zwischen \(fadingOut ? "Vorspann" : "Abspann") und Aufnahme – ziehen ändert die Länge")
    }

    /// Dragging an intro to the right (an outro to the left) pushes it over the recording.
    private func overlapDrag(_ card: TextOverlay) -> some Gesture {
        let isIntro = card.placement == .intro
        return DragGesture(minimumDistance: 2, coordinateSpace: .named("timeline"))
            .onChanged { v in
                if editor.textDragOrigin?.id != card.id {
                    editor.textDragOrigin = card
                    editor.overlapDragOrigin = isIntro ? editor.introOverlapLength : editor.outroOverlapLength
                    editor.selectedTextID = card.id
                    editor.beginInteraction()
                }
                let dt = Double(v.translation.width / scale.pps)
                editor.setOverlap(intro: isIntro, (editor.overlapDragOrigin ?? 0) + (isIntro ? dt : -dt))
            }
            .onEnded { _ in editor.endInteraction() }
    }

    // MARK: Zoom, masks, texts

    /// Empty lane. With `adds`: hovering shows a ghost block where a new item fits, a click adds it.
    @ViewBuilder
    private func laneBackground(height: CGFloat, opacity: Double, hint: String?, y: CGFloat,
                                adds lane: TimelineHover.Lane? = nil, onTap: @escaping () -> Void) -> some View {
        if let v = laneVisible {
            let hover = editor.timelineHover
            BlockShape(visible: v, radius: Theme.laneRadius)
                .fill(Theme.lane)
                .overlay(alignment: .leading) {
                    if let hint, !v.clippedLeft {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .padding(.leading, 10)
                    }
                }
                .frame(width: v.width, height: height)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .named("timeline")) { phase in
                    guard let lane else { return }
                    switch phase {
                    case .active(let p):
                        if addsOnClick(lane), let range = editor.freeRange(lane, at: scale.time(p.x)) {
                            if hover.lane != lane { hover.lane = lane }
                            if hover.range != range { hover.range = range }
                        } else if hover.lane != nil {
                            hover.lane = nil
                        }
                    case .ended:
                        if hover.lane == lane { hover.lane = nil }
                    }
                }
                .gesture(marqueeGesture)
                .onTapGesture {
                    if let lane, hover.lane == lane, addsOnClick(lane) {
                        editor.add(lane, range: hover.range)
                        hover.lane = nil
                    } else {
                        hover.lane = nil
                        onTap()
                    }
                }
                .offset(x: v.x, y: y)
            if let lane {
                HoverGhost(hover: hover, lane: lane, scale: scale, height: height)
                    .offset(y: y)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var zoomLane: some View {
        laneBackground(height: layout.zoomH, opacity: 0.08,
                       hint: editor.settings.zoomSegments.isEmpty ? "Klicken fügt hier einen Zoom ein" : nil,
                       y: layout.zoomY, adds: .zoom) { editor.selection = nil }
        ForEach(editor.settings.zoomSegments) { seg in
            if let v = vis(seg.start, seg.end) {
                RangeBlock(visible: v, pps: scale.pps, height: layout.zoomH, color: .purple, icon: "plus.magnifyingglass",
                           label: String(format: "%.1f×", seg.scale), centered: true,
                           selected: editor.selectedZoomID == seg.id || editor.isInGroup(.zoom(seg.id)),
                           onSelect: { editor.click(.zoom(seg.id)) },
                           onDrag: { kind, dt in
                               if editor.dragGroup(kind, dt: dt, item: .zoom(seg.id)) { return }
                               if editor.zoomDragOrigin?.id != seg.id {
                                   editor.zoomDragOrigin = seg; editor.selectedZoomID = seg.id; editor.beginInteraction()
                               }
                               guard let o = editor.zoomDragOrigin else { return }
                               let r = dragged(kind, dt, start: o.start, end: o.end, minLength: 0.5, id: seg.id)
                               switch kind {
                               case .move: editor.updateZoom(id: seg.id, start: r.start, end: r.end)
                               case .start: editor.updateZoom(id: seg.id, start: r.start)
                               case .end: editor.updateZoom(id: seg.id, end: r.end)
                               }
                           },
                           onDragEnd: { editor.endInteraction() })
                    .help("Zoom-Bereich: ziehen zum Verschieben, Kanten ziehen zum Ändern, ⌫ zum Löschen")
                    .offset(x: v.x, y: layout.zoomY)
            }
        }
    }

    @ViewBuilder
    private var cursorLane: some View {
        laneBackground(height: layout.cursorH, opacity: 0.06,
                       hint: editor.settings.cursorRanges.isEmpty ? "Klicken: Cursor hier hervorheben oder ausblenden" : nil,
                       y: layout.cursorY, adds: .cursor) { editor.selection = nil }
        ForEach(editor.settings.cursorRanges) { range in
            if let v = vis(range.start, range.end) {
                RangeBlock(visible: v, pps: scale.pps, height: layout.cursorH, color: range.effect == .hidden ? .gray : .yellow,
                           icon: range.effect.icon, label: range.effect.label,
                           selected: editor.selection == .cursorRange(range.id) || editor.isInGroup(.cursorRange(range.id)),
                           onSelect: { editor.click(.cursorRange(range.id)) },
                           onDrag: { kind, dt in
                               if editor.dragGroup(kind, dt: dt, item: .cursorRange(range.id)) { return }
                               if editor.cursorRangeDragOrigin?.id != range.id {
                                   editor.cursorRangeDragOrigin = range; editor.selection = .cursorRange(range.id); editor.beginInteraction()
                               }
                               guard let o = editor.cursorRangeDragOrigin else { return }
                               let r = dragged(kind, dt, start: o.start, end: o.end, minLength: 0.3, id: range.id)
                               editor.updateCursorRange(id: range.id) { $0.start = r.start; $0.end = r.end }
                           },
                           onDragEnd: { editor.endInteraction() })
                    .help("Cursor-Hervorhebung nur hier: ziehen verschiebt, Kanten ändern die Länge")
                    .offset(x: v.x, y: layout.cursorY)
            }
        }
    }

    @ViewBuilder
    private var maskLane: some View {
        laneBackground(height: layout.maskH, opacity: 0.06,
                       hint: editor.settings.masks.isEmpty ? "Klicken fügt eine Maske ein (verpixelt z. B. Passwörter)" : nil,
                       y: layout.maskY, adds: .mask) { editor.selection = nil }
        ForEach(editor.settings.masks) { mask in
            if let v = vis(mask.start, mask.end) {
                RangeBlock(visible: v, pps: scale.pps, height: layout.maskH,
                           color: .orange, icon: mask.style == .pixelate ? "square.grid.3x3.fill" : "drop.fill",
                           markers: (mask.track?.count ?? 0) <= 40 ? (mask.track ?? []).map { T($0.t) } : [],
                           selected: editor.selectedMaskID == mask.id || editor.isInGroup(.mask(mask.id)),
                           onSelect: { editor.click(.mask(mask.id)) },
                           onDrag: { kind, dt in
                               if editor.dragGroup(kind, dt: dt, item: .mask(mask.id)) { return }
                               if editor.maskDragOrigin?.id != mask.id {
                                   editor.maskDragOrigin = mask; editor.selectedMaskID = mask.id; editor.beginInteraction()
                               }
                               guard let o = editor.maskDragOrigin else { return }
                               let r = dragged(kind, dt, start: o.start, end: o.end, minLength: 0.1, id: mask.id)
                               editor.updateMask(id: mask.id) { m in
                                   // Moved as a whole, its keyframes come along.
                                   if kind == .move { m.track = o.shifted(by: r.start - o.start).track }
                                   m.start = r.start; m.end = r.end
                               }
                           },
                           onDragEnd: { editor.endInteraction() })
                    .offset(x: v.x, y: layout.maskY)
            }
        }
    }

    @ViewBuilder
    private var cameraLane: some View {
        laneBackground(height: layout.cameraH, opacity: 0.06,
                       hint: editor.settings.cameraLayouts.isEmpty ? "Klicken: Kamera hier groß, bildschirmfüllend oder aus" : nil,
                       y: layout.cameraY, adds: .camera) { editor.selection = nil }
        ForEach(editor.settings.cameraLayouts) { range in
            if let v = vis(range.start, range.end) {
                RangeBlock(visible: v, pps: scale.pps, height: layout.cameraH, color: .cyan, icon: range.layout.icon,
                           label: range.layout.label,
                           selected: editor.selection == .cameraLayout(range.id) || editor.isInGroup(.cameraLayout(range.id)),
                           onSelect: { editor.click(.cameraLayout(range.id)) },
                           onDrag: { kind, dt in
                               if editor.dragGroup(kind, dt: dt, item: .cameraLayout(range.id)) { return }
                               if editor.cameraLayoutDragOrigin?.id != range.id {
                                   editor.cameraLayoutDragOrigin = range; editor.selection = .cameraLayout(range.id); editor.beginInteraction()
                               }
                               guard let o = editor.cameraLayoutDragOrigin else { return }
                               let r = dragged(kind, dt, start: o.start, end: o.end, minLength: 0.3, id: range.id)
                               editor.updateCameraLayout(id: range.id) { $0.start = r.start; $0.end = r.end }
                           },
                           onDragEnd: { editor.endInteraction() })
                    .offset(x: v.x, y: layout.cameraY)
            }
        }
    }

    @ViewBuilder
    private var annotationLane: some View {
        laneBackground(height: layout.annotationH, opacity: 0.06,
                       hint: editor.settings.annotations.isEmpty ? "Klicken: Rahmen – Pfeil (A) und Spotlight (P) über die Symbolleiste" : nil,
                       y: layout.annotationY, adds: .annotation) { editor.selection = nil }
        ForEach(editor.settings.annotations) { a in
            if let v = vis(a.start, a.end) {
                let (r, g, b) = a.color.rgb
                RangeBlock(visible: v, pps: scale.pps, height: layout.annotationH,
                           color: a.kind == .spotlight ? .gray : Color(red: r, green: g, blue: b), icon: a.kind.icon,
                           label: a.kind == .touch ? a.touchGesture.label : a.kind == .step ? "Schritt \(editor.stepNumber(a))" : a.kind.label,
                           selected: editor.selection == .annotation(a.id) || editor.isInGroup(.annotation(a.id)),
                           onSelect: { editor.click(.annotation(a.id)) },
                           onDrag: { kind, dt in
                               if editor.dragGroup(kind, dt: dt, item: .annotation(a.id)) { return }
                               if editor.annotationDragOrigin?.id != a.id {
                                   editor.annotationDragOrigin = a; editor.selection = .annotation(a.id); editor.beginInteraction()
                               }
                               guard let o = editor.annotationDragOrigin else { return }
                               let r = dragged(kind, dt, start: o.start, end: o.end, minLength: 0.2, id: a.id)
                               editor.updateAnnotation(id: a.id) { $0.start = r.start; $0.end = r.end }
                           },
                           onDragEnd: { editor.endInteraction() })
                    .offset(x: v.x, y: layout.annotationY)
            }
        }
    }

    /// Chapter flags in the ruler: click selects, drag moves.
    @ViewBuilder
    private var chapterMarkers: some View {
        ForEach(editor.settings.chapters) { chapter in
            let x = scale.x(T(chapter.time))
            if x >= -60, x <= scale.width + 4 {
                let selected = editor.selection == .chapter(chapter.id)
                HStack(spacing: 2) {
                    Image(systemName: "bookmark.fill").font(.system(size: 9))
                    if scale.width > 0 {
                        Text(chapter.title).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                    }
                }
                .foregroundStyle(.black.opacity(0.8))
                .padding(.horizontal, 4)
                .frame(height: 13)
                .background(Capsule().fill(selected ? Color.yellow : Color.yellow.opacity(0.75)))
                .overlay(Capsule().strokeBorder(selected ? Color.white : .clear, lineWidth: 1.5))
                .shadow(color: selected ? TimelineSelection.color.opacity(0.9) : .clear, radius: selected ? 4 : 0)
                .fixedSize()
                .contentShape(Rectangle())
                .onTapGesture {
                    editor.selection = .chapter(chapter.id)
                    editor.seek(to: chapter.time)
                }
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("timeline"))
                    .onChanged { v in
                        if editor.chapterDragOrigin?.id != chapter.id {
                            editor.chapterDragOrigin = chapter; editor.selection = .chapter(chapter.id); editor.beginInteraction()
                        }
                        guard let o = editor.chapterDragOrigin else { return }
                        let dt = snapped(.start, Double(v.translation.width / scale.pps), T(o.time), T(o.time), chapter.id)
                        editor.updateChapter(id: chapter.id) { $0.time = S(T(o.time) + dt) }
                    }
                    .onEnded { _ in editor.endInteraction() })
                .help("Kapitel „\(chapter.title)“ – ziehen verschiebt, anklicken zum Umbenennen")
                .offset(x: x - 3, y: 1)
            }
        }
    }

    @ViewBuilder
    private var textLane: some View {
        let texts = editor.settings.texts.filter { $0.kind == .lowerThird || $0.placement == .overlay }
        laneBackground(height: layout.textH, opacity: 0.06,
                       hint: texts.isEmpty ? "Klicken fügt eine Bauchbinde ein" : nil,
                       y: layout.textY, adds: .text) { editor.selection = nil }
        ForEach(texts) { text in
            if let run = editor.displayRange(start: text.start, end: text.end, free: text.isFree), let v = scale.visible(run.lowerBound, run.upperBound) {
                RangeBlock(visible: v, pps: scale.pps, height: layout.textH,
                           color: text.kind == .lowerThird ? .teal : .indigo,
                           icon: text.kind == .lowerThird ? "text.below.photo" : "rectangle.inset.filled",
                           label: text.title,
                           selected: editor.selectedTextID == text.id || editor.isInGroup(.text(text.id)),
                           onSelect: { editor.click(.text(text.id)) },
                           onDrag: { kind, dt in
                               if editor.dragGroup(kind, dt: dt, item: .text(text.id)) { return }
                               if editor.textDragOrigin?.id != text.id {
                                   editor.textDragOrigin = text; editor.selectedTextID = text.id; editor.beginInteraction()
                               }
                               guard let o = editor.textDragOrigin else { return }
                               let r = o.isFree ? draggedFree(kind, dt, start: o.start, end: o.end, minLength: 0.2, id: text.id)
                                   : dragged(kind, dt, start: o.start, end: o.end, minLength: 0.2, id: text.id)
                               editor.updateText(id: text.id) { t in t.start = r.start; t.end = r.end }
                           },
                           onDragEnd: { editor.endInteraction() })
                    .offset(x: v.x, y: layout.textY)
            }
        }
    }

    @ViewBuilder
    private var mediaLane: some View {
        laneBackground(height: layout.mediaH, opacity: 0.06,
                       hint: editor.settings.images.isEmpty && editor.settings.videoOverlays.isEmpty
                           ? "Bilder und Videos hierher ziehen – oder klicken" : nil,
                       y: layout.mediaRowY(0), adds: .media) { editor.selection = nil }
        ForEach(1..<max(1, layout.mediaRows), id: \.self) { row in
            laneBackground(height: layout.mediaH, opacity: 0.06, hint: nil, y: layout.mediaRowY(row)) { editor.selection = nil }
        }
        let mediaFades = FrameRenderer.mediaDissolves(editor.settings, map: editor.timeMap)
        ForEach(editor.settings.videoOverlays) { o in
            let shown = editor.displayRange(o)
            if let v = scale.visible(shown.lowerBound, shown.upperBound) {
                RangeBlock(visible: v, pps: scale.pps, height: layout.mediaH, color: o.synced ? .orange : .yellow,
                           icon: o.synced ? "macwindow.on.rectangle" : "pip", label: o.name,
                           fadeIn: mediaFades[o.id].flatMap { $0.fadeIn > 0 ? shown.lowerBound...(shown.lowerBound + $0.fadeIn) : nil },
                           fadeOut: mediaFades[o.id].flatMap { $0.fadeOut > 0 ? (shown.upperBound - $0.fadeOut)...shown.upperBound : nil },
                           markers: (o.keys ?? []).map { shown.lowerBound + $0.t },
                           onVerticalDrag: o.synced ? nil : { dy in
                               if let origin = editor.videoOverlayDragOrigin { editor.setLane(.video(o.id), (origin.lane ?? 0) - Int((dy / layout.mediaPitch).rounded())) }
                           },
                           selected: editor.selection == .videoOverlay(o.id) || editor.isInGroup(.videoOverlay(o.id)),
                           onSelect: { editor.click(.videoOverlay(o.id)) },
                           onDrag: { kind, dt in
                               if editor.dragGroup(kind, dt: dt, item: .videoOverlay(o.id)) { return }
                               if editor.videoOverlayDragOrigin?.id != o.id {
                                   editor.videoOverlayDragOrigin = o; editor.selection = .videoOverlay(o.id); editor.beginInteraction()
                               }
                               guard let origin = editor.videoOverlayDragOrigin else { return }
                               let start = origin.isFree ? origin.start : T(origin.start)
                               let dt = snapped(kind, dt, start, start + origin.duration, o.id)
                               func place(_ t: Double) -> Double { origin.isFree ? t : S(t) }
                               editor.updateVideoOverlay(id: o.id) { c in
                                   switch kind {
                                   case .move:
                                       c.start = place(max(0, min(start + dt, editor.timeMap.total - origin.duration)))
                                   case .start:
                                       // Trim the beginning: later in the file (the synced one stays in sync anyway).
                                       let delta = max(origin.synced ? -start : -min(start, origin.fileOffset), min(dt, origin.duration - 0.2))
                                       c.start = place(start + delta)
                                       if !origin.synced { c.fileOffset = origin.fileOffset + delta }
                                       c.duration = origin.duration - delta
                                   case .end:
                                       c.duration = max(0.2, origin.duration + dt)
                                   }
                               }
                           },
                           onDragEnd: { editor.endInteraction() })
                    .help("Video über der Aufnahme: ziehen verschiebt, auch auf eine andere Spur, Kanten kürzen, S teilt am Abspielkopf")
                    .offset(x: v.x, y: layout.mediaRowY(o.lane ?? 0))
            }
        }
        ForEach(editor.settings.images) { o in
            if let run = editor.displayRange(start: o.start, end: o.end, free: o.isFree), let v = scale.visible(run.lowerBound, run.upperBound) {
                RangeBlock(visible: v, pps: scale.pps, height: layout.mediaH, color: .mint, icon: "photo",
                           label: URL(fileURLWithPath: o.file).deletingPathExtension().lastPathComponent,
                           fadeIn: mediaFades[o.id].flatMap { $0.fadeIn > 0 ? run.lowerBound...(run.lowerBound + $0.fadeIn) : nil },
                           fadeOut: mediaFades[o.id].flatMap { $0.fadeOut > 0 ? (run.upperBound - $0.fadeOut)...run.upperBound : nil },
                           markers: (o.keys ?? []).map { run.lowerBound + $0.t },
                           onVerticalDrag: { dy in
                               if let origin = editor.imageDragOrigin { editor.setLane(.image(o.id), (origin.lane ?? 0) - Int((dy / layout.mediaPitch).rounded())) }
                           },
                           selected: editor.selection == .image(o.id) || editor.isInGroup(.image(o.id)),
                           onSelect: { editor.click(.image(o.id)) },
                           onDrag: { kind, dt in
                               if editor.dragGroup(kind, dt: dt, item: .image(o.id)) { return }
                               if editor.imageDragOrigin?.id != o.id {
                                   editor.imageDragOrigin = o; editor.selection = .image(o.id); editor.beginInteraction()
                               }
                               guard let origin = editor.imageDragOrigin else { return }
                               let r = origin.isFree ? draggedFree(kind, dt, start: origin.start, end: origin.end, minLength: 0.2, id: o.id)
                                   : dragged(kind, dt, start: origin.start, end: origin.end, minLength: 0.2, id: o.id)
                               editor.updateImage(id: o.id) { $0.start = r.start; $0.end = r.end }
                           },
                           onDragEnd: { editor.endInteraction() })
                    .offset(x: v.x, y: layout.mediaRowY(o.lane ?? 0))
            }
        }
    }

    // MARK: Audio lanes

    @ViewBuilder
    private func audioLane(_ lane: AudioLane, y: CGFloat) -> some View {
        let h = layout.audioH
        let color = Self.color(lane)
        let laneMuted = editor.isMuted(lane)
        if let v = laneVisible {
            let map = editor.timeMap
            ZStack(alignment: .leading) {
                BlockShape(visible: v, radius: Theme.laneRadius).fill(color.opacity(0.08))
                if lane == .music, let music = editor.settings.music, music.clipped != true, let peaks = editor.waveforms["music:" + music.file] {
                    let length = Double(peaks.count) / Waveform.rate
                    let introLead = editor.introLead
                    WaveformCanvas(peaks: peaks, loudest: editor.waveformPeaks["music:" + music.file] ?? 0,
                                   timeStart: v.lo, seconds: v.hi - v.lo,
                                   fileTime: { t in
                                       // Music runs in output time: nothing under removed parts.
                                       let f = music.fileOffset + t + introLead
                                       return music.loop && length > 0 ? f.truncatingRemainder(dividingBy: length) : (f < length ? f : nil)
                                   },
                                   color: laneMuted ? Color.secondary.opacity(0.35) : color.opacity(0.8))
                        .padding(.vertical, 3)
                } else if lane != .voiceOver, lane != .music, let peaks = editor.waveforms[lane.role] {
                    // Recording time under each point; freeze frames are silent.
                    WaveformCanvas(peaks: peaks, loudest: editor.waveformPeaks[lane.role] ?? 0,
                                   timeStart: v.lo, seconds: v.hi - v.lo,
                                   fileTime: { t in map.isFrozen(atTimeline: t) ? nil : map.source(t) },
                                   color: laneMuted ? Color.secondary.opacity(0.35) : color.opacity(0.8))
                        .padding(.vertical, 3)
                } else if lane == .voiceOver && editor.settings.voiceOvers.isEmpty && !v.clippedLeft {
                    Text(editor.voiceOverState == .idle ? "„Einsprechen“ nimmt ab dem Abspielkopf Sprache auf" : "")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.leading, 10)
                }
            }
            .frame(width: v.width, height: h)
            .contentShape(Rectangle())
            .onTapGesture { editor.selection = nil }
            .contextMenu {
                if lane != .music { Button("Ab Abspielkopf stummschalten") { editor.addMute(lane: lane) } }
            }
            .offset(x: v.x, y: y)
        }

        if lane == .voiceOver || lane == .music {
            voiceOverClips(y: y, height: h, color: color, laneMuted: laneMuted, music: lane == .music)
        }

        ForEach(editor.settings.audioMutes.filter { $0.lane == lane }) { mute in
            if let v = vis(mute.start, mute.end) {
                RangeBlock(visible: v, pps: scale.pps, height: h,
                           color: mute.kind == .breath ? Color.cyan.opacity(0.55) : mute.isMute ? .black : Self.color(lane).opacity(0.55),
                           icon: mute.kind == .breath ? "wind" : mute.isMute ? "speaker.slash.fill" : mute.enhance != nil ? "wand.and.stars" : "speaker.wave.1.fill",
                           label: mute.kind == .breath ? "Atem" : mute.isMute ? nil
                               : mute.enhance.map { "Stimme \(Int($0 * 100)) %" } ?? "\(Int(mute.level * 100)) %",
                           selected: editor.selectedMuteID == mute.id || editor.isInGroup(.mute(mute.id)),
                           onSelect: { editor.click(.mute(mute.id)) },
                           onDrag: { kind, dt in
                               if editor.dragGroup(kind, dt: dt, item: .mute(mute.id)) { return }
                               if editor.muteDragOrigin?.id != mute.id {
                                   editor.muteDragOrigin = mute; editor.selectedMuteID = mute.id; editor.beginInteraction()
                               }
                               guard let o = editor.muteDragOrigin else { return }
                               let r = dragged(kind, dt, start: o.start, end: o.end, minLength: 0.05, id: mute.id)
                               editor.updateMute(id: mute.id) { m in m.start = r.start; m.end = r.end }
                           },
                           onDragEnd: { editor.endInteraction() })
                    .help("Bereich mit eigener Lautstärke: ziehen verschiebt, Kanten ändern, ⌫ löscht, S teilt am Abspielkopf")
                    .offset(x: v.x, y: y)
            }
        }
    }

    /// Voice-over clips. Clips pushed over each other are shown in rows (as they play on separate
    /// layers) with their crossfade curves; the waveform follows the fades.
    @ViewBuilder
    private func voiceOverClips(y: CGFloat, height h: CGFloat, color: Color, laneMuted: Bool, music: Bool) -> some View {
        // Start in timeline time; the clips play in real time from there.
        let clips = editor.displayVoiceOvers(music: music)
        let layers = VoiceOverClip.layers(clips)
        let fades = VoiceOverClip.crossfades(clips)
        let rowH = h / CGFloat(max(1, layers.count))
        ForEach(clips) { clip in
            if let v = scale.visible(clip.start, clip.end) {
                let layer = layers.layerOf[clip.id] ?? 0
                let fade = fades[clip.id] ?? (0, 0)
                let waveform = editor.waveforms[clip.file].map { peaks in
                    WaveformCanvas(peaks: peaks, loudest: editor.waveformPeaks[clip.file] ?? 0,
                                   timeStart: v.lo, seconds: v.hi - v.lo,
                                   fileTime: { t in clip.fileOffset + t - clip.start },
                                   color: .white.opacity(0.85),
                                   gain: fade == (0, 0) ? nil : { t in
                                       VoiceOverClip.crossfadeGain(at: t, clip: clip, fadeIn: fade.0, fadeOut: fade.1)
                                   })
                }
                RangeBlock(visible: v, pps: scale.pps, height: rowH - (layers.count > 1 ? 1 : 0),
                           color: color, icon: "waveform",
                           waveform: waveform,
                           fadeIn: fade.0 > 0 ? clip.start...(clip.start + fade.0) : nil,
                           fadeOut: fade.1 > 0 ? (clip.end - fade.1)...clip.end : nil,
                           selected: editor.selectedVoiceOverID == clip.id || editor.isInGroup(.voiceOver(clip.id)),
                           onSelect: { editor.click(.voiceOver(clip.id)) },
                           onDrag: { kind, dt in
                               if editor.dragGroup(kind, dt: dt, item: .voiceOver(clip.id)) { return }
                               if editor.voiceOverDragOrigin?.id != clip.id {
                                   editor.voiceOverDragOrigin = editor.settings.voiceOvers.first { $0.id == clip.id }
                                   editor.selectedVoiceOverID = clip.id
                                   editor.beginInteraction()
                               }
                               guard let o = editor.voiceOverDragOrigin else { return }
                               let start = o.isFree ? o.start : T(o.start)
                               let dt = snapped(kind, dt, start, start + o.duration, clip.id)
                               func place(_ t: Double) -> Double { o.isFree ? t : S(t) }
                               editor.updateVoiceOver(id: clip.id) { c in
                                   switch kind {
                                   case .move:
                                       c.start = place(start + dt)
                                   case .start:
                                       // Trim the beginning: the clip keeps its place in the file.
                                       let delta = max(-o.fileOffset, min(dt, o.duration - 0.1))
                                       c.start = place(start + delta)
                                       c.fileOffset = o.fileOffset + delta
                                       c.duration = o.duration - delta
                                   case .end:
                                       c.duration = max(0.1, o.duration + dt)
                                   }
                               }
                           },
                           onDragEnd: { editor.endInteraction() })
                    .opacity(laneMuted ? 0.45 : 1)
                    .help("Voice-over: ziehen zum Verschieben, Kanten zum Kürzen. Über einen anderen Clip geschoben entsteht eine Überblendung.")
                    .offset(x: v.x, y: y + CGFloat(layer) * rowH)
            }
        }
    }

    static func color(_ lane: AudioLane) -> Color {
        switch lane {
        case .mic: return .green
        case .system: return .blue
        case .voiceOver: return .pink
        case .music: return .mint
        }
    }
}

// MARK: - Drawing helpers

/// Selected items in the timeline: a bold yellow outline with a glow (like Final Cut Pro), so the
/// selection is obvious on every lane color.
enum TimelineSelection {
    static let color = Color(red: 1, green: 0.8, blue: 0.08)
    static let lineWidth: CGFloat = 2.5
}

extension View {
    /// Yellow outline and glow when `selected`; a thin dark edge otherwise (separates blocks).
    func timelineSelection<S: InsettableShape>(_ selected: Bool, shape: S) -> some View {
        self
            .overlay(shape.strokeBorder(selected ? TimelineSelection.color : Color.black.opacity(0.22),
                                        lineWidth: selected ? TimelineSelection.lineWidth : 0.5))
            .shadow(color: selected ? TimelineSelection.color.opacity(0.75) : .clear, radius: selected ? 5 : 0)
            .zIndex(selected ? 1 : 0)
    }
}

/// Rounded rectangle whose corners stay square where the item continues off screen.
struct BlockShape: InsettableShape {
    let visible: TimelineScale.Visible
    var radius: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let left = visible.clippedLeft ? 0 : min(radius, r.width / 2)
        let right = visible.clippedRight ? 0 : min(radius, r.width / 2)
        return UnevenRoundedRectangle(topLeadingRadius: left, bottomLeadingRadius: left,
                                      bottomTrailingRadius: right, topTrailingRadius: right).path(in: r)
    }

    func inset(by amount: CGFloat) -> BlockShape {
        var s = self
        s.inset += amount
        return s
    }
}

/// Mirrored waveform from peak buckets (100 per second), drawn for the visible part only. Levels
/// are scaled to the loudest peak of the track (quiet narration fills the clip) on a square-root
/// scale; the floor of the reference keeps pure background noise low.
struct WaveformCanvas: View {
    let peaks: [Float]
    /// Loudest peak of the whole track.
    let loudest: Float
    /// Timeline time at the left edge and the seconds covered by the width.
    let timeStart: Double
    let seconds: Double
    /// File time at a timeline time (nil: silent there, e.g. a freeze frame).
    let fileTime: (Double) -> Double?
    let color: Color
    /// Volume factor at a timeline time (crossfades).
    var gain: ((Double) -> Double)? = nil

    /// 0…1 height for a peak; silence (< −54 dBFS) is flat.
    static func level(_ peak: Float, loudest: Float) -> Double {
        guard peak > 0.002 else { return 0 }
        return sqrt(min(1, Double(peak) / Double(max(loudest, 0.15))))
    }

    var body: some View {
        Canvas { ctx, size in
            guard seconds > 0, size.width > 1 else { return }
            let columns = max(1, Int(size.width / 2))
            let mid = size.height / 2
            var path = Path()
            for c in 0..<columns {
                let t0 = timeStart + Double(c) / Double(columns) * seconds
                let t1 = timeStart + Double(c + 1) / Double(columns) * seconds
                guard let f0 = fileTime(t0), let f1 = fileTime(t1) else { continue }
                let a = Int(min(f0, f1) * Waveform.rate)
                let b = max(a + 1, Int(max(f0, f1) * Waveform.rate))
                var peak: Float = 0
                let lo = max(0, a), hi = min(peaks.count, b)
                if lo < hi {
                    for i in lo..<hi where peaks[i] > peak { peak = peaks[i] }
                }
                var level = Self.level(peak, loudest: loudest)
                if let gain { level *= gain((t0 + t1) / 2) }
                let half = max(0.5, CGFloat(level) * (mid - 1))
                path.addRect(CGRect(x: CGFloat(c) * size.width / CGFloat(columns), y: mid - half, width: 1.5, height: 2 * half))
            }
            ctx.fill(path, with: .color(color))
        }
    }
}

/// A fade drawn on a clip: the curve of its volume/opacity, the faded part above it shaded.
struct FadeCurve: View {
    enum Kind {
        /// Equal-power audio crossfade (voice-over clips).
        case audioIn, audioOut
        /// Eased video cross dissolve.
        case videoIn, videoOut

        func value(_ p: Double) -> Double {
            let x = min(1, max(0, p))
            switch self {
            case .audioIn: return sin(x * .pi / 2)
            case .audioOut: return cos(x * .pi / 2)
            case .videoIn: return RenderInstruction.smooth(x)
            case .videoOut: return 1 - RenderInstruction.smooth(x)
            }
        }
    }

    let kind: Kind
    /// Visible part of the view and the whole fade (may continue off screen).
    let visible: TimelineScale.Visible
    let range: ClosedRange<Double>
    let pps: CGFloat
    var color: Color = .white
    var shade = true

    var body: some View {
        Canvas { ctx, size in
            let length = range.upperBound - range.lowerBound
            guard length > 0, size.width > 0 else { return }
            let steps = max(8, Int(size.width / 3))
            var curve = Path()
            for i in 0...steps {
                let x = size.width * CGFloat(i) / CGFloat(steps)
                let t = visible.lo + Double(x / pps)
                let y = (size.height - 3) * (1 - CGFloat(kind.value((t - range.lowerBound) / length))) + 1.5
                if i == 0 { curve.move(to: CGPoint(x: x, y: y)) } else { curve.addLine(to: CGPoint(x: x, y: y)) }
            }
            if shade {
                var area = curve
                area.addLine(to: CGPoint(x: size.width, y: 0))
                area.addLine(to: .zero)
                area.closeSubpath()
                ctx.fill(area, with: .color(.black.opacity(0.28)))
            }
            ctx.stroke(curve, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Recorded clicks as dots along the bottom of the clip.
private struct ClickDots: View {
    let clicks: [ClickEvent]
    let scale: TimelineScale
    let map: TimeMap
    /// x of the clip's left edge in the lane.
    let left: CGFloat

    var body: some View {
        Canvas { ctx, size in
            var dots = Path()
            for click in clicks {
                guard map.contains(source: click.t) else { continue }
                let t = map.timeline(click.t)
                guard t >= scale.start, t <= scale.end else { continue }
                let x = scale.x(t) - left
                dots.addEllipse(in: CGRect(x: x - 2.5, y: size.height - 5, width: 5, height: 5))
            }
            ctx.fill(dots, with: .color(Theme.color(.video)))
        }
        .allowsHitTesting(false)
    }
}

/// Time ruler: the tick spacing adapts to the zoom.
private struct RulerCanvas: View {
    let scale: TimelineScale
    let duration: Double

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.06)))
            let pps = Double(scale.pps)
            let candidates: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200]
            let step = candidates.first { $0 * pps >= 64 } ?? 1800
            let minor = step / (step == 15 || step == 30 ? 3 : 5)
            // Minor ticks
            var t = max(0, (scale.start / minor).rounded(.down) * minor)
            var minorPath = Path()
            while t <= min(duration, scale.end) + 1e-9 {
                let x = scale.x(t)
                minorPath.addRect(CGRect(x: x, y: size.height - 3, width: 1, height: 3))
                t += minor
            }
            ctx.fill(minorPath, with: .color(.secondary.opacity(0.3)))
            // Major ticks with labels
            t = max(0, (scale.start / step).rounded(.down) * step)
            var majorPath = Path()
            while t <= min(duration, scale.end) + 1e-9 {
                let x = scale.x(t)
                majorPath.addRect(CGRect(x: x, y: size.height - 7, width: 1, height: 7))
                let label = Text(Self.label(t, step: step)).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                ctx.draw(label, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                t += step
            }
            ctx.fill(majorPath, with: .color(.secondary.opacity(0.6)))
        }
    }

    static func label(_ t: Double, step: Double) -> String {
        let m = Int(t + 1e-6) / 60, s = Int(t + 1e-6) % 60
        if step < 1 {
            let tenths = Int(((t - floor(t + 1e-6)) * 10).rounded()) % 10
            return String(format: "%d:%02d.%d", m, s, tenths)
        }
        return String(format: "%d:%02d", m, s)
    }
}

private struct TrimHandle: View {
    let isStart: Bool
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .frame(width: 10, height: height)
            .overlay(
                Image(systemName: isStart ? "chevron.compact.right" : "chevron.compact.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black.opacity(0.7))
            )
            .shadow(radius: 1)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .help(isStart ? "Anfang trimmen" : "Ende trimmen")
    }
}

/// Red playhead: a head in the ruler and a line through all lanes. Both can be dragged.
private struct PlayheadView: View {
    static let width: CGFloat = 14
    let rulerHeight: CGFloat
    let height: CGFloat

    /// The head and a narrow strip around the line.
    struct HitShape: Shape {
        let rulerHeight: CGFloat
        func path(in rect: CGRect) -> Path {
            var p = Path(CGRect(x: 0, y: 0, width: rect.width, height: rulerHeight))
            p.addRect(CGRect(x: rect.midX - 3.5, y: rulerHeight, width: 7, height: max(0, rect.height - rulerHeight)))
            return p
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: height)
            PlayheadHead()
                .fill(Color.red)
                .frame(width: Self.width, height: rulerHeight - 4)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        }
        .frame(width: Self.width, height: height, alignment: .top)
    }
}

/// Pentagon pointing down (the classic playhead head).
private struct PlayheadHead: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY * 0.6))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY * 0.6))
        p.closeSubpath()
        return p
    }
}

/// Handle for the length of a cross dissolve at a cut.
private struct DissolveKnob: View {
    static let size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color.red.opacity(0.85), lineWidth: 2))
            .frame(width: Self.size, height: Self.size)
            .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            .contentShape(Circle())
            .pointerStyle(.columnResize)
    }
}

/// Generic draggable time-range block (move by dragging, resize at the edges).
struct RangeBlock: View {
    enum DragKind { case move, start, end }
    let visible: TimelineScale.Visible
    let pps: CGFloat
    let height: CGFloat
    let color: Color
    let icon: String
    var label: String? = nil
    /// Label centered (zoom blocks) instead of left-aligned.
    var centered = false
    var waveform: WaveformCanvas? = nil
    /// Crossfades at the start/end of the clip (timeline time).
    var fadeIn: ClosedRange<Double>? = nil
    var fadeOut: ClosedRange<Double>? = nil
    /// Keyframes (timeline time).
    var markers: [Double] = []
    /// Dragged up or down (points since the drag began).
    var onVerticalDrag: ((CGFloat) -> Void)? = nil
    let selected: Bool
    let onSelect: () -> Void
    let onDrag: (DragKind, Double) -> Void
    let onDragEnd: () -> Void

    /// New range after dragging by `dt` seconds (kept inside 0…duration).
    static func apply(_ kind: DragKind, dt: Double, start: Double, end: Double, duration: Double,
                      minLength: Double) -> (start: Double, end: Double) {
        switch kind {
        case .move:
            let len = end - start
            let s = min(max(0, start + dt), max(0, duration - len))
            return (s, s + len)
        case .start:
            return (max(0, min(start + dt, end - minLength)), end)
        case .end:
            return (start, min(duration, max(end + dt, start + minLength)))
        }
    }

    var body: some View {
        let width = max(10, visible.width)
        let shape = BlockShape(visible: visible, radius: 6)
        shape
            .fill(color.opacity(selected ? 0.9 : 0.6))
            .overlay {
                if let waveform {
                    waveform.padding(.vertical, 3)
                }
            }
            .overlay(alignment: .leading) { fade(fadeIn, kind: .audioIn) }
            .overlay(alignment: .leading) { fade(fadeOut, kind: .audioOut) }
            .clipShape(shape)
            .timelineSelection(selected, shape: shape)
            .overlay(alignment: centered || (waveform == nil && label == nil) ? .center : .leading) {
                if waveform == nil {
                    if let label, width > 60 {
                        Label(label, systemImage: icon)
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                    } else if width > 28 {
                        Image(systemName: icon).font(.caption2.bold()).foregroundStyle(.white)
                    }
                }
            }
            .overlay(alignment: .leading) { if !visible.clippedLeft { edge(.start) } }
            .overlay(alignment: .trailing) { if !visible.clippedRight { edge(.end) } }
            .overlay(alignment: .leading) {
                ForEach(markers, id: \.self) { t in
                    if t >= visible.lo, t <= visible.hi {
                        Rectangle().fill(Theme.focus).frame(width: 6, height: 6).rotationEffect(.degrees(45))
                            .offset(x: CGFloat(t - visible.lo) * pps - 3)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("timeline"))
                .onChanged {
                    onDrag(.move, Double($0.translation.width / pps))
                    onVerticalDrag?($0.translation.height)
                }
                .onEnded { _ in onDragEnd() })
    }

    @ViewBuilder
    private func fade(_ range: ClosedRange<Double>?, kind: FadeCurve.Kind) -> some View {
        if let range, let part = TimelineScale(start: visible.lo, span: visible.hi - visible.lo, width: visible.width)
            .visible(range.lowerBound, range.upperBound) {
            FadeCurve(kind: kind, visible: part, range: range, pps: pps)
                .frame(width: part.width)
                .offset(x: part.x)
                .allowsHitTesting(false)
        }
    }

    private func edge(_ kind: DragKind) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 8)
            .overlay {
                // Grips on the edges of the selected block (drag to trim).
                if selected && visible.width > 24 {
                    Capsule()
                        .fill(TimelineSelection.color)
                        .frame(width: 3, height: max(8, height * 0.55))
                        .offset(x: kind == .start ? 1 : -1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                .onChanged { onDrag(kind, Double($0.translation.width / pps)) }
                .onEnded { _ in onDragEnd() })
    }
}

/// Mark where two parts of the video meet: a click opens the transition between them.
private struct JoinMark: View {
    static let width: CGFloat = 14
    @ObservedObject var editor: EditorModel
    let key: Double
    let height: CGFloat

    var body: some View {
        let selected = editor.selection == .join(key)
        let active = editor.joinTransition(key: key) != nil
        ZStack(alignment: .bottom) {
            Color.clear
            RoundedRectangle(cornerRadius: 1.5)
                .fill(selected ? TimelineSelection.color : active ? Theme.brand : Color.white)
                .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(active || selected ? Color.clear : Color.secondary.opacity(0.7), lineWidth: 1))
                .frame(width: 8, height: 8)
                .rotationEffect(.degrees(45))
                .padding(.bottom, 5)
        }
        .frame(width: Self.width, height: height)
        // Only the mark itself: above it the edges of the two parts can be grabbed.
        .contentShape(Rectangle().size(width: Self.width, height: 18).offset(y: height - 18))
        .onTapGesture { editor.selection = .join(key) }
        .contextMenu {
            let parts = editor.clipParts
            if let i = parts.firstIndex(where: { abs($0.key - key) < 1e-4 }), i > 0, let t = editor.splitPoint(after: parts[i - 1], before: parts[i]) {
                Button("Teilung aufheben – wieder ein Clip") { editor.join([.parts(at: t)]) }
            }
            Section("Übergang") {
                ForEach([0.0, 0.5, 1.0, 2.0], id: \.self) { length in
                    Button(length == 0 ? "Harter Schnitt" : String(format: "%.1f s", length)) {
                        editor.commitUndoStep()
                        editor.setJoinTransition(key: key, length: length)
                        editor.commitUndoStep()
                    }
                }
            }
        }
        .help(active ? "Übergang zwischen den Teilen – anklicken zum Einstellen, ⇧S oder Rechtsklick verbindet geteilte Teile wieder"
                     : "Hier treffen sich zwei Teile – anklicken, um einen Übergang einzustellen; ⇧S oder Rechtsklick verbindet geteilte Teile wieder")
    }
}

/// Mark where something was cut out and the timeline closed up. Automatic cuts (filler words,
/// pauses, transcript) are orange and labelled.
private struct CutSeam: View {
    static let width: CGFloat = 16
    @ObservedObject var editor: EditorModel
    let cut: CutRange
    let height: CGFloat

    var body: some View {
        let selected = editor.selectedCutID == cut.id
        let tint: Color = cut.origin == nil ? .red : .orange
        ZStack(alignment: .top) {
            Rectangle()
                .fill(selected ? TimelineSelection.color : tint.opacity(0.8))
                .frame(width: selected ? 3 : 2, height: height)
            Group {
                if let origin = cut.origin {
                    Text(origin.short).font(.system(size: 8.5, weight: .bold))
                } else {
                    Image(systemName: "scissors").font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, 3)
            .frame(minWidth: 14, minHeight: 13)
            .background(RoundedRectangle(cornerRadius: 3).fill(selected ? TimelineSelection.color : tint))
            .offset(y: 1)
        }
        .frame(width: Self.width, height: height)
        // Only the tab at the top: below it the edges of the two parts can be grabbed.
        .contentShape(Rectangle().size(width: Self.width, height: 16))
        .onTapGesture { editor.selectedCutID = cut.id }
        .contextMenu {
            Button("Entferntes wiederherstellen") {
                editor.selectedCutID = cut.id
                editor.deleteSelection()
            }
            if editor.canDissolve(cut) {
                Section("Überblendung") {
                    ForEach([0.0, 0.5, 1.0, 2.0], id: \.self) { length in
                        Button(length == 0 ? "Harter Schnitt" : String(format: "%.1f s", length)) {
                            editor.setDissolve(cutID: cut.id, length)
                        }
                    }
                }
            }
        }
        .help(String(format: "%@ %.1f s entfernt. Anklicken: Überblendung einstellen, ⌫ holt es zurück.",
                     cut.origin?.label ?? "Hier wurden", cut.end - cut.start))
    }
}

// MARK: - Zoom controls and overview

private struct ZoomControls: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        HStack(spacing: 3) {
            Button {
                editor.zoom(by: 0.5)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Herauszoomen (⌘−)")
            Slider(value: Binding(get: { editor.zoomLevel }, set: { editor.zoomLevel = $0 }), in: 0...1)
                .controlSize(.mini)
                .help("Zoom der Timeline – auch mit ⌥/⌘ + Scrollrad oder zwei Fingern auf dem Trackpad")
            Button {
                editor.zoom(by: 2)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Hineinzoomen (⌘+)")
            Button {
                editor.zoomToFit()
            } label: {
                Image(systemName: "arrow.left.and.right.square")
            }
            .help("Ganze Timeline zeigen (⇧Z)")
            .disabled(!editor.isZoomed)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
        .padding(.trailing, 12)
    }
}

/// The whole timeline in miniature with the visible part; drag it to scroll.
private struct OverviewBar: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var drag = DragStart()

    final class DragStart: ObservableObject { var scroll: Double? }

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let total = editor.totalSpan
            let t0 = editor.displayStart
            let thumbW = max(16, CGFloat(editor.visibleSpan / total) * w)
            let thumbX = min(w - thumbW, CGFloat((editor.visibleStart - t0) / total) * w)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12)).frame(height: 8)
                Capsule()
                    .fill(Color.secondary.opacity(editor.isZoomed ? 0.45 : 0.2))
                    .frame(width: thumbW, height: 8)
                    .offset(x: thumbX)
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 1.5, height: 12)
                    .offset(x: CGFloat((editor.display(editor.currentTime) - t0) / total) * w)
            }
            .frame(width: w, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard editor.isZoomed else { return }
                    if drag.scroll == nil {
                        let onThumb = v.startLocation.x >= thumbX && v.startLocation.x <= thumbX + thumbW
                        drag.scroll = onThumb ? editor.visibleStart
                            : t0 + Double(v.startLocation.x / w) * total - editor.visibleSpan / 2
                    }
                    editor.scroll(to: (drag.scroll ?? 0) + Double(v.translation.width / w) * total)
                }
                .onEnded { _ in drag.scroll = nil })
        }
        .help("Sichtbarer Ausschnitt der Timeline – ziehen zum Verschieben (oder seitlich wischen)")
    }
}

/// Scroll wheel, trackpad swipes and pinch over the timeline: ⌥/⌘ + scroll or pinch zooms around
/// the mouse, horizontal scrolling moves the visible part. Vertical scrolling stays with the lanes.
private struct TimelineScrollCatcher: NSViewRepresentable {
    let editor: EditorModel
    /// x where the lanes begin (right of the lane headers).
    let laneLeft: CGFloat

    func makeNSView(context: Context) -> TimelineScrollCatcherView {
        let view = TimelineScrollCatcherView()
        view.editor = editor
        view.laneLeft = laneLeft
        return view
    }

    func updateNSView(_ view: TimelineScrollCatcherView, context: Context) {
        view.editor = editor
        view.laneLeft = laneLeft
    }
}

final class TimelineScrollCatcherView: NSView {
    weak var editor: EditorModel?
    var laneLeft: CGFloat = 0
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// What a scroll wheel / trackpad event asks for.
    enum Input {
        /// Scroll deltas in points; `zoom`: ⌥, ⌘ or ⌃ held.
        case scroll(dx: Double, dy: Double, zoom: Bool)
        case magnify(Double)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        let input: Input
        switch event.type {
        case .magnify:
            input = .magnify(Double(event.magnification))
        case .scrollWheel:
            let precise = event.hasPreciseScrollingDeltas
            input = .scroll(dx: Double(event.scrollingDeltaX) * (precise ? 1 : 8),
                            dy: Double(event.scrollingDeltaY) * (precise ? 1 : 8),
                            zoom: !event.modifierFlags.intersection([.command, .option, .control]).isEmpty)
        default:
            return event
        }
        return apply(input, at: convert(event.locationInWindow, from: nil)) ? nil : event
    }

    /// Zooms or scrolls the timeline; false if the input is not for the timeline (e.g. vertical
    /// scrolling of the lanes). `p` is in this view's coordinates.
    func apply(_ input: Input, at p: NSPoint) -> Bool {
        guard let editor else { return false }
        let laneWidth = bounds.width - laneLeft
        guard bounds.contains(p), laneWidth > 20 else { return false }
        let anchor = editor.visibleStart + Double(min(1, max(0, (p.x - laneLeft) / laneWidth))) * editor.visibleSpan
        switch input {
        case .magnify(let amount):
            editor.zoom(by: 1 + amount, around: anchor)
            return true
        case .scroll(let dx, let dy, let zoom):
            if zoom {
                editor.zoom(by: exp((abs(dy) >= abs(dx) ? dy : dx) * 0.01), around: anchor)
                return true
            }
            guard abs(dx) > abs(dy), dx != 0, editor.isZoomed else { return false }
            editor.pan(by: -dx / Double(laneWidth) * editor.visibleSpan)
            return true
        }
    }
}

/// Ghost block where a click in an empty lane would add a zoom, mask or lower third.
private struct HoverGhost: View {
    @ObservedObject var hover: TimelineHover
    let lane: TimelineHover.Lane
    let scale: TimelineScale
    let height: CGFloat

    var body: some View {
        if hover.lane == lane, let v = scale.visible(hover.range.lowerBound, hover.range.upperBound) {
            let (label, color): (String, Color) = switch lane {
            case .zoom: ("Zoom", .purple)
            case .mask: ("Maske", .orange)
            case .text: ("Bauchbinde", .teal)
            case .annotation: ("Rahmen", .red)
            case .camera: ("Kamera groß", .cyan)
            case .media: ("Bild oder Video …", .mint)
            case .cursor: ("Spotlight", .yellow)
            }
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.8), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                .overlay(alignment: .leading) {
                    if v.width > 50 {
                        Label(label, systemImage: "plus")
                            .font(.caption2.bold())
                            .foregroundStyle(color)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                    }
                }
                .frame(width: max(10, v.width), height: height)
                .offset(x: v.x)
        }
    }
}

/// A faster or slower part: tint and a badge with the speed.
private struct SpeedBadge: View {
    let rate: Double
    let visible: TimelineScale.Visible
    let height: CGFloat

    var body: some View {
        let color: Color = rate > 1 ? .orange : .cyan
        BlockShape(visible: visible, radius: 8)
            .fill(color.opacity(0.14))
            .overlay(alignment: .topTrailing) {
                if visible.width > 34 {
                    Label(InspectorView.speedLabel(rate), systemImage: rate > 1 ? "hare.fill" : "tortoise.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.85), in: Capsule())
                        .padding(4)
                        .lineLimit(1)
                }
            }
            .frame(width: visible.width, height: height)
    }
}

/// Freeze frame in the clip lane: click selects it, the right edge sets its duration.
private struct FreezeBlock: View {
    @ObservedObject var editor: EditorModel
    let freeze: FreezeFrame
    let visible: TimelineScale.Visible
    let pps: CGFloat
    let height: CGFloat
    /// Snapped drag delta of the right edge.
    let snap: (Double) -> Double

    var body: some View {
        let selected = editor.selection == .freeze(freeze.id)
        let width = max(8, visible.width)
        let shape = BlockShape(visible: visible, radius: 6)
        shape
            .fill(Color.cyan.opacity(selected ? 0.6 : 0.38))
            .overlay {
                // Diagonal stripes: the picture stands still here.
                Canvas { ctx, size in
                    var stripes = Path()
                    var x = -size.height
                    while x < size.width {
                        stripes.move(to: CGPoint(x: x, y: size.height))
                        stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                        x += 9
                    }
                    ctx.stroke(stripes, with: .color(.white.opacity(0.18)), lineWidth: 3)
                }
                .clipShape(shape)
            }
            .overlay(shape.strokeBorder(Color.cyan.opacity(0.9), lineWidth: 1))
            .timelineSelection(selected, shape: shape)
            .overlay(alignment: .leading) {
                if width > 46 {
                    Label(String(format: "%.1f s", freeze.duration), systemImage: "snowflake")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                } else if width > 18 {
                    Image(systemName: "snowflake").font(.caption2.bold()).foregroundStyle(.white).frame(maxWidth: .infinity)
                }
            }
            .overlay(alignment: .trailing) {
                if !visible.clippedRight { edge }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onTapGesture {
                editor.selection = .freeze(freeze.id)
                editor.seek(to: freeze.sourceRange.lowerBound + FreezeFrame.span / 2)
            }
            .help("Standbild: ziehen an der rechten Kante ändert die Dauer, ⌫ entfernt es")
    }

    private var edge: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 10)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                .onChanged { v in
                    if editor.freezeDragID != freeze.id {
                        editor.freezeDragID = freeze.id
                        editor.overlapDragOrigin = freeze.duration
                        editor.selection = .freeze(freeze.id)
                        editor.beginInteraction()
                    }
                    let dt = snap(Double(v.translation.width / pps))
                    editor.setFreezeDuration(id: freeze.id, (editor.overlapDragOrigin ?? freeze.duration) + dt)
                }
                .onEnded { _ in editor.endInteraction() })
    }
}

/// Inserted video clip in the clip lane: click selects it, the right edge shortens or lengthens it.
private struct InsertBlock: View {
    @ObservedObject var editor: EditorModel
    let clip: InsertClip
    let visible: TimelineScale.Visible
    let pps: CGFloat
    let height: CGFloat
    let snap: (Double) -> Double

    var body: some View {
        let selected = editor.selection == .insert(clip.id) || editor.isInGroup(.insert(clip.id))
        let shape = BlockShape(visible: visible, radius: 6)
        shape
            .fill(Color.green.opacity(selected ? 0.65 : 0.45))
            .overlay(shape.strokeBorder(Color.green.opacity(0.9), lineWidth: 1))
            .timelineSelection(selected, shape: shape)
            .overlay(alignment: .leading) {
                if visible.width > 46 {
                    Label(clip.name, systemImage: "film.stack")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                }
            }
            .overlay(alignment: .trailing) {
                if !visible.clippedRight {
                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: 10)
                        .contentShape(Rectangle())
                        .pointerStyle(.columnResize)
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                            .onChanged { v in
                                if editor.freezeDragID != clip.id {
                                    editor.freezeDragID = clip.id
                                    editor.overlapDragOrigin = clip.duration
                                    editor.selection = .insert(clip.id)
                                    editor.beginInteraction()
                                }
                                let dt = snap(Double(v.translation.width / pps))
                                editor.updateInsert(id: clip.id) { $0.duration = (editor.overlapDragOrigin ?? clip.duration) + dt }
                            }
                            .onEnded { _ in editor.endInteraction() })
                }
            }
            .frame(width: max(8, visible.width), height: height)
            .contentShape(Rectangle())
            .onTapGesture {
                editor.click(.insert(clip.id))
                if !NSEvent.modifierFlags.contains(.shift) { editor.seek(to: clip.sourceRange.lowerBound + FreezeFrame.span / 2) }
            }
            .help("Eingefügter Clip „\(clip.name)“: rechte Kante ändert die Länge, ⌫ entfernt ihn")
    }
}

// MARK: - Drag and drop of files

/// Lane files are dragged over.
final class DropHighlight: ObservableObject {
    @Published var rect: CGRect?
    @Published var label = ""
}

private struct DropHighlightView: View {
    @ObservedObject var highlight: DropHighlight
    let width: CGFloat

    var body: some View {
        if let r = highlight.rect {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(TimelineSelection.color.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(TimelineSelection.color, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                Text(highlight.label)
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.leading, 8)
            }
            .frame(width: width, height: r.height)
            .offset(y: r.minY)
            .allowsHitTesting(false)
        }
    }
}

/// Files dropped on the timeline: on the video lane movies are inserted, on the other picture lanes
/// pictures and movies are shown on top, on the audio lanes audio becomes the music.
struct TimelineDropDelegate: DropDelegate {
    let editor: EditorModel
    let layout: TimelineLayout
    let scale: TimelineScale
    let lanes: [AudioLane]
    let highlight: DropHighlight

    private func target(at y: CGFloat) -> (EditorModel.DropTarget, CGRect, String) {
        if y >= layout.clipY - 2 && y < layout.clipY + layout.clipH + 2 {
            return (.mainTrack, CGRect(x: 0, y: layout.clipY, width: 0, height: layout.clipH), "Video einfügen – die Aufnahme wartet")
        }
        if y >= layout.audioY(0) - 2 {
            if let i = lanes.firstIndex(of: .voiceOver), y >= layout.audioY(i) - 2, y < layout.audioY(i) + layout.audioH + 2 {
                return (.narration, CGRect(x: 0, y: layout.audioY(i), width: 0, height: layout.audioH),
                        "Audio als Sprachspur (Voice-over) – auch für Untertitel")
            }
            if let i = lanes.firstIndex(of: .music), y >= layout.audioY(i) - 2, y < layout.audioY(i) + layout.audioH + 2 {
                return (.music, CGRect(x: 0, y: layout.audioY(i), width: 0, height: layout.audioH), "Audio als weiterer Clip auf der Musikspur")
            }
            return (.audio, CGRect(x: 0, y: layout.audioY(0), width: 0, height: layout.total - layout.audioY(0)), "Audio als Hintergrundmusik")
        }
        return (.overlay, CGRect(x: 0, y: layout.mediaY, width: 0, height: layout.mediaTotal), "Über der Aufnahme einblenden")
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: EditorModel.droppableTypes) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let (_, rect, label) = target(at: info.location.y)
        if highlight.rect != rect { highlight.rect = rect }
        if highlight.label != label { highlight.label = label }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { highlight.rect = nil }

    func performDrop(info: DropInfo) -> Bool {
        highlight.rect = nil
        let (target, _, _) = target(at: info.location.y)
        let time = editor.sourceTime(max(0, scale.time(info.location.x)))
        let providers = info.itemProviders(for: EditorModel.droppableTypes)
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for p in providers {
                if let url = await p.loadFileURL() { urls.append(url) }
            }
            editor.drop(urls, target: target, at: time)
        }
        return true
    }
}

extension NSItemProvider {
    /// The file URL of a dragged Finder item.
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { cont in
            _ = loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
    }
}


/// Hatched, transparent band over removed parts (in every lane).
private struct RemovedBand: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.08)))
            var lines = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                lines.move(to: CGPoint(x: x, y: size.height))
                lines.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 8
            }
            context.stroke(lines, with: .color(color.opacity(0.22)), lineWidth: 1)
        }
        .clipped()
    }
}
