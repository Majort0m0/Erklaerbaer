import AppKit
import AVFoundation

/// Small round camera preview that floats above all windows while recording.
/// It belongs to Screenkast, which is excluded from the capture, so it never appears in the video.
@MainActor
final class FloatingCameraPanel {
    private var panel: NSPanel?

    func show(session: AVCaptureSession) {
        guard panel == nil else { return }
        let size: CGFloat = 170
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let rect = NSRect(x: frame.maxX - size - 24, y: frame.minY + 24, width: size, height: size)
        let panel = Self.makePanel(session: session, frame: rect)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    static func makePanel(session: AVCaptureSession?, frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The bubble moves itself (see CameraBubbleView): no window-server or AppKit window drag.
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = CameraBubbleView(frame: NSRect(origin: .zero, size: frame.size), session: session)
        return panel
    }
}

/// Round, mirrored live preview that can be dragged around.
///
/// Dragging is done by hand (mouseDown/mouseDragged → setFrameOrigin). The first version
/// combined `isMovableByWindowBackground` with SwiftUI's `WindowDragGesture`; dragging the
/// bubble during a recording then froze the app.
final class CameraBubbleView: NSView {
    /// Current mouse position in screen coordinates (replaceable for tests).
    var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    init(frame: NSRect, session: AVCaptureSession?) {
        super.init(frame: frame)
        let root = CALayer()
        root.frame = bounds
        root.cornerRadius = min(frame.width, frame.height) / 2
        root.masksToBounds = true
        root.backgroundColor = NSColor.black.cgColor
        root.borderWidth = 2
        root.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        if let session {
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = root.bounds
            // Mirror like a selfie view.
            preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            root.addSublayer(preview)
        }
        layer = root
        wantsLayer = true
        toolTip = "Kamera-Vorschau (wird nicht aufgenommen) – zum Verschieben ziehen"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = (mouseLocation(), window.frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = dragStart else { return }
        let p = mouseLocation()
        var frame = window.frame
        frame.origin = NSPoint(x: start.origin.x + p.x - start.mouse.x, y: start.origin.y + p.y - start.mouse.y)
        window.setFrameOrigin(Self.keepVisible(frame, near: p).origin)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    /// Keeps the bubble inside the visible area of the screen under the mouse.
    static func keepVisible(_ frame: NSRect, near p: NSPoint) -> NSRect {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) ?? NSScreen.main else {
            return frame
        }
        let v = screen.visibleFrame
        var f = frame
        f.origin.x = min(max(f.origin.x, v.minX), v.maxX - f.width)
        f.origin.y = min(max(f.origin.y, v.minY), v.maxY - f.height)
        return f
    }
}
