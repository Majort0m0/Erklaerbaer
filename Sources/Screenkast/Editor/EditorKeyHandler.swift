import AppKit
import SwiftUI

/// Editor keys: Space = play/pause, ⌫ = delete the selected item, ←/→ = one frame (⇧: one second),
/// Home/End = start/end, S or ⌘B = split, ⇧S = join again, ⌥F = freeze frame, ⌘Z / ⇧⌘Z = undo/redo, N = snapping, Esc = deselect,
/// ⌘+ / ⌘− = zoom the timeline, ⇧Z or ⌘0 = fit the timeline.
///
/// A local event monitor instead of SwiftUI's `onKeyPress`: `onKeyPress` on the editor also
/// caught keys typed into text fields (Space started the player while editing a caption).
/// Here the keys are left alone while a text field is being edited, and a click outside
/// the edited field ends the editing, so Space plays again afterwards.
enum EditorKeyCommand: Equatable {
    case step(frames: Int), stepSeconds(Double), home, end, zoomIn, zoomOut, zoomFit
    case split, undo, redo, toggleSnapping, deselect, freeze, chapter, copy, paste, shuttle(Int)
    case selectRight, addStep, cycleTrimMode
    case trimStart, trimEnd, addZoom, addText, addMask, addArrow, addFrame, addSpotlight, addFinger, addCursor, addImage, addVideo
    case voiceOver, toggleMagnet, transition, join, speed(Int), memeBoard, meme(Int)
}

struct EditorKeyHandler: NSViewRepresentable {
    let onSpace: () -> Void
    let onDelete: () -> Void
    var onCommand: (EditorKeyCommand) -> Void = { _ in }
    /// Every mouse-up in the window (ends drags whose gesture got lost).
    var onMouseUp: () -> Void = {}

    func makeNSView(context: Context) -> EditorKeyHandlerView { EditorKeyHandlerView() }

    func updateNSView(_ view: EditorKeyHandlerView, context: Context) {
        view.onSpace = onSpace
        view.onDelete = onDelete
        view.onCommand = onCommand
        view.onMouseUp = onMouseUp
    }
}

final class EditorKeyHandlerView: NSView {
    var onSpace: () -> Void = {}
    var onDelete: () -> Void = {}
    var onCommand: (EditorKeyCommand) -> Void = { _ in }
    var onMouseUp: () -> Void = {}
    private var monitor: Any?

    /// Never takes clicks itself.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit { removeMonitor() }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// True while a text field in `window` is being edited (its field editor has the focus).
    static func isEditingText(in window: NSWindow?) -> Bool {
        window?.firstResponder is NSText
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        let textEditor = window.firstResponder as? NSText

        if event.type == .leftMouseUp {
            // After SwiftUI has handled the event (its gesture ends first).
            DispatchQueue.main.async { [weak self] in self?.onMouseUp() }
            return event
        }
        if event.type == .leftMouseDown {
            // Clicking anywhere outside the edited field ends the editing (the text is kept).
            if let textEditor {
                let field = (textEditor.delegate as? NSView) ?? textEditor
                if !field.convert(field.bounds, to: nil).contains(event.locationInWindow) {
                    window.makeFirstResponder(nil)
                }
            }
            return event
        }

        guard textEditor == nil, window.attachedSheet == nil else { return event }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers ?? ""
        if mods == [.command] {
            switch chars.lowercased() {
            case "+", "=": onCommand(.zoomIn)
            case "-": onCommand(.zoomOut)
            case "0": onCommand(.zoomFit)
            case "z": onCommand(.undo)
            case "b": onCommand(.split)
            case "c": onCommand(.copy)
            case "v": onCommand(.paste)
            case "t": onCommand(.transition)
            default: return event
            }
            return nil
        }
        if mods == [.option], event.keyCode == 3 {   // ⌥F: freeze frame
            onCommand(.freeze)
            return nil
        }
        if mods == [.option], event.keyCode == 126 || event.keyCode == 125 {   // ⌥↑ ⌥↓: tempo
            onCommand(.speed(event.keyCode == 126 ? 1 : -1))
            return nil
        }
        if mods == [.command, .shift], event.keyCode == 124 {   // ⇧⌘→
            onCommand(.selectRight)
            return nil
        }
        if mods == [.command, .shift], chars.lowercased() == "z" {
            onCommand(.redo)
            return nil
        }
        if mods == [.shift] {
            switch event.keyCode {
            case 123: onCommand(.stepSeconds(-1))
            case 124: onCommand(.stepSeconds(1))
            default:
                switch chars.lowercased() {
                case "z": onCommand(.zoomFit)
                case "s": onCommand(.join)   // ⇧S: join split clips again
                default: return event
                }
            }
            return nil
        }
        guard mods.isEmpty else { return event }
        switch event.keyCode {
        case 49:            // Space
            onSpace()
        case 51, 117:       // Backspace, forward delete
            onDelete()
        case 123: onCommand(.step(frames: -1))
        case 124: onCommand(.step(frames: 1))
        case 115: onCommand(.home)
        case 119: onCommand(.end)
        case 53: onCommand(.deselect)   // Esc
        default:
            if chars.count == 1, let digit = Int(chars) {   // 1 … 9, 0: the places of the meme board
                onCommand(.meme(digit == 0 ? 9 : digit - 1))
                return nil
            }
            switch chars.lowercased() {
            case "s": onCommand(.split)
            case "n": onCommand(.toggleSnapping)
            case "m": onCommand(.chapter)
            case "j": onCommand(.shuttle(-1))
            case "k": onCommand(.shuttle(0))
            case "l": onCommand(.shuttle(1))
            case "q": onCommand(.trimStart)
            case "w": onCommand(.trimEnd)
            case "z": onCommand(.addZoom)
            case "t": onCommand(.addText)
            case "x": onCommand(.addMask)
            case "a": onCommand(.addArrow)
            case "r": onCommand(.addFrame)
            case "p": onCommand(.addSpotlight)
            case "f": onCommand(.addFinger)
            case "b": onCommand(.addStep)
            case "y": onCommand(.cycleTrimMode)
            case "e": onCommand(.memeBoard)
            case "c": onCommand(.addCursor)
            case "i": onCommand(.addImage)
            case "o": onCommand(.addVideo)
            case "v": onCommand(.voiceOver)
            case "g": onCommand(.toggleMagnet)
            default: return event
            }
        }
        return nil
    }
}
