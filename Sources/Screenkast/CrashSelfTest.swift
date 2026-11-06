import Foundation
import AVFoundation
import AppKit

/// Crash safety test (part of `--selftest`): a child process records a synthetic recording
/// with the crash-safe writer and progress saving, then kills itself mid-recording.
/// The parent recovers the folder and checks that a usable project comes out.
enum CrashSelfTest {
    static let killAfter = 4.0   // the synthetic video is sparse from 1 to 3 s, dense afterwards

    static func run(dir: URL) async throws {
        func fail(_ message: String) -> NSError {
            NSError(domain: "selftest", code: 30, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let library = dir.appendingPathComponent("crash-library", isDirectory: true)
        try? FileManager.default.removeItem(at: library)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let folder = library.appendingPathComponent("Aufnahme Absturz.screenkast", isDirectory: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        process.arguments = ["--crashrecord", folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .uncaughtSignal, process.terminationStatus == SIGKILL else {
            throw fail("crash child ended with \(process.terminationReason.rawValue)/\(process.terminationStatus), expected SIGKILL")
        }
        // Running recordings (recently written folders) are left alone.
        guard RecordingRecovery.interruptedProjects(in: library).isEmpty else { throw fail("fresh folder treated as interrupted") }

        let result = await RecordingRecovery.recoverAll(in: library, minimumAge: 0)
        guard result.failed.isEmpty, result.recovered.count == 1 else {
            throw fail("recovery: \(result.recovered.count) recovered, \(result.failed.count) failed")
        }
        let url = result.recovered[0]
        let project = try Project.load(from: url)
        let d = project.info.duration
        guard url.lastPathComponent.contains("wiederhergestellt"),
              !FileManager.default.fileExists(atPath: url.appendingPathComponent(RecordingRecovery.progressFile).path) else {
            throw fail("recovered folder not marked / progress file left: \(url.lastPathComponent)")
        }
        guard d >= killAfter - 1.6, d <= killAfter + 0.05 else { throw fail("recovered duration \(d) s") }
        guard project.info.audioRoles == ["system", "mic"], project.info.sourceName == "Absturztest",
              project.cursor.clicks.map(\.t) == [1.0, 2.0].filter({ $0 <= d }),
              let lastSample = project.cursor.samples.last, lastSample.t <= d, lastSample.t > 1.5,
              project.cursor.images.count == 1 else {
            throw fail("recovered data (\(d) s): roles \(project.info.audioRoles), clicks \(project.cursor.clicks.map(\.t)), samples \(project.cursor.samples.count), images \(project.cursor.images.count)")
        }
        // The recovered project goes through the normal pipeline.
        let renderer = FrameRenderer(project: project)
        let media = try await MediaBuilder.make(project: project, renderer: renderer, fps: 30)
        guard media.audioTracks.map(\.role) == ["system", "mic"] else { throw fail("recovered audio roles in composition") }
        for track in media.asset.tracks {
            guard try await track.load(.segments).contains(where: { !$0.isEmpty }) else {
                throw fail("recovered composition track \(track.trackID) is empty")
            }
        }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: project.videoURL))
        _ = try await gen.image(at: CMTime(seconds: d * 0.9, preferredTimescale: 600))
        print(String(format: "✓ crash safety: killed after %.1f s, recovered %.2f s with cursor, clicks and both audio tracks", killAfter, d))
    }

    /// Child process: starts a "recording" and dies without finishing it.
    static func child(folder: URL) -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let info = RecordingInfo(pixelWidth: 640, pixelHeight: 360, pointPixelScale: 1, duration: 0, createdAt: Date(),
                                         sourceName: "Absturztest", hasMicrophone: true, cameraFile: nil,
                                         audioTracks: ["system", "mic"])
                let progress = try RecordingProgressWriter(folder: folder, info: info)
                // Cursor progress as saved during recording; a click after the crash point must be dropped.
                var track = CursorTrack()
                for i in 0...(Int(killAfter * 60) + 60) {
                    track.samples.append(CursorSample(t: Double(i) / 60, x: 0.3 + Double(i) * 0.002, y: 0.5, c: 0))
                }
                track.clicks = [ClickEvent(t: 1.0, x: 0.4, y: 0.5), ClickEvent(t: 2.0, x: 0.5, y: 0.5),
                                ClickEvent(t: killAfter + 0.5, x: 0.6, y: 0.5)]
                track.images = [CursorImageInfo(file: "cursors/cursor-0.png", width: 17, height: 23, hotX: 4, hotY: 4)]
                let png = NSBitmapImageRep(cgImage: CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                                                            space: CGColorSpaceCreateDeviceRGB(),
                                                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                                            provider: CGDataProvider(data: Data(count: 16) as CFData)!,
                                                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!)
                    .representation(using: .png, properties: [:])!
                progress.save(cursor: track, images: [png])
                progress.flush()
                try await SelfTest.writeSyntheticVideo(url: folder.appendingPathComponent("screen.mov"), width: 640, height: 360,
                                                       fps: 30, duration: killAfter + 2,
                                                       audio: [("system", 440), ("mic", 660)],
                                                       crashSafe: true, killAfter: killAfter)
            } catch {
                print("crash child failed: \(error)")
            }
            sem.signal()
        }
        sem.wait()
        return 1   // only reached if the kill did not happen
    }
}
