import AppKit
import AVFoundation

/// Live picture of the iPad on the Mac while it is recorded (the recording comes from the iPad
/// itself, so this window is never part of the video).
@MainActor
final class DevicePreviewPanel {
    private var panel: NSPanel?

    func show(session: AVCaptureSession, pixelSize: CGSize, name: String) {
        guard panel == nil else { return }
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let scale = min(screen.width * 0.42 / max(1, pixelSize.width), screen.height * 0.62 / max(1, pixelSize.height))
        let size = NSSize(width: (pixelSize.width * scale).rounded(), height: (pixelSize.height * scale).rounded())
        let rect = NSRect(x: screen.minX + 32, y: screen.maxY - size.height - 48, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: rect, styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "\(name) – Live-Ansicht"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = size
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspect
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(preview)
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
    }

    var windowNumber: Int? { panel?.windowNumber }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
