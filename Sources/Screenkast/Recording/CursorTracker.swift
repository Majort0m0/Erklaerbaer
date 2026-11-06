import AppKit
import QuartzCore

/// Records cursor position, cursor shape and clicks while the screen recording runs.
/// Coordinates are stored normalized to the captured rect (origin top-left), times in
/// seconds relative to the first video frame (both use the host clock).
@MainActor
final class CursorTracker {
    private(set) var track = CursorTrack()
    private var imagePNGs: [Data] = []
    private var imageKeys: [Data: Int] = [:]

    private var captureRect: CGRect = .zero   // global CG coordinates (points, top-left origin)
    private var hostStart: Double = 0
    private var timer: Timer?
    private var clickMonitor: Any?
    private var lastPos = CGPoint(x: -1, y: -1)
    private var lastSampleTime = -1.0
    private var lastCursorIndex = -1
    private var lastCursorCheck = -1.0
    private var running = false
    /// Shared pause state (set by the app before starting).
    var pauseGate: PauseGate?
    /// Record keyboard shortcuts (needs Accessibility permission).
    var recordShortcuts = false
    private var keyMonitor: Any?

    /// - Parameters:
    ///   - rect: captured area in global CoreGraphics coordinates (points).
    ///   - hostStart: host time (seconds, `CACurrentMediaTime`) of the first video frame.
    func start(rect: CGRect, hostStart: Double) {
        track = CursorTrack()
        imagePNGs = []
        imageKeys = [:]
        lastPos = CGPoint(x: -1, y: -1)
        lastSampleTime = -1
        lastCursorIndex = -1
        lastCursorCheck = -1
        captureRect = rect
        self.hostStart = hostStart
        running = true
        sample(force: true)

        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample(force: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordClick() }
        }
        if recordShortcuts {
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.recordKey(event) }
            }
        }
    }

    func updateRect(_ rect: CGRect) { captureRect = rect }

    /// Current track and cursor images without stopping (for crash-safe progress saving).
    func snapshot() -> (CursorTrack, [Data]) { (track, imagePNGs) }

    private func recordKey(_ event: NSEvent) {
        guard running else { return }
        let t = now
        guard t >= 0, let label = KeyShortcuts.label(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                                      flags: event.modifierFlags) else { return }
        if track.keys == nil { track.keys = [] }
        track.keys?.append(KeyEvent(t: t, label: label))
    }

    func stop() -> (CursorTrack, [Data]) {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        running = false
        timer?.invalidate()
        timer = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        return (track, imagePNGs)
    }

    /// Recording time now, or -1 while paused.
    private var now: Double {
        let host = CACurrentMediaTime()
        guard let gate = pauseGate else { return host - hostStart }
        guard let adjusted = gate.adjust(host) else { return -1 }
        return adjusted - hostStart
    }

    private func normalizedMouse() -> CGPoint {
        let loc = NSEvent.mouseLocation  // Cocoa global coordinates, origin bottom-left of primary screen
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cg = CGPoint(x: loc.x, y: primaryHeight - loc.y)
        guard captureRect.width > 0, captureRect.height > 0 else { return .zero }
        return CGPoint(x: (cg.x - captureRect.minX) / captureRect.width,
                       y: (cg.y - captureRect.minY) / captureRect.height)
    }

    private func sample(force: Bool) {
        guard running else { return }
        let t = now
        if t < 0 { return }
        let p = normalizedMouse()

        // Checking the cursor image is more expensive, so do it at ~30 Hz.
        if force || t - lastCursorCheck >= 1.0 / 30.0 {
            lastCursorCheck = t
            lastCursorIndex = currentCursorIndex()
        }

        let moved = abs(p.x - lastPos.x) > 0.00005 || abs(p.y - lastPos.y) > 0.00005
        let changedShape = !track.samples.isEmpty && track.samples.last!.c != lastCursorIndex
        if force || moved || changedShape || t - lastSampleTime > 0.5 {
            // After an idle period, anchor the old position right before the movement
            // so interpolation doesn't spread the motion over the idle gap.
            if moved, let last = track.samples.last, t - last.t > 1.0 / 60.0 {
                track.samples.append(CursorSample(t: t - 1.0 / 120.0, x: last.x, y: last.y, c: last.c))
            }
            track.samples.append(CursorSample(t: t, x: p.x, y: p.y, c: lastCursorIndex))
            lastPos = p
            lastSampleTime = t
        }
    }

    private func recordClick() {
        guard running else { return }
        let t = now
        guard t >= 0 else { return }
        let p = normalizedMouse()
        track.clicks.append(ClickEvent(t: t, x: p.x, y: p.y))
    }

    /// Drops clicks after `t` (e.g. clicks on the stop button).
    func dropClicks(after t: Double) {
        track.clicks.removeAll { $0.t > t }
    }

    private func currentCursorIndex() -> Int {
        guard let cursor = NSCursor.currentSystem else { return lastCursorIndex }
        let image = cursor.image
        guard let tiff = image.tiffRepresentation else { return lastCursorIndex }
        if let idx = imageKeys[tiff] { return idx }
        guard let rep = NSBitmapImageRep(data: tiff),
              let best = bestRepresentation(of: image) ?? rep.cgImage,
              let png = NSBitmapImageRep(cgImage: best).representation(using: .png, properties: [:]) else {
            return lastCursorIndex
        }
        let idx = track.images.count
        track.images.append(CursorImageInfo(file: "cursors/cursor-\(idx).png",
                                            width: image.size.width, height: image.size.height,
                                            hotX: cursor.hotSpot.x, hotY: cursor.hotSpot.y))
        imagePNGs.append(png)
        imageKeys[tiff] = idx
        return idx
    }

    /// Picks the highest resolution bitmap of the cursor image.
    private func bestRepresentation(of image: NSImage) -> CGImage? {
        var best: CGImage?
        for rep in image.representations {
            var rect = CGRect(origin: .zero, size: image.size)
            if let cg = rep.cgImage(forProposedRect: &rect, context: nil, hints: nil),
               cg.width > (best?.width ?? 0) {
                best = cg
            }
        }
        if best == nil {
            var rect = CGRect(origin: .zero, size: CGSize(width: image.size.width * 2, height: image.size.height * 2))
            best = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return best
    }
}
