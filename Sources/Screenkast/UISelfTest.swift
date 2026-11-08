import AppKit
import AVFoundation
import SwiftUI

/// UI checks with synthetic events in windows that are never visible (part of `--selftest`).
@MainActor
enum UISelfTest {
    static func run() throws {
        _ = NSApplication.shared
        try bubbleDrag()
        try editorKeys()
    }

    private static func fail(_ message: String) -> NSError {
        NSError(domain: "selftest", code: 20, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func mouse(_ type: NSEvent.EventType, at p: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    // MARK: Camera bubble

    /// Dragging moves the bubble by the mouse delta and keeps it on the screen.
    private static func bubbleDrag() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            print("– camera bubble drag skipped (no screen)")
            return
        }
        let v = screen.visibleFrame
        let start = NSRect(x: v.midX - 85, y: v.midY - 85, width: 170, height: 170)
        let panel = FloatingCameraPanel.makePanel(session: nil, frame: start)   // never ordered in
        defer { panel.close() }
        guard let bubble = panel.contentView as? CameraBubbleView else { throw fail("camera bubble view missing") }
        var pointer = NSPoint(x: v.midX, y: v.midY)
        bubble.mouseLocation = { pointer }
        let startOrigin = panel.frame.origin   // AppKit may round the requested frame
        // The panel is never shown, so the events go straight to the view (AppKit does not route
        // mouse events to windows that are not on screen).
        let inside = NSPoint(x: 85, y: 85)
        func send(_ type: NSEvent.EventType) {
            let e = mouse(type, at: inside, in: panel)
            switch type {
            case .leftMouseDown: bubble.mouseDown(with: e)
            case .leftMouseDragged: bubble.mouseDragged(with: e)
            default: bubble.mouseUp(with: e)
            }
        }
        guard bubble.acceptsFirstMouse(for: nil), !bubble.mouseDownCanMoveWindow, !panel.isMovable,
              !panel.isMovableByWindowBackground else { throw fail("camera panel must not use window dragging") }

        send(.leftMouseDown)
        for i in 1...10 {
            pointer = NSPoint(x: v.midX + CGFloat(i) * 10, y: v.midY - CGFloat(i) * 5)
            send(.leftMouseDragged)
        }
        send(.leftMouseUp)
        let moved = panel.frame.origin
        guard abs(moved.x - (startOrigin.x + 100)) < 0.5, abs(moved.y - (startOrigin.y - 50)) < 0.5 else {
            throw fail("camera bubble at \(moved), expected \(startOrigin.x + 100), \(startOrigin.y - 50)")
        }

        // Dragging past the corner of the screen keeps the bubble inside the visible area.
        pointer = NSPoint(x: v.midX, y: v.midY)
        send(.leftMouseDown)
        pointer = NSPoint(x: v.maxX - 1, y: v.minY + 1)
        send(.leftMouseDragged)
        send(.leftMouseUp)
        let f = panel.frame
        guard f.maxX <= v.maxX + 0.5, f.minY >= v.minY - 0.5, f.maxX > v.maxX - 1, f.minY < v.minY + 1 else {
            throw fail("camera bubble not kept on screen: \(f) in \(v)")
        }

        // A drag after the mouse was released does nothing.
        let before = panel.frame.origin
        pointer = NSPoint(x: v.midX, y: v.midY)
        send(.leftMouseDragged)
        guard panel.frame.origin == before else { throw fail("camera bubble moved without mouse down") }
        print("✓ camera bubble drag (moves with the mouse, stays on screen)")
    }

    // MARK: Editor keys

    private final class KeyModel: ObservableObject {
        @Published var text = "Hallo"
        var plays = 0
        var deletes = 0
    }

    private struct KeyHarness: View {
        @ObservedObject var model: KeyModel
        var body: some View {
            VStack {
                Rectangle().fill(.gray).frame(width: 200, height: 100)
                TextField("Text", text: $model.text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            .frame(width: 400, height: 300)
            .background(EditorKeyHandler(onSpace: { model.plays += 1 }, onDelete: { model.deletes += 1 }))
        }
    }

    /// Space/⌫ go into a caption text field while it is edited; otherwise they play/delete.
    private static func editorKeys() throws {
        let model = KeyModel()
        // Borderless and far outside every screen, so it is never seen.
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: KeyHarness(model: model))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        func pump(_ seconds: Double = 0.15) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(e)
                }
            }
        }
        func key(_ chars: String, _ code: UInt16) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                NSApp.postEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, characters: chars,
                                                 charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!,
                                atStart: false)
            }
            pump()
        }
        func click(_ p: NSPoint) {
            NSApp.postEvent(mouse(.leftMouseDown, at: p, in: window), atStart: false)
            NSApp.postEvent(mouse(.leftMouseUp, at: p, in: window), atStart: false)
            pump()
        }
        func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }

        pump(0.3)
        host.layoutSubtreeIfNeeded()
        guard let field = allViews(host).compactMap({ $0 as? NSTextField }).first else { throw fail("no text field") }
        window.makeFirstResponder(field)
        (window.firstResponder as? NSTextView)?.setSelectedRange(NSRange(location: 5, length: 0))
        pump()
        guard EditorKeyHandlerView.isEditingText(in: window) else { throw fail("text field not editing") }

        // While editing, the handler lets Space/⌫ through to the text field. (Whether AppKit then
        // inserts the character can't be checked here: windows that are not visible get no text input.)
        key(" ", 49)
        key("\u{7f}", 51)
        guard model.plays == 0, model.deletes == 0, EditorKeyHandlerView.isEditingText(in: window) else {
            throw fail("keys while editing: plays \(model.plays), deletes \(model.deletes)")
        }
        (window.firstResponder as? NSTextView)?.insertText(" Welt", replacementRange: NSRange(location: 5, length: 0))

        // Click into the field keeps editing, a click outside ends it and keeps the text.
        let fieldRect = field.convert(field.bounds, to: nil)
        click(NSPoint(x: fieldRect.midX, y: fieldRect.midY))
        guard EditorKeyHandlerView.isEditingText(in: window) else { throw fail("click into field ended editing") }
        click(NSPoint(x: 200, y: fieldRect.maxY + 50))
        guard !EditorKeyHandlerView.isEditingText(in: window), model.text == "Hallo Welt" else {
            throw fail("click outside: editing \(EditorKeyHandlerView.isEditingText(in: window)), text \"\(model.text)\"")
        }

        key(" ", 49)
        key("\u{7f}", 51)
        guard model.plays == 1, model.deletes == 1, model.text == "Hallo Welt" else {
            throw fail("editor keys: plays \(model.plays), deletes \(model.deletes), text \"\(model.text)\"")
        }
        print("✓ editor keys (space/backspace left to text fields while editing, otherwise play/delete)")
    }

    // MARK: Timeline mouse

    /// A real `EditorTimeline` driven by synthetic mouse and key events: ruler click, playhead drag,
    /// voice-over clip drag (the composition is rebuilt only after the mouse is released), ⌘+ zoom
    /// and ⌥ + scroll wheel zoom.
    static func timeline(project base: Project) throws {
        // Clean settings: earlier tests' editors save theirs into the same project.
        var settings = EditSettings()
        settings.zoomSegments = base.settings.zoomSegments
        settings.voiceOvers = [VoiceOverClip(file: "voiceover/selftest.caf", fileOffset: 0, start: 0.5, duration: 1.5)]
        settings.texts = []
        settings.cuts = []
        settings.trimStart = 0
        settings.trimEnd = nil
        let project = Project(url: base.url, info: base.info, cursor: base.cursor, settings: settings)
        let editor = EditorModel(project: project)
        let size = NSSize(width: 1000, height: 400)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = EditorTimeline(editor: editor)
            .frame(width: size.width, height: size.height)
            .background(EditorKeyHandler(onSpace: {}, onDelete: { editor.deleteSelection() }, onCommand: { editor.perform($0) },
                                         onMouseUp: { editor.endInteraction() }))
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        func pump(_ seconds: Double = 0.1) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(e)
                }
            }
        }
        func pump(until done: () -> Bool, max seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end { pump(0.05) }
        }
        pump(until: { editor.player.currentItem != nil }, max: 10)
        pump(0.5)
        guard let firstItem = editor.player.currentItem else { throw fail("timeline: no player item") }

        let layout = TimelineLayout(available: size.height - EditorTimeline.footerHeight, audioCount: editor.audioLanes.count,
                                    hasCamera: editor.hasCamera)
        let laneLeft = EditorTimeline.headerWidth, laneWidth = size.width - laneLeft
        func x(_ t: Double) -> CGFloat { laneLeft + CGFloat((t - editor.visibleStart) / editor.visibleSpan) * laneWidth }
        /// Window point from x and a y measured from the top of the timeline.
        func point(_ x: CGFloat, _ top: CGFloat) -> NSPoint { NSPoint(x: x, y: size.height - top) }
        func post(_ type: NSEvent.EventType, _ p: NSPoint) { NSApp.postEvent(mouse(type, at: p, in: window), atStart: false) }
        func click(_ p: NSPoint) {
            post(.leftMouseDown, p)
            post(.leftMouseUp, p)
            pump(0.25)
        }
        func drag(_ a: NSPoint, _ b: NSPoint, whileDragging: () -> Void = {}) {
            post(.leftMouseDown, a)
            pump(0.05)
            for i in 1...10 {
                let f = CGFloat(i) / 10
                post(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
                pump(0.03)
            }
            whileDragging()
            post(.leftMouseUp, b)
            pump(0.25)
        }

        // 1. A click into the ruler moves the playhead there.
        click(point(x(2.0), layout.ruler / 2))
        guard abs(editor.currentTime - 2.0) < 0.02 else { throw fail("ruler click: playhead at \(editor.currentTime), expected 2.0") }

        // 2. The playhead line can be dragged (here in the empty mask lane).
        drag(point(x(2.0), layout.maskY + 10), point(x(3.0), layout.maskY + 10))
        guard abs(editor.currentTime - 3.0) < 0.02 else { throw fail("playhead drag: at \(editor.currentTime), expected 3.0") }

        // 3. Dragging a voice-over clip moves it; the composition waits for the mouse-up.
        guard let voLane = editor.audioLanes.firstIndex(of: .voiceOver) else { throw fail("no voice-over lane") }
        let voY = layout.audioY(voLane) + layout.audioH / 2
        var interactingWhileDragging = false
        var sameItemWhileDragging = false
        drag(point(x(1.25), voY), point(x(1.65), voY)) {
            interactingWhileDragging = editor.isInteracting
            sameItemWhileDragging = editor.player.currentItem === firstItem
        }
        let clip = editor.settings.voiceOvers[0]
        guard abs(clip.start - 0.9) < 0.02, interactingWhileDragging, sameItemWhileDragging, !editor.isInteracting else {
            throw fail("clip drag: start \(clip.start) (expected 0.9), interacting \(interactingWhileDragging), "
                       + "same item \(sameItemWhileDragging), still interacting \(editor.isInteracting)")
        }
        pump(until: { editor.player.currentItem !== firstItem }, max: 10)
        guard editor.player.currentItem !== firstItem else { throw fail("clip drag: composition not rebuilt after release") }

        // 4. ⌘+ zooms in; the ruler then maps clicks with the new scale.
        let keyEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, characters: "+", charactersIgnoringModifiers: "+", isARepeat: false, keyCode: 30)!
        NSApp.postEvent(keyEvent, atStart: false)
        pump(0.2)
        guard editor.isZoomed, abs(editor.visibleSpan - editor.totalSpan / 2) < 1e-6 else {
            throw fail("⌘+: span \(editor.visibleSpan) of \(editor.totalSpan)")
        }
        let target = editor.visibleStart + editor.visibleSpan * 0.3
        click(point(x(target), layout.ruler / 2))
        guard abs(editor.currentTime - target) < 0.02 else { throw fail("zoomed ruler click: \(editor.currentTime), expected \(target)") }

        // 5. Scroll wheel and trackpad (synthetic scroll events reach no window, so the view's handler is
        //    called directly): ⌥ + scroll and pinch zoom around the mouse, a sideways swipe scrolls,
        //    vertical scrolling stays with the lanes.
        func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }
        guard let content = window.contentView,
              let catcher = allViews(content).compactMap({ $0 as? TimelineScrollCatcherView }).first else {
            throw fail("timeline: scroll handler view missing")
        }
        func at(_ fraction: Double) -> (NSPoint, Double) {
            let t = editor.visibleStart + editor.visibleSpan * fraction
            return (catcher.convert(point(x(t), layout.zoomY + 10), from: nil), t)
        }
        var (p, t) = at(0.25)
        var span = editor.visibleSpan
        guard catcher.apply(.scroll(dx: 0, dy: 40, zoom: true), at: p), editor.visibleSpan < span * 0.9,
              abs((t - editor.visibleStart) / editor.visibleSpan - 0.25) < 0.01 else {
            throw fail("⌥+scroll zoom: span \(span) → \(editor.visibleSpan)")
        }
        (p, t) = at(0.7)
        span = editor.visibleSpan
        guard catcher.apply(.magnify(-0.3), at: p), editor.visibleSpan > span * 1.2,
              abs((t - editor.visibleStart) / editor.visibleSpan - 0.7) < 0.01 else {
            throw fail("pinch zoom: span \(span) → \(editor.visibleSpan)")
        }
        let start = editor.visibleStart
        guard catcher.apply(.scroll(dx: -50, dy: 2, zoom: false), at: p),
              abs(editor.visibleStart - (start + 50 / Double(laneWidth) * editor.visibleSpan)) < 1e-6 else {
            throw fail("sideways scroll: start \(start) → \(editor.visibleStart)")
        }
        guard !catcher.apply(.scroll(dx: 0, dy: -30, zoom: false), at: p), abs(editor.visibleStart - (start + 50 / Double(laneWidth) * editor.visibleSpan)) < 1e-6,
              !catcher.apply(.scroll(dx: 0, dy: 40, zoom: true), at: NSPoint(x: -50, y: 10)) else {
            throw fail("vertical scroll or scroll outside the timeline was taken")
        }
        let scrollNote = "⌥+scroll/pinch zoom around the mouse, sideways scroll"
        // 6. S splits at the playhead, a click selects the part, ⌫ removes it, ⌘Z brings it back.
        editor.zoomToFit()
        editor.settings.zoomSegments = []
        editor.settings.masks = []
        pump(0.2)
        func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
            NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                             isARepeat: false, keyCode: code)!, atStart: false)
            pump(0.2)
        }
        key("\u{1b}", 53)   // Esc: deselect (a selected voice-over clip would be split instead)
        guard editor.selection == nil else { throw fail("Esc did not deselect") }
        click(point(x(2.0), layout.ruler / 2))
        key("s", 1)
        guard editor.settings.splits.contains(where: { abs($0 - 2.0) < 0.03 }) else { throw fail("S: splits \(editor.settings.splits)") }
        click(point(x(3.0), layout.clipY + layout.clipH / 2))
        guard case .segment(let start) = editor.selection, abs(start - 2.0) < 0.03 else {
            throw fail("click on the clip: selection \(String(describing: editor.selection))")
        }
        key("\u{7f}", 51)
        guard editor.settings.cuts.count == 1, editor.settings.keptSegments(duration: editor.duration).count == 1 else {
            throw fail("⌫ on a part: cuts \(editor.settings.cuts)")
        }
        key("z", 6, .command)
        guard editor.settings.cuts.isEmpty else { throw fail("⌘Z: cuts \(editor.settings.cuts)") }

        // 7. Hovering over the empty mask lane shows a ghost block; a click adds a mask there.
        var hoverNote = "click in an empty lane adds"
        window.acceptsMouseMovedEvents = true
        let maskPoint = point(x(1.0), layout.maskY + layout.maskH / 2)
        NSApp.postEvent(mouse(.mouseMoved, at: maskPoint, in: window), atStart: false)
        pump(0.2)
        if editor.timelineHover.lane == .mask {
            click(maskPoint)
            guard editor.settings.masks.count == 1, abs(editor.settings.masks[0].start - 1.0) < 0.03 else {
                throw fail("click on the mask ghost: \(editor.settings.masks)")
            }
        } else {
            hoverNote = "hover not testable with synthetic events"
        }
        // 8. ⌥F holds the last frame of the selected part; dragging its right edge makes it longer.
        editor.settings.masks = []
        editor.settings.splits = [2.0]
        editor.settings.cuts = []
        pump(0.3)
        click(point(x(1.0), layout.clipY + layout.clipH / 2))
        guard editor.selection == .segment(0) else { throw fail("click on the first part: \(String(describing: editor.selection))") }
        NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: "ƒ", charactersIgnoringModifiers: "f",
                                         isARepeat: false, keyCode: 3)!, atStart: false)
        pump(0.6)
        guard let freeze = editor.settings.freezes.first, editor.selection == .freeze(freeze.id), abs(freeze.at - 2.0) < 1e-6 else {
            throw fail("⌥F: freezes \(editor.settings.freezes)")
        }
        let edgeX = x(editor.display(freeze.at)) - 4
        let pps = Double(laneWidth) / editor.visibleSpan
        let freezeY = layout.clipY + layout.clipH / 2
        drag(point(edgeX, freezeY), point(edgeX + 43, freezeY))
        let longer = editor.settings.freezes.first?.duration ?? 0
        guard abs(longer - (freeze.duration + 43 / pps)) < 0.1 else {
            throw fail("freeze edge drag: \(longer) s, expected about \(freeze.duration + 43 / pps)")
        }
        // 8b. Dragging the second part in front of the first moves it; ⌘Z takes it back. The edge trims.
        editor.settings.freezes = []
        editor.settings.splits = [2.0]
        editor.settings.cuts = []
        pump(0.3)
        let clipY = layout.clipY + layout.clipH / 2
        drag(point(x(editor.display(3.0)), clipY), point(x(0.2), clipY))
        guard editor.clipParts.first?.range.lowerBound == 2.0, editor.settings.clipOrder != nil else {
            throw fail("dragging a part: \(editor.clipParts.map(\.range))")
        }
        key("z", 6, .command)
        pump(0.3)
        guard editor.settings.clipOrder == nil else { throw fail("⌘Z after moving a part") }
        click(point(x(3.5), layout.ruler / 2))   // the playhead is not in the way
        let totalBefore = editor.timeMap.total
        let rippleEdge = x(2.0) - 3
        drag(point(rippleEdge, clipY), point(rippleEdge - 40, clipY))
        guard editor.settings.cuts.count == 1, editor.timeMap.total < totalBefore - 0.1 else {
            throw fail("edge drag: cuts \(editor.settings.cuts), total \(editor.timeMap.total) of \(totalBefore)")
        }
        key("z", 6, .command)
        pump(0.3)
        editor.settings.cuts = []
        // 9. A click on a lane name selects the lane; a click in an empty lane then ends the selection (adds nothing).
        click(NSPoint(x: 40, y: size.height - (layout.zoomY + 11)))
        guard editor.selection == .panel(.zoom) else { throw fail("click on the lane name: \(String(describing: editor.selection))") }
        let masksBefore = editor.settings.masks.count
        click(point(x(3.6), layout.maskY + layout.maskH / 2))
        guard editor.selection == nil, editor.settings.masks.count == masksBefore else {
            throw fail("click in an empty lane: selection \(String(describing: editor.selection)), masks \(editor.settings.masks.count)")
        }
        click(NSPoint(x: 40, y: size.height - (layout.audioY(0) + layout.audioH / 2)))
        guard editor.selection == .audioLane(editor.audioLanes[0]) else { throw fail("click on an audio lane name: \(String(describing: editor.selection))") }
        print("✓ timeline mouse: ruler click, playhead drag, clip drag (rebuilt only after release), ⌘+ zoom, \(scrollNote), "
              + "S/click/⌫/⌘Z on parts, \(hoverNote), ⌥F freeze + edge drag (\(String(format: "%.1f", freeze.duration)) → \(String(format: "%.1f", longer)) s), "
              + "lane names select lanes, a click beside ends the selection")
    }

    // MARK: Preview handles

    /// The handles on the preview, driven by synthetic mouse events: a mask moves with the mouse,
    /// the arrow's tip and tail follow exactly (no jumping, also on a second drag).
    static func previewHandles(project base: Project) throws {
        var settings = EditSettings()
        settings.zoomSegments = []
        settings.cameraVisible = false
        settings.removeEcho = false
        let project = Project(url: base.url, info: base.info, cursor: base.cursor, settings: settings)
        let editor = EditorModel(project: project)
        let out = editor.renderer.outputSize
        let size = NSSize(width: 800, height: 800 * out.height / out.width)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = PreviewArea(editor: editor)
            .frame(width: size.width, height: size.height)
            .background(EditorKeyHandler(onSpace: {}, onDelete: {}, onCommand: { _ in }, onMouseUp: { editor.endInteraction() }))
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func pump(_ seconds: Double = 0.1) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(e)
                }
            }
        }
        let wait = Date().addingTimeInterval(10)
        while editor.player.currentItem == nil && Date() < wait { pump(0.05) }
        pump(0.3)
        func post(_ type: NSEvent.EventType, _ p: CGPoint) {
            NSApp.postEvent(mouse(type, at: NSPoint(x: p.x, y: size.height - p.y), in: window), atStart: false)
        }
        /// Drag from a view point (top-left origin) by a delta.
        func drag(from a: CGPoint, by d: CGSize) {
            post(.leftMouseDown, a)
            pump(0.05)
            for i in 1...8 {
                let f = CGFloat(i) / 8
                post(.leftMouseDragged, CGPoint(x: a.x + d.width * f, y: a.y + d.height * f))
                pump(0.03)
            }
            post(.leftMouseUp, CGPoint(x: a.x + d.width, y: a.y + d.height))
            pump(0.2)
        }
        let g = PreviewGeometry(editor: editor, size: CGSize(width: size.width, height: size.height))

        // 1. The mask moves with the mouse (inside), a corner resizes it.
        editor.settings.masks = [BlurMask(start: 0, end: editor.duration, x: 0.2, y: 0.2, width: 0.25, height: 0.25)]
        editor.seek(to: 1.0)
        editor.selection = .mask(editor.settings.masks[0].id)
        pump(0.3)
        let m0 = editor.settings.masks[0]
        let r0 = g.view(CGRect(x: m0.x, y: m0.y, width: m0.width, height: m0.height))
        drag(from: CGPoint(x: r0.midX, y: r0.midY), by: CGSize(width: 60, height: 30))
        let m1 = editor.settings.masks[0]
        let r1 = g.view(CGRect(x: m1.x, y: m1.y, width: m1.width, height: m1.height))
        guard abs(r1.midX - r0.midX - 60) < 1.5, abs(r1.midY - r0.midY - 30) < 1.5, abs(r1.width - r0.width) < 0.5 else {
            throw fail("mask move: \(r0) → \(r1)")
        }
        drag(from: CGPoint(x: r1.maxX, y: r1.maxY), by: CGSize(width: 40, height: 20))
        let m2 = editor.settings.masks[0]
        let r2 = g.view(CGRect(x: m2.x, y: m2.y, width: m2.width, height: m2.height))
        guard abs(r2.width - r1.width - 40) < 1.5, abs(r2.height - r1.height - 20) < 1.5, abs(r2.minX - r1.minX) < 0.5 else {
            throw fail("mask corner: \(r1) → \(r2)")
        }

        // 2. The arrow: the tip follows the mouse exactly, the tail stays; then the tail, the tip stays.
        editor.settings.masks = []
        editor.settings.annotations = [Annotation(kind: .arrow, start: 0, end: editor.duration, x: 0.3, y: 0.3, width: 0.2, height: 0.15)]
        editor.selection = .annotation(editor.settings.annotations[0].id)
        pump(0.3)
        func ends() -> (CGPoint, CGPoint) {
            let a = editor.settings.annotations[0]
            return (g.view(CGPoint(x: a.x, y: a.y)), g.view(CGPoint(x: a.x + a.width, y: a.y + a.height)))
        }
        let (tail0, head0) = ends()
        drag(from: head0, by: CGSize(width: -50, height: 40))
        let (tail1, head1) = ends()
        guard hypot(head1.x - head0.x + 50, head1.y - head0.y - 40) < 1.5, hypot(tail1.x - tail0.x, tail1.y - tail0.y) < 0.5 else {
            throw fail("arrow tip: \(head0) → \(head1), tail \(tail0) → \(tail1)")
        }
        drag(from: tail1, by: CGSize(width: 30, height: -20))
        let (tail2, head2) = ends()
        guard hypot(tail2.x - tail1.x - 30, tail2.y - tail1.y + 20) < 1.5, hypot(head2.x - head1.x, head2.y - head1.y) < 0.5 else {
            throw fail("arrow tail: \(tail1) → \(tail2), tip \(head1) → \(head2)")
        }
        // The shaft moves the whole arrow.
        drag(from: CGPoint(x: (tail2.x + head2.x) / 2, y: (tail2.y + head2.y) / 2), by: CGSize(width: 25, height: 15))
        let (tail3, head3) = ends()
        guard hypot(tail3.x - tail2.x - 25, tail3.y - tail2.y - 15) < 1.5, hypot(head3.x - head2.x - 25, head3.y - head2.y - 15) < 1.5 else {
            throw fail("arrow move: \(tail2)/\(head2) → \(tail3)/\(head3)")
        }
        // Outside the arrow's time its handles are hidden.
        editor.settings.annotations[0].end = 0.5
        editor.seek(to: 2.0)
        pump(0.2)
        let before = editor.settings.annotations[0]
        drag(from: CGPoint(x: (tail3.x + head3.x) / 2, y: (tail3.y + head3.y) / 2), by: CGSize(width: 40, height: 0))
        guard editor.settings.annotations[0] == before else { throw fail("arrow handles active outside its time") }
        print("✓ preview handles: mask moves with the mouse and resizes at a corner; arrow tip, tail and shaft follow the mouse exactly (also on later drags); no handles outside the item's time")
    }
}

