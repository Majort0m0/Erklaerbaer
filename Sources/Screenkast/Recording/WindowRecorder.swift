import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation
import ApplicationServices

/// Records a second window while the screen is recorded (picture in picture in the editor). The
/// movie's timeline starts at the first screen frame, like the camera, so both line up 1:1.
final class WindowRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "screenkast.window2", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private var startTime: CMTime = .invalid
    private var lastPTS: CMTime = .invalid
    private var lastFrame: CMSampleBuffer?
    private var preStart: CMSampleBuffer?
    private(set) var size: CGSize = .zero
    var pauseGate: PauseGate?

    /// Starts capturing `window` into `url`; frames before `start` (host time) are dropped.
    func start(window: SCWindow, url: URL, start: CMTime) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Double(filter.pointPixelScale)
        // At most 1920 pixels wide: it is shown smaller than the main recording anyway.
        let k = min(1, 1920 / max(1, filter.contentRect.width * scale))
        let width = max(64, Int((filter.contentRect.width * scale * k / 2).rounded()) * 2)
        let height = max(64, Int((filter.contentRect.height * scale * k / 2).rounded()) * 2)
        size = CGSize(width: width, height: height)
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.ignoreShadowsSingleWindow = true
        config.queueDepth = 5

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        RecordingRecovery.prepare(writer)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: RecordingRecovery.keyFrameProperties(fps: 30).merging([
                AVVideoAverageBitRateKey: min(20_000_000, max(3_000_000, width * height * 3)),
            ]) { a, _ in a },
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.writerFailed("Fenster-Spur") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecorderError.writerFailed("Fenster-Spur") }
        writer.startSession(atSourceTime: start)
        queue.sync {
            self.writer = writer
            self.input = input
            self.startTime = start
            self.started = false
            self.lastPTS = .invalid
            self.lastFrame = nil
            self.preStart = nil
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    /// Finishes the movie at `end` (host time). Returns false if nothing usable was written.
    func stop(end: CMTime) async -> Bool {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        return await withCheckedContinuation { cont in
            queue.async {
                // A window that never changed after the start still gets its picture.
                if !self.started, let pre = self.preStart, let input = self.input, let first = Self.retimed(pre, to: self.startTime),
                   input.isReadyForMoreMediaData, input.append(first) {
                    self.started = true
                    self.lastPTS = self.startTime
                    self.lastFrame = first
                }
                guard let writer = self.writer, self.started else {
                    self.writer?.cancelWriting()
                    self.writer = nil
                    cont.resume(returning: false)
                    return
                }
                // The window may not have changed for a while: repeat the last frame at the end.
                if let last = self.lastFrame, let input = self.input, CMTimeCompare(end, self.lastPTS) > 0,
                   let copy = Self.retimed(last, to: CMTimeSubtract(end, CMTime(value: 1, timescale: 30))), input.isReadyForMoreMediaData,
                   CMTimeCompare(copy.presentationTimeStamp, self.lastPTS) > 0 {
                    input.append(copy)
                }
                self.input?.markAsFinished()
                writer.endSession(atSourceTime: CMTimeMaximum(end, self.lastPTS))
                writer.finishWriting {
                    self.writer = nil
                    cont.resume(returning: writer.status == .completed)
                }
            }
        }
    }

    func cancel() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        queue.sync {
            writer?.cancelWriting()
            writer = nil
        }
    }

    private static func retimed(_ sb: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer raw: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, raw.isValid, let input,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(raw, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = (attachments.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)), status == .complete else { return }
        var sb = raw
        if let gate = pauseGate {
            guard let shifted = gate.retime(raw) else { return }
            sb = shifted
        }
        let pts = sb.presentationTimeStamp
        if !started {
            // Frames before the screen's first frame: keep the newest, it shows the window at the start.
            if CMTimeCompare(pts, startTime) < 0 { preStart = sb; return }
            // The movie starts with a picture (the window changes only now and then).
            if CMTimeCompare(pts, startTime) > 0, let first = Self.retimed(preStart ?? sb, to: startTime), input.isReadyForMoreMediaData,
               input.append(first) {
                lastPTS = startTime
            }
            preStart = nil
            started = true
        }
        guard !lastPTS.isValid || CMTimeCompare(pts, lastPTS) > 0, input.isReadyForMoreMediaData else { return }
        if input.append(sb) {
            lastPTS = pts
            lastFrame = sb
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {}
}

/// Brings a window to the front: activates its app (in Stage Manager that brings its stage to the
/// center) and, with the accessibility permission, raises exactly this window.
enum WindowFocus {
    @MainActor
    static func bringToFront(_ window: SCWindow) {
        guard let pid = window.owningApplication?.processID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.unhide()
        app.activate(options: [.activateAllWindows])
        guard AXIsProcessTrusted() else { return }
        let axApp = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        func title(_ w: AXUIElement) -> String? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &v) == .success ? v as? String : nil
        }
        func size(_ w: AXUIElement) -> CGSize? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &v) == .success, let v,
                  CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
            var s = CGSize.zero
            return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
        }
        // Same title, closest size (several windows of an app can share a title).
        let candidates = windows.filter { title($0) == window.title }
        let target = candidates.min { a, b in
            let sa = size(a) ?? .zero, sb = size(b) ?? .zero
            return abs(sa.width - window.frame.width) + abs(sa.height - window.frame.height)
                < abs(sb.width - window.frame.width) + abs(sb.height - window.frame.height)
        } ?? windows.first
        guard let target else { return }
        AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
}
