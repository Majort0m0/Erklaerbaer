import Foundation
import AVFoundation
import CoreImage
import AppKit
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// Selftests for the clip timeline (closed gaps, moved parts, ripple trim), clips tied to the
/// video or free, music across joins, and moving projects.
enum ClipTimelineTest {
    private static func fail(_ m: String) -> NSError {
        NSError(domain: "selftest", code: 97, userInfo: [NSLocalizedDescriptionKey: m])
    }

    static func run(base: Project, dir: URL) async throws {
        try await MainActor.run { try modelTest(base) }
        try await compositionTest(base, dir)
        try mockupTest(base)
        try locationTest(base, dir)
        try await MainActor.run { try toolbarTest(base) }
        try motionTest(base, dir)
        try touchTest(base)
        try markingEdgeTest(base)
        try await liveTest(dir)
        try await memeTest(base, dir)
        try await improvementTest(base, dir)
        try await deviceWriterTest(dir)
    }

    private static func project(_ base: Project, _ change: (inout EditSettings) -> Void) -> Project {
        var s = EditSettings()
        s.removeEcho = false
        s.zoomSegments = []
        change(&s)
        return Project(url: base.url, info: base.info, cursor: base.cursor, settings: s)
    }

    private static func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) < tolerance }

    @MainActor
    private static func modelTest(_ base: Project) throws {
        let d = base.info.duration
        guard d >= 3.9 else { print("– clip timeline skipped (short test video)"); return }
        let editor = EditorModel(project: project(base) { s in
            s.cuts = [CutRange(start: 1, end: 2)]
            s.splits = [3]
            s.masks = [BlurMask(start: 2.5, end: 3.5)]
        })
        // The removed second is gone from the timeline.
        guard editor.clipParts.map(\.range) == [0...1, 2...3, 3...d], near(editor.timeMap.total, d - 1), near(editor.display(2.5), 1.5),
              !editor.timeMap.contains(source: 1.5), near(editor.outputTime, 0), near(editor.outputDuration, d - 1) else {
            throw fail("closed gap: \(editor.clipParts.map(\.range)), total \(editor.timeMap.total)")
        }
        // A text tied to the video and a free one.
        var tied = TextOverlay(kind: .lowerThird, start: 3.2, end: 3.6, title: "tied")
        tied.id = UUID()
        var free = TextOverlay(kind: .lowerThird, start: 1.0, end: 1.5, title: "free")
        free.free = true
        editor.settings.texts = [tied, free]
        // Last part to the front: its text comes along, the free one stays, the mask is split.
        editor.moveClip(key: 3, to: 0)
        guard editor.clipParts.map(\.range) == [3...d, 0...1, 2...3], near(editor.sourceTime(0), 3), near(editor.display(0.5), d - 3 + 0.5) else {
            throw fail("moved part: \(editor.clipParts.map(\.range))")
        }
        guard near(editor.displayRun(3.2, 3.6)?.lowerBound ?? -1, 0.2), editor.settings.masks.count == 2,
              editor.displayRange(start: 1.0, end: 1.5, free: true) == 1.0...1.5 else {
            throw fail("anchored items: run \(String(describing: editor.displayRun(3.2, 3.6))), masks \(editor.settings.masks.count)")
        }
        // A split in the moved order keeps the new piece next to its neighbor.
        editor.settings.splits.append(3.5)
        guard editor.clipParts.map(\.range.lowerBound) == [3, 3.5, 0, 2] else { throw fail("split after a move: \(editor.clipParts.map(\.range))") }
        editor.settings.splits.removeAll { $0 == 3.5 }
        editor.undo()
        guard editor.settings.clipOrder == nil, editor.settings.masks.count == 1 else { throw fail("undo of a move: \(String(describing: editor.settings.clipOrder))") }

        // Ripple trim: the right edge of the first part back into material, and out again.
        editor.settings.texts = []
        editor.settings.cuts = []
        editor.settings.masks = []
        let first = editor.clipParts[0]
        editor.dragEdge(of: first, isStart: false, dt: -0.5)
        editor.dragEdge(of: first, isStart: false, dt: -0.8)
        editor.endInteraction()
        guard editor.settings.cuts.count == 1, near(editor.settings.cuts[0].start, 2.2, 1e-3), near(editor.settings.cuts[0].end, 3, 1e-3),
              near(editor.timeMap.total, d - 0.8, 1e-3) else { throw fail("ripple trim: \(editor.settings.cuts)") }
        let shorter = editor.clipParts[0]
        editor.dragEdge(of: shorter, isStart: false, dt: 2)
        editor.endInteraction()
        guard editor.settings.cuts.isEmpty else { throw fail("ripple trim back: \(editor.settings.cuts)") }
        // The ends of the video trim it.
        editor.dragEdge(of: editor.clipParts[0], isStart: true, dt: 0.4)
        editor.endInteraction()
        guard near(editor.settings.trimStart, 0.4, 1e-3), near(editor.sourceTime(0), 0.4, 1e-3) else { throw fail("trim at the start: \(editor.settings.trimStart)") }
        // A lane made free: positions on the timeline stay, later cuts don't touch them.
        editor.settings.trimStart = 0
        editor.settings.texts = [TextOverlay(kind: .lowerThird, start: 2.5, end: 3.0, title: "t")]
        editor.setLane(.texts, free: true)
        guard let t = editor.settings.texts.first, t.isFree, near(t.start, 2.5, 1e-3) else { throw fail("free lane") }
        editor.settings.cuts = [CutRange(start: 0.5, end: 1.5)]
        guard editor.displayRange(start: t.start, end: t.end, free: t.isFree) == t.start...t.end, near(editor.settings.texts[0].start, 2.5, 1e-3) else { throw fail("free text moved") }
        editor.setLane(.texts, free: false)
        guard let tied2 = editor.settings.texts.first, !tied2.isFree, near(tied2.start, 3.5, 1e-3) else { throw fail("tied again: \(editor.settings.texts)") }
        try editingTest(base)
        try groupTest(base)
        print("✓ clip timeline: gaps close, parts move with what is anchored to them, ripple trim, undo; free clips stay put")
    }

    /// Several things selected: moved, copied and removed together.
    @MainActor
    private static func groupTest(_ base: Project) throws {
        let d = base.info.duration
        let editor = EditorModel(project: project(base) { s in
            s.masks = [BlurMask(start: 0.5, end: 1.0)]
            s.annotations = []
            s.zoomSegments = [ZoomSegment(start: 2.0, end: 3.0, scale: 1.5)]
            s.splits = [1, 2]
        })
        let mask = EditorSelection.mask(editor.settings.masks[0].id), zoom = EditorSelection.zoom(editor.settings.zoomSegments[0].id)
        editor.click(mask, adding: false)
        editor.click(zoom, adding: true)
        guard editor.multiSelection.count == 2, editor.isInGroup(mask), editor.isInGroup(zoom), editor.selection == zoom else {
            throw fail("group: \(editor.multiSelection)")
        }
        // Dragged together, kept on the timeline.
        guard editor.dragGroup(.move, dt: 0.5, item: mask) else { throw fail("group drag not taken") }
        guard near(editor.settings.masks[0].start, 1.0, 1e-3), near(editor.settings.zoomSegments[0].start, 2.5, 1e-3) else {
            throw fail("group drag: \(editor.settings.masks[0].start) \(editor.settings.zoomSegments[0].start)")
        }
        _ = editor.dragGroup(.move, dt: 100, item: mask)
        guard near(editor.settings.zoomSegments[0].end, d, 1e-3), near(editor.settings.masks[0].end - editor.settings.masks[0].start, 0.5, 1e-3) else {
            throw fail("group drag at the end: \(editor.settings.zoomSegments[0].end)")
        }
        editor.endInteraction()
        // Copied with their distance, removed in one step.
        editor.copySelection()
        editor.seek(to: 0.2)
        editor.pasteClipboard()
        guard editor.settings.masks.count == 2, editor.settings.zoomSegments.count == 2, editor.multiSelection.count == 2 else { throw fail("group paste") }
        let before = editor.settings.masks.count + editor.settings.zoomSegments.count
        editor.deleteSelection()
        guard editor.settings.masks.count + editor.settings.zoomSegments.count == before - 2, editor.multiSelection.isEmpty, editor.selection == nil else { throw fail("group delete") }
        editor.undo()
        guard editor.settings.masks.count + editor.settings.zoomSegments.count == before else { throw fail("group undo") }
        // ⇧-click takes one out again; a normal click on something else ends the group.
        editor.selection = nil
        editor.click(mask, adding: true)
        editor.click(zoom, adding: true)
        guard editor.multiSelection.count == 2 else { throw fail("group again: \(editor.multiSelection)") }
        editor.click(zoom, adding: true)
        guard editor.multiSelection.isEmpty, editor.selection == mask else { throw fail("group: taking out") }
        editor.click(zoom, adding: true)
        editor.click(.segment(0), adding: false)
        guard editor.multiSelection.isEmpty else { throw fail("group: ended by a click") }
        // Parts moved together keep their order.
        editor.selection = nil
        editor.click(.segment(0), adding: true)
        editor.click(.segment(1), adding: true)
        editor.moveClip(key: 0, to: 1)
        guard editor.clipParts.map(\.key) == [2, 0, 1] else { throw fail("parts moved together: \(editor.clipParts.map(\.key))") }
        print("✓ several things selected: moved, copied and removed together, ⇧-click adds and takes out, parts move as a group")
    }

    /// Music as clips, sound separated from the video, copy and paste.
    @MainActor
    private static func editingTest(_ base: Project) throws {
        let d = base.info.duration
        let editor = EditorModel(project: project(base) { s in
            s.music = BackgroundMusic(file: "media/x.m4a", name: "x")
            s.cuts = [CutRange(start: 1, end: 2)]
        })
        // 2.5 s file looped over the 3 s timeline, cut at 1 s.
        editor.waveforms["music:media/x.m4a"] = [Float](repeating: 0.1, count: Int(2.5 * Waveform.rate))
        editor.splitMusic(atTimeline: 1)
        let clips = editor.settings.voiceOvers.filter(\.isMusic).sorted { $0.start < $1.start }
        guard editor.settings.music?.clipped == true, clips.count == 3, clips.allSatisfy(\.isFree), near(clips[0].duration, 1, 0.02),
              near(clips[1].start, 1, 0.02), near(clips[1].fileOffset, 1, 0.02), near(clips[2].start, 2.5, 0.02), near(clips[2].fileOffset, 0, 0.02),
              case .voiceOver = editor.selection else {
            throw fail("music clips: \(clips.map { ($0.start, $0.duration, $0.fileOffset) })")
        }
        // The last clip gone: the lane stays empty until all are gone.
        for c in clips { editor.selection = .voiceOver(c.id); editor.deleteSelection() }
        guard editor.settings.music == nil, !editor.audioLanes.contains(.music) else { throw fail("empty music lane") }
        // Copy and paste keep the length, at the playhead.
        editor.settings.masks = [BlurMask(start: 0.2, end: 0.7)]
        editor.selection = .mask(editor.settings.masks[0].id)
        editor.copySelection()
        editor.seek(to: 2.5)
        editor.pasteClipboard()
        guard editor.settings.masks.count == 2, let m = editor.settings.masks.last, near(m.start, 2.5, 1e-3), near(m.end, 3.0, 1e-3) else {
            throw fail("paste: \(editor.settings.masks)")
        }
        // Sound separated from a video with one sound track.
        var info = base.info
        info.audioTracks = ["mic"]
        info.hasMicrophone = true
        let own = EditorModel(project: Project(url: base.url, info: info, cursor: base.cursor, settings: project(base) { $0.cuts = [CutRange(start: 1, end: 2)] }.settings))
        guard own.canDetachSound(.mic) else { throw fail("can't detach") }
        own.detachSound(.mic)
        guard own.settings.micMuted, own.settings.voiceOvers.count == 2, own.settings.voiceOvers.allSatisfy(\.isFree),
              near(own.settings.voiceOvers[1].start, 1), near(own.settings.voiceOvers[1].fileOffset, 2), near(own.settings.voiceOvers[1].duration, d - 2),
              !own.canDetachSound(.mic) else { throw fail("detached sound: \(own.settings.voiceOvers)") }
        // A locked lane is remembered.
        own.toggleLock("zoom")
        guard own.isLocked("zoom") else { throw fail("lock") }
    }

    private static func compositionTest(_ base: Project, _ dir: URL) async throws {
        let d = base.info.duration
        guard d >= 3.9 else { return }
        // Continuous music file, one voice-over tied to the video and one free.
        let music = "voiceover/selftest-music.caf"
        let url = base.url.appendingPathComponent(music)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let count = 48_000 * Int(d + 2)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count { samples[i] = Float(0.2 * sin(2 * Double.pi * 300 * Double(i) / 48_000)) }
        try EchoCanceller.writeCAF(samples, to: url)
        let tied = VoiceOverClip(file: music, fileOffset: 0, start: 0.5, duration: 1.5)
        var free = VoiceOverClip(file: music, fileOffset: 0, start: 2.5, duration: 1.0)
        free.free = true
        let p = project(base) { s in
            s.cuts = [CutRange(start: 1, end: 2)]
            s.splits = [3]
            s.clipOrder = [3, 0, 2]
            s.voiceOvers = [tied, free]
            s.music = BackgroundMusic(file: music, name: "m")
        }
        // Built like the preview (no segments given): holds the edited timeline only.
        let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30)
        let total = p.settings.outputDuration(duration: d)
        guard near(media.totalDuration, total, 0.03), near(media.recordingOffset, 0, 1e-6),
              near(media.compTime(ofSource: 3.5) ?? -1, 0.5, 0.01), near(media.compTime(ofSource: 0.5) ?? -1, d - 3 + 0.5, 0.01) else {
            throw fail("preview composition: \(media.totalDuration) for \(total), 3.5 s at \(String(describing: media.compTime(ofSource: 3.5)))")
        }
        // Tied: only 0.5–1.0 remains, and it moved with its part. Free: where it was put.
        let shift = d - 3
        let linked = media.voiceOverClips.filter { $0.parent == tied.id }
        guard linked.count == 1, near(linked[0].start, shift + 0.5, 0.01), near(linked[0].duration, 0.5, 0.01),
              let placed = media.voiceOverClips.first(where: { $0.id == free.id }), near(placed.start, 2.5), near(placed.duration, 1.0) else {
            throw fail("voice-overs: \(media.voiceOverClips.map { ($0.start, $0.duration) })")
        }
        // The music runs through the joins without a jump in the file.
        guard let track = media.audioTracks.first(where: { $0.role == AudioLane.music.role })?.track else { throw fail("no music track") }
        let segments = try await track.load(.segments).filter { !$0.isEmpty }
        for (a, b) in zip(segments, segments.dropFirst()) {
            guard near(a.timeMapping.source.end.seconds, b.timeMapping.source.start.seconds, 0.002),
                  near(a.timeMapping.target.end.seconds, b.timeMapping.target.start.seconds, 0.002) else {
                throw fail("music jumps: \(a.timeMapping.source.end.seconds) → \(b.timeMapping.source.start.seconds)")
            }
        }
        guard let first = segments.first, near(first.timeMapping.target.start.seconds, 0, 0.002), near(first.timeMapping.source.start.seconds, 0, 0.002) else {
            throw fail("music start")
        }
        try await transitionTest(base)
        // Music as clips goes to its own lane, not the voice-over lane; the running file is off.
        var cutMusic = VoiceOverClip(file: music, fileOffset: 0, start: 0.5, duration: 1.0)
        cutMusic.free = true
        cutMusic.music = true
        var bed = BackgroundMusic(file: music, name: "m")
        bed.clipped = true
        let q = project(base) { s in s.voiceOvers = [cutMusic]; s.music = bed }
        let clipped = try await MediaBuilder.make(project: q, renderer: FrameRenderer(project: q), fps: 30)
        let tracks = clipped.audioTracks.filter { $0.role == AudioLane.music.role }
        guard tracks.count == 1, tracks[0].layer == 0, !clipped.audioTracks.contains(where: { $0.role == AudioLane.voiceOver.role }),
              clipped.audioMix(settings: q.settings) != nil else { throw fail("music clip lane: \(clipped.audioTracks.map(\.role))") }
        let placedMusic = try await tracks[0].track.load(.segments).filter { !$0.isEmpty }
        guard placedMusic.count == 1, near(placedMusic[0].timeMapping.target.start.seconds, 0.5, 0.002), near(placedMusic[0].timeMapping.target.duration.seconds, 1, 0.002) else {
            throw fail("music clip placed: \(placedMusic.map(\.timeMapping.target.start.seconds))")
        }
        print("✓ preview and export hold the edited timeline; the music runs through the joins; tied voice-overs are cut and move along, free ones stay")
    }

    /// Transitions at any join: between parts, after a move, and between inserted clips.
    private static func transitionTest(_ base: Project) async throws {
        let d = base.info.duration
        func midFrame(_ p: Project, at t: Double) async throws -> (MediaComposition, CGImage) {
            let media = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30)
            let gen = AVAssetImageGenerator(asset: media.asset)
            gen.videoComposition = media.videoComposition
            gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            return (media, try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image)
        }
        // A join without a cut: the video gets shorter by the transition.
        let split = project(base) { s in
            s.splits = [2]
            s.joinTransitions = [JoinTransition(key: 2, length: 0.4)]
        }
        let (a, _) = try await midFrame(split, at: 1.8)
        guard a.dissolves.count == 1, near(a.dissolves[0].start, 1.6, 0.01), near(a.totalDuration, d - 0.4, 0.03),
              split.settings.clipParts(duration: d).map(\.key) == [0, 2] else {
            throw fail("join transition: \(a.dissolves.count), \(a.totalDuration)")
        }
        // Moved parts: a transition at their new join; the one at the old cut is gone and gives back its seconds.
        let moved = project(base) { s in
            s.cuts = [CutRange(start: 1, end: 1.5, dissolve: 0.3)]
            s.splits = [3]
            s.clipOrder = [3, 1.5, 0]
            s.joinTransitions = [JoinTransition(key: 0, length: 0.25, style: .push)]
        }
        let (b, _) = try await midFrame(moved, at: (d - 3) - 0.1)
        let parts = moved.settings.clipParts(duration: d)
        guard b.dissolves.count == 1, b.dissolves[0].style == .push, near(parts[1].range.lowerBound, 1.5, 1e-6), near(b.totalDuration, d - 0.5 - 0.25, 0.03) else {
            throw fail("transition after a move: \(b.dissolves.count), \(parts.map(\.range)), \(b.totalDuration)")
        }
        // Between two inserted clips.
        let clipA = InsertClip(file: base.info.videoFile, name: "A", at: 1.0, duration: 1.5, fileDuration: d)
        let clipB = InsertClip(file: base.info.videoFile, name: "B", at: 1.001, duration: 1.5, fileDuration: d)
        let clips = project(base) { s in
            s.inserts = [clipA, clipB]
            s.trimStart = 0.999
            s.trimEnd = 1.001
            s.joinTransitions = [JoinTransition(key: 1.0, length: 0.5)]
        }
        let (c, frame) = try await midFrame(clips, at: 1.25)
        guard c.dissolves.count == 1, c.dissolves[0].bSlices.first?.insertID == clipB.id, near(c.totalDuration, 2.5, 0.03), frame.width > 0 else {
            throw fail("transition between clips: \(c.dissolves.count), \(c.totalDuration)")
        }
    }

    /// Every scene: the video lies on the screen, the scene around it, in landscape and portrait.
    private static func mockupTest(_ base: Project) throws {
        let aspect = CGFloat(base.info.pixelWidth) / CGFloat(base.info.pixelHeight)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: base.info.pixelWidth, height: base.info.pixelHeight))
        let context = CIContext()
        func pixel(_ image: CIImage, _ p: CGPoint) -> (Float, Float, Float) {
            var px = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: p.x, y: p.y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return (px[0], px[1], px[2])
        }
        for kind in MockupKind.allCases {
            for format in [OutputAspect.wide, .vertical, .square] {
                let p = project(base) { s in
                    s.mockup = kind
                    s.aspect = format
                    s.exportShortSide = 720
                    s.showCursor = false
                    s.clickEffect = false
                }
                let r = FrameRenderer(project: p)
                let out = r.outputSize
                let screen = kind.screen(out: out, aspect: aspect)
                let inside = CGRect(origin: .zero, size: out).contains(screen)
                let shape = kind == .tablet ? (aspect >= 1 ? 4.0 / 3.0 : 3.0 / 4.0) : Double(aspect)
                let centered = abs(screen.midY / out.height - 0.5) < 0.09 && abs(screen.midX / out.width - 0.5) < 0.01
                let large = screen.width > out.width * 0.6 || screen.height > out.height * 0.6
                guard inside, near(Double(screen.width / screen.height), shape, 0.01), centered, large else {
                    throw fail("scene \(kind) \(format): screen \(screen) in \(out)")
                }
                let image = r.render(source: red, camera: nil, time: 1)
                let center = pixel(image, CGPoint(x: screen.midX, y: screen.midY))
                let above = pixel(image, CGPoint(x: screen.midX, y: min(out.height - 2, screen.maxY + 3 + out.height * 0.02)))
                guard center.0 > 0.6, center.1 < 0.25, !(above.0 > 0.6 && above.1 < 0.25 && kind != .theater) else {
                    throw fail("scene \(kind) \(format): center \(center), above \(above)")
                }
                // Handles and clicks in the preview use the same place.
                let q = r.outputPoint(CGPoint(x: 0.5, y: 0.5), at: 1)
                guard near(Double(q.x), Double(screen.midX), 1), near(Double(q.y), Double(out.height - screen.midY), 1) else {
                    throw fail("scene \(kind) \(format): preview point \(q) for \(screen)")
                }
            }
        }
        // Placed by hand: the screen moves and shrinks; an enlarged video stays on the screen.
        let p = project(base) { s in
            s.mockup = .laptop
            s.aspect = .wide
            s.exportShortSide = 720
            s.showCursor = false
            s.clickEffect = false
            s.mockupPlacements["laptop|16:9"] = MockupPlacement(x: 0.1, y: -0.05, scale: 0.7, videoScale: 2, videoX: 1, videoY: 0)
        }
        let r = FrameRenderer(project: p)
        let out = r.outputSize
        let base0 = MockupKind.laptop.screen(out: out, aspect: aspect)
        let moved = MockupKind.laptop.screen(out: out, aspect: aspect, placement: p.settings.mockupPlacement)
        guard near(Double(moved.width), Double(base0.width * 0.7), 1), near(Double(moved.midX), Double(base0.midX + out.width * 0.1), 1),
              near(Double(moved.midY), Double(base0.midY - out.height * 0.05), 1) else { throw fail("scene placement: \(moved) from \(base0)") }
        let image = r.render(source: red, camera: nil, time: 1)
        let on = pixel(image, CGPoint(x: moved.midX, y: moved.midY)), bezel = pixel(image, CGPoint(x: moved.maxX + 3, y: moved.midY))
        guard on.0 > 0.6, on.1 < 0.25, bezel.0 < 0.4 else { throw fail("enlarged video: on \(on), bezel \(bezel)") }
        // Far off to one side, the screen stays in the picture.
        let far = MockupKind.cinema.screen(out: out, aspect: aspect, placement: MockupPlacement(x: 0.5, y: 0.5, scale: 1.3))
        guard CGRect(origin: .zero, size: out).contains(far) else { throw fail("screen left the picture: \(far)") }
        try logoTest(base, red: red, pixel: pixel)
        print("✓ scenes: laptop, tablet, television, theater, cinema and picture frame in landscape, portrait and square, the video on their screen")
    }

    /// The logo: in the chosen corner, on the recording and on the title cards.
    private static func logoTest(_ base: Project, red: CIImage, pixel: (CIImage, CGPoint) -> (Float, Float, Float)) throws {
        let file = "media/selftest-logo.png"
        let url = base.url.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        try CIContext().writePNGRepresentation(of: green, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        for corner in CameraCorner.allCases {
            var card = TextOverlay(kind: .titleCard, start: 0, end: 3, title: "Titel")
            card.placement = .intro
            let p = project(base) { s in
                s.exportShortSide = 720
                s.showCursor = false
                s.watermark = Watermark(file: file, corner: corner, size: 0.2, opacity: 1)
                s.texts = [card]
            }
            let r = FrameRenderer(project: p)
            let out = r.outputSize
            guard let frame = r.watermarkFrame(p.settings.watermark!, out: out) else { throw fail("logo not loaded") }
            let middle = CGPoint(x: frame.midX, y: frame.midY)
            let onLeft: Bool = frame.midX < out.width / 2
            let onBottom: Bool = frame.midY < out.height / 2
            let wantLeft: Bool = corner == .topLeft || corner == .bottomLeft
            let wantBottom: Bool = corner == .bottomLeft || corner == .bottomRight
            let wanted: CGFloat = min(out.width, out.height) * 0.2
            guard onLeft == wantLeft, onBottom == wantBottom, abs(frame.width - wanted) < 1 else { throw fail("logo \(corner): \(frame)") }
            let video = pixel(r.render(source: red, camera: nil, time: 1), middle)
            let title = pixel(r.renderCard(card, localTime: 1), middle)
            guard video.1 > 0.7, video.0 < 0.3, title.1 > 0.7, title.0 < 0.3 else { throw fail("logo \(corner): video \(video), title card \(title)") }
        }
    }

    private static func locationTest(_ base: Project, _ dir: URL) throws {
        let root = dir.appendingPathComponent("locations", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let a = root.appendingPathComponent("a", isDirectory: true), b = root.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = a.appendingPathComponent("Film.\(Project.fileExtension)", isDirectory: true)
        let copy = Project(url: source, info: base.info, cursor: base.cursor, settings: base.settings)
        try copy.saveAll()
        // Twice to the same place: the name is numbered, nothing is overwritten.
        let moved = try ProjectLocations.move(source, to: b)
        defer { ProjectLocations.forget(moved) }
        guard !FileManager.default.fileExists(atPath: source.path), (try? Project.load(from: moved)) != nil,
              ProjectLocations.known.contains(moved), ProjectLocations.destination(for: moved, in: b).lastPathComponent == "Film 2.\(Project.fileExtension)",
              Project.listProjects(in: b) == [moved] else { throw fail("move project: \(moved.path)") }
        print("✓ projects: moved to another folder, still loadable and listed, an existing name is never overwritten")
    }

    /// Gluing clips, pushing them over each other, and the commands of the toolbar.
    @MainActor
    private static func toolbarTest(_ base: Project) throws {
        let d = base.info.duration
        guard d >= 3.9 else { print("– toolbar skipped (short test video)"); return }
        func voice(_ start: Double, _ length: Double) -> VoiceOverClip {
            var c = VoiceOverClip(file: "voiceover/a.m4a", fileOffset: 0, start: start, duration: length)
            c.free = true
            return c
        }
        let glue = EditorModel(project: project(base) { $0.voiceOvers = [voice(0, 1), voice(2, 1)] })
        let savedMagnet = glue.magnet, savedSnapping = glue.snapping
        defer { glue.magnet = savedMagnet; glue.snapping = savedSnapping }
        glue.magnet = true
        let moving = glue.settings.voiceOvers[1].id
        // 0.9 s to the left would end 0.1 s away from the neighbor: it sticks to its end.
        guard let stuck = glue.magnetDelta(.move, dt: -0.9, start: 2, end: 3, id: moving, tolerance: 0.2), near(stuck, -1) else { throw fail("magnet: \(String(describing: glue.magnetDelta(.move, dt: -0.9, start: 2, end: 3, id: moving, tolerance: 0.2)))") }
        // Pushed further it is not held, so that the clips overlap.
        guard glue.magnetDelta(.move, dt: -1.5, start: 2, end: 3, id: moving, tolerance: 0.2) == nil else { throw fail("magnet holds an overlap") }
        glue.magnet = false
        guard glue.magnetDelta(.move, dt: -0.9, start: 2, end: 3, id: moving, tolerance: 0.2) == nil else { throw fail("magnet is off but holds") }
        glue.perform(.toggleMagnet)
        guard glue.magnet else { throw fail("key G") }
        // Items that are not clips of a file have no neighbors.
        guard glue.laneNeighbours(of: UUID()).isEmpty else { throw fail("magnet on other items") }

        // A part pushed onto its neighbor dissolves; dragged past the middle it moves.
        let editor = EditorModel(project: project(base) { s in s.splits = [1.5] })
        let parts = editor.clipParts
        guard parts.count == 2 else { throw fail("two parts: \(parts.count)") }
        let slip = EditorModel.ClipDrag(key: parts[1].key, dt: -0.1)
        guard editor.clipDragOverlap(slip, minimum: 0.15) == nil else { throw fail("a slip of the mouse dissolves") }
        let push = EditorModel.ClipDrag(key: parts[1].key, dt: -0.6)
        guard let overlap = editor.clipDragOverlap(push, minimum: 0.15), near(overlap.length, 0.6), overlap.before.key == parts[1].key else { throw fail("no overlap when pushing") }
        editor.finishClipDrag(push, minimum: 0.15)
        guard let join = editor.joinTransition(key: parts[1].key), near(join.length, 0.6), editor.clipParts.map(\.key) == parts.map(\.key), editor.clipDrag == nil else {
            throw fail("pushing does not dissolve: \(editor.settings.joinTransitions)")
        }
        guard editor.canUndo else { throw fail("pushing cannot be undone") }
        editor.undo()
        guard editor.settings.joinTransitions.isEmpty else { throw fail("undo pushing") }
        let far = EditorModel.ClipDrag(key: parts[1].key, dt: -3)
        guard editor.clipDragOverlap(far, minimum: 0.15) == nil else { throw fail("far drag dissolves") }
        editor.finishClipDrag(far, minimum: 0.15)
        guard editor.clipParts.map(\.key) == [parts[1].key, parts[0].key], editor.settings.joinTransitions.isEmpty else { throw fail("far drag does not move") }

        // A removed piece between the parts: the transition belongs to the cut.
        let cutEditor = EditorModel(project: project(base) { s in s.cuts = [CutRange(start: 1, end: 2)] })
        let cutParts = cutEditor.clipParts
        cutEditor.finishClipDrag(EditorModel.ClipDrag(key: cutParts[1].key, dt: -0.4), minimum: 0.15)
        guard near(cutEditor.settings.cuts[0].dissolve, 0.4), cutEditor.settings.joinTransitions.isEmpty else { throw fail("pushing at a cut: \(cutEditor.settings.cuts)") }

        // Toolbar commands.
        let tools = EditorModel(project: project(base) { s in s.splits = [1.5] })
        tools.seek(to: 1)
        tools.perform(.addZoom); tools.perform(.addText); tools.perform(.addMask); tools.perform(.addArrow); tools.perform(.addFrame); tools.perform(.addSpotlight)
        guard !tools.settings.zoomSegments.isEmpty, !tools.settings.texts.isEmpty, !tools.settings.masks.isEmpty, tools.settings.annotations.count == 3 else {
            throw fail("add commands: zoom \(tools.settings.zoomSegments.count), text \(tools.settings.texts.count), annotations \(tools.settings.annotations.count)")
        }
        tools.perform(.transition)
        guard tools.settings.joinTransitions.count == 1, near(tools.settings.joinTransitions[0].length, 0.5) else { throw fail("transition command") }
        tools.selection = nil
        tools.seek(to: 1)
        tools.perform(.speed(1))
        guard let rate = tools.settings.speeds.first?.rate, near(rate, 1.25) else { throw fail("tempo step: \(tools.settings.speeds)") }
        tools.perform(.trimEnd)
        guard near(tools.trimEnd, 1, 0.05) else { throw fail("trim end: \(tools.trimEnd)") }
        print("✓ timeline: clips glue at their ends, pushed further they overlap, a pushed part dissolves, the toolbar commands work")
    }

    /// Clips over each other dissolve; drawn markings and text animations.
    private static func motionTest(_ base: Project, _ dir: URL) throws {
        // Overlap on the media lane.
        func overlay(_ start: Double, x: Double) -> VideoOverlay {
            var o = VideoOverlay(file: "a.mov", name: "a", start: start, duration: 2, fileDuration: 2)
            o.free = true
            o.x = x
            return o
        }
        let same = project(base) { $0.videoOverlays = [overlay(1, x: 0.5), overlay(0, x: 0.5)] }
        let map = same.settings.editMap(duration: base.info.duration)
        let fades = FrameRenderer.mediaDissolves(same.settings, map: map)
        let later = same.settings.videoOverlays[0].id
        guard let fade = fades[later], near(fade.fadeIn, 1), fades.count == 1 else { throw fail("overlap dissolve: \(fades)") }
        let apart = project(base) { $0.videoOverlays = [overlay(1, x: 0.2), overlay(0, x: 0.8)] }
        guard FrameRenderer.mediaDissolves(apart.settings, map: map).isEmpty else { throw fail("clips at different places dissolve") }

        // Drawn step by step, with a bent line and no change from frame to frame.
        let id = UUID()
        let strokes = Sketch.arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 900, y: 500), line: 8, handDrawn: true, seed: Sketch.seed(id))
        let again = Sketch.arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 900, y: 500), line: 8, handDrawn: true, seed: Sketch.seed(id))
        let straight = Sketch.arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 900, y: 500), line: 8, handDrawn: false, seed: 0)
        func off(_ points: [CGPoint]) -> CGFloat {
            points.map { abs(($0.y - 100) - ($0.x - 100) * 0.5) }.max() ?? 0
        }
        guard strokes.count == 3, strokes == again, off(strokes[0]) > 8, off(straight[0]) < 1 else { throw fail("sketch arrow: bend \(off(strokes[0])), straight \(off(straight[0]))") }
        for shape in AnnotationShape.allCases {
            let outline = Sketch.outline(CGRect(x: 100, y: 100, width: 600, height: 300), shape: shape, line: 8, handDrawn: true, seed: 3)
            guard outline.count == 1, outline[0].count > 40 else { throw fail("sketch frame \(shape)") }
        }

        let green = CIImage(color: CIColor(red: 0, green: 0.6, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: base.info.pixelWidth, height: base.info.pixelHeight))
        let context = CIContext()
        func pixels(_ image: CIImage) -> [UInt8] {
            let w = 320, h = 180
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / image.extent.width, y: CGFloat(h) / image.extent.height))
            context.render(scaled, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return px
        }
        /// How many pixels differ between two pictures.
        func difference(_ a: [UInt8], _ b: [UInt8]) -> Int {
            stride(from: 0, to: a.count, by: 4).filter { i in (0..<3).contains { abs(Int(a[i + $0]) - Int(b[i + $0])) > 16 } }.count
        }
        let frames = ProcessInfo.processInfo.environment["SCREENKAST_TEST_FRAMES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let frames { try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true) }
        func save(_ image: CIImage, _ name: String) throws {
            guard let frames else { return }
            try context.writePNGRepresentation(of: image, to: frames.appendingPathComponent(name + ".png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        func plain(_ change: (inout EditSettings) -> Void) -> FrameRenderer {
            FrameRenderer(project: project(base) { s in
                s.exportShortSide = 720
                s.showCursor = false
                s.clickEffect = false
                change(&s)
            })
        }
        let empty = pixels(plain { _ in }.render(source: green, camera: nil, time: 2))
        var arrow = Annotation(kind: .arrow, start: 1, end: 3)
        arrow.x = 0.2; arrow.y = 0.25; arrow.width = 0.45; arrow.height = 0.4
        var frame = Annotation(kind: .frame, start: 1, end: 3)
        frame.x = 0.25; frame.y = 0.3; frame.width = 0.5; frame.height = 0.4
        for (name, item) in [("arrow", arrow), ("frame", frame)] {
            let r = plain { $0.annotations = [item] }
            let early = difference(pixels(r.render(source: green, camera: nil, time: 1.05)), empty)
            let done = difference(pixels(r.render(source: green, camera: nil, time: 1.8)), empty)
            guard early * 2 < done, done > 50 else { throw fail("\(name) is not drawn on: \(early) of \(done)") }
            for t in [1.05, 1.2, 1.8, 2.3] { try save(r.render(source: green, camera: nil, time: t), "\(name)-\(t)") }
        }
        // Without the animation it is complete at once (after the short fade).
        var still = arrow
        still.animated = false
        let drawnAtOnce = plain { $0.annotations = [still] }
        guard difference(pixels(drawnAtOnce.render(source: green, camera: nil, time: 1.25)), pixels(drawnAtOnce.render(source: green, camera: nil, time: 2.5))) == 0 else {
            throw fail("an arrow without animation moves")
        }

        // Each animation: at the start it is not at its place yet; at rest it is the same picture.
        var text = TextOverlay(kind: .lowerThird, start: 1, end: 3, title: "Titel der Einblendung", subtitle: "Untertitel")
        text.free = true
        let rest = pixels(plain { $0.texts = [text] }.render(source: green, camera: nil, time: 2))
        let size = difference(rest, empty)
        guard size > 50 else { throw fail("text not visible") }
        for motion in TextMotion.allCases where motion != .standard {
            var t = text
            t.motionIn = motion
            t.motionOut = motion
            let r = plain { $0.texts = [t] }
            let settled = difference(pixels(r.render(source: green, camera: nil, time: 2)), rest)
            let moved = difference(pixels(r.render(source: green, camera: nil, time: 1.04)), rest)
            let leaving = difference(pixels(r.render(source: green, camera: nil, time: 2.96)), rest)
            try save(r.render(source: green, camera: nil, time: 1.12), "text-\(motion.rawValue)")
            guard settled == 0 else { throw fail("\(motion) at rest differs: \(settled)") }
            if motion == .none {
                guard moved == 0, leaving == 0 else { throw fail("none animates: \(moved), \(leaving)") }
            } else {
                guard moved * 10 > size * 3, leaving * 10 > size * 3 else { throw fail("\(motion) already in place: \(moved), \(leaving) of \(size)") }
            }
        }
        print("✓ motion: overlapping clips dissolve, arrows and frames are drawn on and hand-drawn, text animations work")
    }

    /// Finger gestures: where the fingers are during each gesture.
    private static func touchTest(_ base: Project) throws {
        let from = CGPoint(x: 100, y: 100), to = CGPoint(x: 500, y: 100)
        func pose(_ g: TouchGesture, _ age: Double, length: Double = 2, repeats: Bool = false) -> TouchPose {
            TouchAnimation.pose(g, from: from, to: to, gap: 40, age: age, length: length, repeats: repeats)
        }
        func distance(_ p: TouchPose) -> CGFloat { hypot(p.fingers[0].at.x - p.fingers[1].at.x, p.fingers[0].at.y - p.fingers[1].at.y) }
        guard pose(.tap, 0.05).fingers.first.map({ $0.alpha < 1 && $0.scale > 1 }) == true else { throw fail("tap does not arrive") }
        guard pose(.tap, 0.25).fingers.first.map({ $0.scale < 0.9 }) == true, pose(.tap, 0.33).ripples.count == 1 else { throw fail("tap does not press") }
        guard pose(.tap, 1.6).fingers.isEmpty else { throw fail("tap does not end") }
        guard pose(.tap, 1.6, length: 6, repeats: true).ripples.count == 1, pose(.tap, 1.6, length: 6).ripples.isEmpty else { throw fail("tap repeat") }
        guard pose(.doubleTap, 0.62).ripples.count == 2 else { throw fail("double tap: \(pose(.doubleTap, 0.62).ripples.count)") }
        let hold = pose(.hold, 1)
        guard hold.fingers.first.map({ $0.scale < 0.9 }) == true, let ring = hold.hold, ring > 0.3, ring < 0.8, pose(.hold, 0.05).hold == nil else { throw fail("hold") }
        let xs = stride(from: 0.2, through: 1.72, by: 0.1).map { pose(.drag, $0).fingers[0].at.x }
        guard near(Double(xs[0]), 100, 1), Double(xs.last ?? 0) > 490, zip(xs, xs.dropFirst()).allSatisfy({ $0 <= $1 }), !pose(.drag, 1).trails.isEmpty else { throw fail("drag: \(xs)") }
        guard pose(.swipe, 0.5).fingers[0].at.x > 150, pose(.swipe, 0.5).fingers.count == 1 else { throw fail("swipe") }
        guard pose(.twoFingerDrag, 1).fingers.count == 2, near(Double(distance(pose(.twoFingerDrag, 1))), 40, 0.01) else { throw fail("two fingers") }
        guard distance(pose(.pinchIn, 0.2)) > distance(pose(.pinchIn, 1.7)) * 3 else { throw fail("pinch in") }
        guard distance(pose(.pinchOut, 0.2)) * 3 < distance(pose(.pinchOut, 1.7)) else { throw fail("pinch out") }
        let turnA = pose(.rotate, 0.2), turnB = pose(.rotate, 1.7)
        guard near(Double(distance(turnA)), Double(distance(turnB)), 0.01), abs(turnA.fingers[0].at.y - turnB.fingers[0].at.y) > 100 else { throw fail("rotate") }

        // Projects from before have no gesture; a saved one comes back.
        var saved = Annotation(kind: .touch, start: 1, end: 2)
        saved.gesture = .pinchOut
        saved.look = .finger
        let old = try JSONDecoder().decode(Annotation.self, from: Data(#"{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","kind":"arrow","start":1,"end":2,"x":0.1,"y":0.1,"width":0.1,"height":0.1,"color":"red","thickness":1}"#.utf8))
        guard try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(saved)) == saved, old.touchGesture == .tap, old.touchLook == .dot else { throw fail("touch saved") }

        // Drawn on a white picture, as on the screen of an iPad.
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: base.info.pixelWidth, height: base.info.pixelHeight))
        let folder = ProcessInfo.processInfo.environment["SCREENKAST_TEST_FRAMES"].map { URL(fileURLWithPath: $0).appendingPathComponent("touch", isDirectory: true) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let context = CIContext()
        func plain(_ a: [Annotation]) -> FrameRenderer {
            FrameRenderer(project: project(base) { s in
                s.exportShortSide = 720; s.showCursor = false; s.clickEffect = false; s.padding = 0; s.cornerRadius = 0; s.shadow = 0
                s.annotations = a
            })
        }
        func grey(_ image: CIImage) -> Int {
            let w = 320, h = 180
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / image.extent.width, y: CGFloat(h) / image.extent.height))
            context.render(scaled, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return stride(from: 0, to: px.count, by: 4).filter { px[$0] < 235 }.count
        }
        let nothing = grey(plain([]).render(source: white, camera: nil, time: 0.5))
        for look in TouchLook.allCases {
            for g in TouchGesture.allCases {
                var a = Annotation(kind: .touch, start: 1, end: 3)
                a.gesture = g; a.look = look; a.color = .blue
                a.x = 0.5; a.y = 0.5; a.width = g.isPinch ? 0.16 : 0.22; a.height = 0
                let r = plain([a])
                let image = r.render(source: white, camera: nil, time: g == .tap || g == .doubleTap ? 1.34 : g == .swipe ? 1.45 : 2)
                guard grey(image) > nothing + 15 else { throw fail("\(g) \(look) is not visible: \(grey(image)) of \(nothing)") }
                if let folder {
                    try context.writePNGRepresentation(of: image, to: folder.appendingPathComponent("\(look.rawValue)-\(g.rawValue).png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                }
            }
        }
        print("✓ finger gestures: tap, double tap, hold, drag, swipe, two fingers, pinch and rotate, visible on a white screen")
    }

    /// The writer of the iPad recording: the picture keeps its size when the device is turned.
    private static func deviceWriterTest(_ dir: URL) async throws {
        guard DeviceRecorder.allowDevices() else { throw fail("devices not allowed") }
        _ = DeviceRecorder.availableDevices()
        func frame(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
            var out: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &out)
            guard let out else { throw fail("no pixel buffer") }
            CIContext().render(CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h)), to: out)
            return out
        }
        let url = dir.appendingPathComponent("device.mov")
        let writer = try DeviceMovieWriter(url: url, width: 640, height: 481, deviceAudio: true, microphone: true)
        guard writer.canvas == CGSize(width: 640, height: 480), writer.audioRoles == ["system", "mic"] else { throw fail("device canvas: \(writer.canvas), \(writer.audioRoles)") }
        try writer.start(at: CMTime(seconds: 100, preferredTimescale: 600))
        let wide = try frame(640, 480), tall = try frame(480, 640)
        var written = 0
        for i in 0..<20 {
            let t = CMTime(seconds: 100 + Double(i) / 10, preferredTimescale: 600)
            for _ in 0..<100 where !writer.append(i < 10 ? wide : tall, at: t) { try await Task.sleep(for: .milliseconds(5)) }
            written += 1
        }
        guard writer.hasFrames, !writer.append(wide, at: CMTime(seconds: 100.5, preferredTimescale: 600)) else { throw fail("device writer takes an old frame") }
        let length = try await writer.finish(end: CMTime(seconds: 103, preferredTimescale: 600))
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first, try await track.load(.naturalSize) == CGSize(width: 640, height: 480), near(length, 3, 0.01) else {
            throw fail("device movie, length \(length)")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 2.5, preferredTimescale: 600)).image
        var px = [UInt8](repeating: 0, count: 4 * 640 * 480)
        let drawn = CGContext(data: &px, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 4 * 640, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        drawn?.draw(image, in: CGRect(x: 0, y: 0, width: 640, height: 480))
        let row = 4 * 240 * 640
        let side = px[row + 4 * 10 + 1], middle = px[row + 4 * 320 + 1]
        guard side < 40, middle > 180 else { throw fail("turned device: side \(side), middle \(middle)") }
        print("✓ iPad recording: the movie keeps its size when the device is turned, frames in order, last picture stands until the end")
    }

    /// Markings that reach over the edge of the recording must not move the recording.
    private static func markingEdgeTest(_ base: Project) throws {
        let w = CGFloat(base.info.pixelWidth), h = CGFloat(base.info.pixelHeight)
        let left = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: w / 2, height: h))
        let right = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        let source = right.composited(over: left)
        let context = CIContext()
        func render(_ annotations: [Annotation], at t: Double) -> [UInt8] {
            let r = FrameRenderer(project: project(base) { s in
                s.exportShortSide = 720; s.showCursor = false; s.clickEffect = false
                s.annotations = annotations
            })
            let image = r.render(source: source, camera: nil, time: t)
            let cw = 320, ch = 180
            var px = [UInt8](repeating: 0, count: cw * ch * 4)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(cw) / image.extent.width, y: CGFloat(ch) / image.extent.height))
            context.render(scaled, toBitmap: &px, rowBytes: cw * 4, bounds: CGRect(x: 0, y: 0, width: cw, height: ch), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return px
        }
        let plain = render([], at: 2)
        // The upper left quarter is far from the marking, which sits in the lower right corner.
        func moved(_ px: [UInt8]) -> Int {
            var count = 0
            for y in 0..<90 { for x in 0..<160 {
                let i = (y * 320 + x) * 4
                if (0..<3).contains(where: { abs(Int(px[i + $0]) - Int(plain[i + $0])) > 24 }) { count += 1 }
            } }
            return count
        }
        for g in TouchGesture.allCases {
            for look in TouchLook.allCases {
                var a = Annotation(kind: .touch, start: 1, end: 3)
                a.gesture = g; a.look = look
                a.x = 0.9; a.y = 0.9; a.width = g.isPinch ? 0.12 : 0.09; a.height = 0.08
                for t in [1.4, 2.0, 2.6, 2.75] {
                    let n = moved(render([a], at: t))
                    guard n == 0 else { throw fail("\(g) \(look) moves the picture at \(t): \(n) pixels") }
                }
            }
        }
        var arrow = Annotation(kind: .arrow, start: 1, end: 3)
        arrow.x = 0.8; arrow.y = 0.8; arrow.width = 0.2; arrow.height = 0.2
        guard moved(render([arrow], at: 2)) == 0 else { throw fail("an arrow at the edge moves the picture") }
        print("✓ markings over the edge of the recording leave it where it is")
    }

    private static func colored(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ w: Int, _ h: Int) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &out)
        guard let out else { throw fail("no pixel buffer") }
        CIContext().render(CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h)), to: out)
        return out
    }

    /// The live picture: scenes, bubble, effects and memes, and that it is always the same size.
    private static func liveTest(_ dir: URL) async throws {
        let context = CIContext()
        func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> (Int, Int, Int) {
            var px = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return (Int(px[0]), Int(px[1]), Int(px[2]))
        }
        func isRed(_ p: (Int, Int, Int)) -> Bool { p.0 > 200 && p.1 < 60 && p.2 < 60 }
        func isGreen(_ p: (Int, Int, Int)) -> Bool { p.1 > 200 && p.0 < 60 && p.2 < 60 }
        func isBlue(_ p: (Int, Int, Int)) -> Bool { p.2 > 200 && p.0 < 60 && p.1 < 60 }
        let canvas = LiveCompositor.canvas
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600))
        let camera = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        var config = LiveConfig()
        config.bubble = false

        // A 4:3 source lies in the middle with bars beside it.
        var image = LiveCompositor.compose(config: config, source: source, camera: camera)
        guard image.extent == canvas, isRed(pixel(image, 960, 540)), !isRed(pixel(image, 20, 540)) else { throw fail("live source: \(pixel(image, 960, 540)), \(pixel(image, 20, 540))") }
        // Only the webcam fills everything.
        config.scene = .webcam
        image = LiveCompositor.compose(config: config, source: source, camera: camera)
        guard isGreen(pixel(image, 5, 5)), isGreen(pixel(image, 1915, 1075)) else { throw fail("live webcam") }
        // The bubble is round, in its place, and always completely in the picture.
        config.scene = .source
        config.bubble = true
        image = LiveCompositor.compose(config: config, source: source, camera: camera)
        let bubble = LiveCompositor.bubbleRect(config)
        guard isGreen(pixel(image, bubble.midX, bubble.midY)), !isGreen(pixel(image, bubble.minX + 4, bubble.minY + 4)), isRed(pixel(image, 960, 700)) else { throw fail("live bubble") }
        var corner = config
        corner.bubbleX = 1
        corner.bubbleY = 1
        guard canvas.contains(LiveCompositor.bubbleRect(corner)) else { throw fail("bubble outside") }

        // Mouse marks, also over the edge, do not change the size of the picture.
        config.bubble = false
        config.trail = true
        let far = LiveEffects(trail: [(CGPoint(x: 0.5, y: 0.5), 0.1), (CGPoint(x: 1.5, y: -0.5), 0)], clicks: [(CGPoint(x: 0.5, y: 0.5), 0.1), (CGPoint(x: 2, y: 2), 0.1)])
        image = LiveCompositor.compose(config: config, source: source, camera: nil, effects: far)
        guard image.extent == canvas else { throw fail("live effects extent") }
        let clicked = LiveCompositor.compose(config: config, source: source, camera: nil, effects: LiveEffects(clicks: [(CGPoint(x: 0.5, y: 0.5), 0.1)]))
        let ringAt = 64 * (0.45 + 1.1 * (0.1 / LiveCompositor.clickLife))
        guard !isRed(pixel(clicked, 960 + ringAt, 540)) else { throw fail("no click ring") }

        // Memes: in their corner, on every scene.
        let meme = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        config.memeSpot = .topRight
        image = LiveCompositor.compose(config: config, source: source, camera: nil, meme: (meme, 1, false))
        let spot = LiveCompositor.memeRect(config, size: meme.extent.size)
        guard isBlue(pixel(image, spot.midX, spot.midY)), spot.maxX <= canvas.maxX - 39, spot.maxY <= canvas.maxY - 39, image.extent == canvas else { throw fail("meme place: \(spot)") }
        config.scene = .webcam
        guard isBlue(pixel(LiveCompositor.compose(config: config, source: nil, camera: camera, meme: (meme, 1, false)), spot.midX, spot.midY)) else { throw fail("meme over webcam") }
        guard try JSONDecoder().decode(LiveConfig.self, from: JSONEncoder().encode(config)) == config else { throw fail("live config") }
        // Masks are mixed over time, but not across a jump to another place.
        func gray(_ value: UInt8) throws -> CVPixelBuffer {
            var out: CVPixelBuffer?
            CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_OneComponent8, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &out)
            guard let out else { throw fail("mask buffer") }
            CVPixelBufferLockBaseAddress(out, [])
            memset(CVPixelBufferGetBaseAddress(out), Int32(value), CVPixelBufferGetDataSize(out))
            CVPixelBufferUnlockBaseAddress(out, [])
            return out
        }
        func value(_ b: CVPixelBuffer) -> Int {
            CVPixelBufferLockBaseAddress(b, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
            return Int(CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)[0])
        }
        // The outline moves with the threshold: a mask value of 40 % counts as person only for a low one.
        let grey = LiveCompositor.maskImage(try gray(102))
        guard pixel(LiveCompositor.sharpened(grey, edge: 0.15), 8, 8).1 > 240, pixel(LiveCompositor.sharpened(grey, edge: 0.8), 8, 8).1 < 15 else {
            throw fail("mask threshold: \(pixel(LiveCompositor.sharpened(grey, edge: 0.15), 8, 8)), \(pixel(LiveCompositor.sharpened(grey, edge: 0.8), 8, 8))")
        }
        let smoother = MaskSmoother()
        _ = smoother.blend(try gray(0), calm: 0.5, time: 1)
        let mixed = value(smoother.blend(try gray(200), calm: 0.5, time: 1.03))
        let jumped = value(smoother.blend(try gray(200), calm: 0.5, time: 9))
        let off = value(smoother.blend(try gray(40), calm: 0, time: 9.03))
        guard abs(mixed - 100) < 25, jumped == 200, off == 40 else { throw fail("mask calming: \(mixed), \(jumped), \(off)") }
        // Where the mask is white the person stays, elsewhere the picture is behind.
        let halfMask = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 120)).composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 120)))
        let person = LiveCompositor.person(camera, mask: halfMask, background: source)
        guard person.extent == camera.extent, isGreen(pixel(person, 200, 360)), isRed(pixel(person, 1080, 360)) else { throw fail("virtual background") }

        // The engine draws pictures of the right size and records them.
        let engine = LiveEngine()
        var run = LiveConfig()
        run.scene = .source
        engine.setConfig(run)
        let red = try colored(1, 0, 0, 800, 600), green = try colored(0, 1, 0, 640, 360)
        guard let first = engine.renderForTest(source: red, camera: green), CVPixelBufferGetWidth(first) == 1920, CVPixelBufferGetHeight(first) == 1080 else { throw fail("live engine") }
        let url = dir.appendingPathComponent("live.mov")
        _ = try engine.startRecording(to: url, microphoneID: nil)
        for _ in 0..<12 {
            _ = engine.renderForTest(source: red, camera: green)
            try await Task.sleep(for: .milliseconds(40))
        }
        let length = try await engine.stopRecording()
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first, try await track.load(.naturalSize) == CGSize(width: 1920, height: 1080), length > 0.3 else { throw fail("live recording: \(length)") }
        await engine.stop()
        // In a scene the source lies on the screen of the device; the picture around it is the scene.
        var framed = LiveConfig()
        framed.bubble = false
        for kind in MockupKind.allCases {
            framed.mockup = kind
            let shot = LiveCompositor.compose(config: framed, source: source, camera: nil)
            let area = kind.screen(out: canvas.size, aspect: 800.0 / 600.0, placement: MockupPlacement())
            guard shot.extent == canvas, canvas.contains(area), area.width < canvas.width else { throw fail("live scene \(kind): \(area)") }
            guard isRed(pixel(shot, area.midX, area.midY)), !isRed(pixel(shot, 3, 3)), pixel(shot, 3, 3) != (18, 20, 26) else { throw fail("live scene \(kind): \(pixel(shot, area.midX, area.midY)), \(pixel(shot, 3, 3))") }
        }
        // The logo in its corner, only when it is switched on.
        let logoFile = dir.appendingPathComponent("logo-live.png")
        try NSBitmapImageRep(cgImage: CIContext().createCGImage(CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100)), from: CGRect(x: 0, y: 0, width: 200, height: 100))!).representation(using: .png, properties: [:])?.write(to: logoFile)
        var branded = LiveConfig()
        branded.bubble = false
        branded.logo = Watermark(file: logoFile.path, corner: .bottomLeft, size: 0.2, opacity: 1)
        let logoSpot = LiveCompositor.logoRect(branded.logo!, size: CGSize(width: 200, height: 100))
        guard !isGreen(pixel(LiveCompositor.compose(config: branded, source: source, camera: nil), logoSpot.midX, logoSpot.midY)) else { throw fail("logo shown while off") }
        branded.logoOn = true
        let withLogo = LiveCompositor.compose(config: branded, source: source, camera: nil)
        guard isGreen(pixel(withLogo, logoSpot.midX, logoSpot.midY)), logoSpot.minX < 100, logoSpot.minY < 100, withLogo.extent == canvas else { throw fail("live logo: \(logoSpot)") }
        // A shortcut appears at the bottom and is gone later.
        var shortcut = LiveConfig()
        shortcut.keys = true
        shortcut.bubble = false
        let shown = LiveCompositor.compose(config: shortcut, source: source, camera: nil, effects: LiveEffects(key: ("⌘S", 0.5)))
        let gone = LiveCompositor.compose(config: shortcut, source: source, camera: nil, effects: LiveEffects(key: ("⌘S", 5)))
        guard shown.extent == canvas, !isRed(pixel(shown, canvas.midX, 80)), isRed(pixel(gone, canvas.midX, 80)) else { throw fail("shortcut in the live picture") }
        // The drawer goes to the nearer edge, and the handle stays on the screen.
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let near_ = LiveDrawer.frames(panel: NSRect(x: 1000, y: 200, width: 400, height: 660), screen: screen, visible: screen)
        let farSide = LiveDrawer.frames(panel: NSRect(x: 40, y: 800, width: 400, height: 660), screen: screen, visible: screen)
        guard near_.atRight, near_.hidden.minX >= screen.maxX, screen.contains(near_.handle), near_.handle.maxX == screen.maxX,
              !farSide.atRight, farSide.hidden.maxX <= screen.minX, screen.contains(farSide.handle), farSide.handle.minX == screen.minX else { throw fail("drawer: \(near_), \(farSide)") }
        print("✓ live picture: scenes, bubble, mouse marks, memes and recording, always the same size")
    }

    /// The board: own files become movies, places are remembered, search answers are read.
    private static func memeTest(_ base: Project, _ dir: URL) async throws {
        let folder = dir.appendingPathComponent("memes", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func image(_ color: CGColor) -> CGImage? {
            let c = CGContext(data: nil, width: 301, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            c?.setFillColor(color)
            c?.fill(CGRect(x: 0, y: 0, width: 301, height: 200))
            return c?.makeImage()
        }
        let gif = folder.appendingPathComponent("tanz.gif")
        guard let destination = CGImageDestinationCreateWithURL(gif as CFURL, "com.compuserve.gif" as CFString, 5, nil) else { throw fail("gif") }
        for i in 0..<5 {
            guard let frame = image(CGColor(srgbRed: CGFloat(i) / 4, green: 0.5, blue: 0.2, alpha: 1)) else { throw fail("gif frame") }
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw fail("gif write") }
        let png = folder.appendingPathComponent("bild.png")
        guard let still = image(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)) else { throw fail("png") }
        try NSBitmapImageRep(cgImage: still).representation(using: .png, properties: [:])?.write(to: png)

        let store = folder.appendingPathComponent("board", isDirectory: true)
        let board = await MainActor.run { MemeBoard(folder: store) }
        await board.assign(0, file: gif, credit: "Autor – CC BY 4.0")
        await board.assign(9, file: png)
        let junk = folder.appendingPathComponent("kaputt.gif")
        try Data("kein bild".utf8).write(to: junk)
        await board.assign(4, file: junk)
        let (first, last, broken, problem, credits) = await MainActor.run { (board.slots[0], board.slots[9], board.slots[4], board.problem, board.credits) }
        guard let first, let last, broken == nil, problem != nil, credits == "Autor – CC BY 4.0" else { throw fail("meme places: \(String(describing: first)), \(String(describing: last)), \(String(describing: problem))") }
        // The GIF (1 second) plays three times, so that it is on screen long enough.
        guard near(first.duration, 3, 0.05), near(last.duration, MemeConverter.stillLength, 0.05), first.width == 300, first.title == "tanz" else { throw fail("meme lengths: \(first.duration), \(last.duration), \(first.width)") }
        var timed = first
        guard near(timed.liveLength ?? 0, 3, 0.05) else { throw fail("live length auto: \(String(describing: timed.liveLength))") }
        timed.showFor = 0
        guard timed.liveLength == nil else { throw fail("live length until pressed") }
        timed.showFor = 8
        guard timed.liveLength == 8 else { throw fail("live length set") }
        for slot in [first, last] {
            let url = await MainActor.run { board.url(of: slot) }
            let asset = AVURLAsset(url: url)
            let length = try await asset.load(.duration).seconds
            guard try await asset.loadTracks(withMediaType: .video).count == 1, near(length, slot.duration, 0.05) else { throw fail("meme movie: \(length)") }
            guard FileManager.default.fileExists(atPath: store.appendingPathComponent(slot.thumb).path) else { throw fail("meme thumbnail") }
        }
        // A photo stored sideways and a sideways movie with a note how to turn them come out upright.
        if let sideways = image(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)), let target = CGImageDestinationCreateWithURL(folder.appendingPathComponent("foto.jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(target, sideways, [kCGImagePropertyOrientation: 6] as CFDictionary)
            guard CGImageDestinationFinalize(target) else { throw fail("photo") }
            await board.assign(5, file: folder.appendingPathComponent("foto.jpg"))
            let photo = await MainActor.run { board.slots[5] }
            guard let photo, photo.height > photo.width else { throw fail("photo not upright: \(String(describing: photo))") }
        }
        let turned = folder.appendingPathComponent("gedreht.mov")
        let movie = try AVAssetWriter(outputURL: turned, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        movie.add(input)
        guard movie.startWriting() else { throw fail("turned movie") }
        movie.startSession(atSourceTime: .zero)
        let pixels = try colored(0, 1, 0, 640, 360)
        for i in 0..<8 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(i), timescale: 10))
        }
        input.markAsFinished()
        await movie.finishWriting()
        await board.assign(6, file: turned)
        let upright = await MainActor.run { board.slots[6] }
        guard let upright, upright.height > upright.width else { throw fail("turned movie: \(String(describing: upright))") }
        let file = await MainActor.run { board.url(of: upright) }
        guard let track = try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first, try await track.load(.preferredTransform).isIdentity,
              try await track.load(.naturalSize).height > track.load(.naturalSize).width else { throw fail("the turned movie still needs turning") }
        await MainActor.run { board.clear(5); board.clear(6) }

        // A picture that can be seen through stays so: live and in the finished video.
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
        ctx?.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        guard let halfImage = ctx?.makeImage() else { throw fail("transparent picture") }
        let halfFile = folder.appendingPathComponent("halb.png")
        try NSBitmapImageRep(cgImage: halfImage).representation(using: .png, properties: [:])?.write(to: halfFile)
        await board.assign(7, file: halfFile)
        guard let glass = await MainActor.run(body: { board.slots[7] }), glass.transparent == true, glass.thumb.hasSuffix(".png") else { throw fail("transparent meme") }
        let glassURL = await MainActor.run { board.url(of: glass) }
        let liveAlpha = try await Task { @MainActor () throws -> (Int, Int) in
            let item = AVPlayerItem(url: glassURL)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.play()
            var frame: CVPixelBuffer?
            for _ in 0..<150 where frame == nil {
                try await Task.sleep(for: .milliseconds(20))
                let time = output.itemTime(forHostTime: CACurrentMediaTime())
                if output.hasNewPixelBuffer(forItemTime: time) { frame = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) }
            }
            player.pause()
            guard let frame else { throw fail("no live frame of the transparent meme") }
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
            let row = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self) + CVPixelBufferGetBytesPerRow(frame) * CVPixelBufferGetHeight(frame) / 2
            let w = CVPixelBufferGetWidth(frame)
            return (Int(row[(w / 4) * 4 + 3]), Int(row[(w * 3 / 4) * 4 + 3]))
        }.value
        guard liveAlpha.0 > 200, liveAlpha.1 < 40 else { throw fail("live meme alpha: \(liveAlpha)") }
        // In the composition of the editor and the export.
        let media = base.url.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let inProject = media.appendingPathComponent("glas.mov")
        try? FileManager.default.removeItem(at: inProject)
        try FileManager.default.copyItem(at: glassURL, to: inProject)
        func picture(_ overlays: [VideoOverlay]) async throws -> CGImage {
            let p = project(base) { $0.videoOverlays = overlays; $0.showCursor = false; $0.exportShortSide = 720 }
            let built = try await MediaBuilder.make(project: p, renderer: FrameRenderer(project: p), fps: 30)
            let generator = AVAssetImageGenerator(asset: built.asset)
            generator.videoComposition = built.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
        }
        var over = VideoOverlay(file: "media/glas.mov", name: "glas", start: 1, duration: glass.duration, fileDuration: glass.duration)
        over.free = true
        over.x = 0.5; over.y = 0.5; over.width = 0.6; over.aspect = 2
        over.frame = .none
        over.shadow = false
        let without = try await picture([]), with = try await picture([over])
        func rgb(_ image: CGImage, _ fx: CGFloat) -> (Int, Int, Int) {
            var px = [UInt8](repeating: 0, count: 4)
            let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            c?.draw(image, in: CGRect(x: -fx * CGFloat(image.width), y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
            return (Int(px[0]), Int(px[1]), Int(px[2]))
        }
        // 0.35 of the width is the solid half, 0.65 the part to see through.
        let solid = rgb(with, 0.35), seeThrough = rgb(with, 0.65), behind = rgb(without, 0.65)
        guard solid.0 > 180, solid.1 < 90, solid.2 > 180, abs(seeThrough.0 - behind.0) < 30, abs(seeThrough.1 - behind.1) < 30, abs(seeThrough.2 - behind.2) < 30 else {
            throw fail("editor meme alpha: solid \(solid), through \(seeThrough), behind \(behind)")
        }
        await MainActor.run { board.clear(7) }

        let reloaded = await MainActor.run { MemeBoard(folder: store).slots[9] }
        guard reloaded == last else { throw fail("meme not remembered") }
        await MainActor.run { board.clear(0) }
        guard await MainActor.run(body: { board.slots[0] == nil }), !FileManager.default.fileExists(atPath: store.appendingPathComponent(first.file).path) else { throw fail("meme clear") }

        // Answers of the two search services.
        let openverse = Data(#"{"results":[{"title":"Katze","url":"https://a.example/k.gif","thumbnail":"https://a.example/t","license":"by-sa","license_version":"4.0","creator":"Ada","foreign_landing_url":"https://a.example/p"},{"title":"ohne Bild"}]}"#.utf8)
        let parsed = MemeSearch.parseOpenverse(openverse)
        guard parsed.count == 1, parsed[0].license == "CC BY-SA 4.0", parsed[0].credit == "Katze – Ada – CC BY-SA 4.0 – https://a.example/p" else { throw fail("openverse: \(parsed)") }
        let commons = Data(#"{"query":{"pages":{"7":{"index":2,"title":"File:Zwei.gif","imageinfo":[{"url":"https://c.example/2.gif","thumburl":"https://c.example/t2","descriptionurl":"https://c.example/p2","extmetadata":{"LicenseShortName":{"value":"CC0"}}}]},"3":{"index":1,"title":"File:Eins.gif","imageinfo":[{"url":"https://c.example/1.gif","thumburl":"https://c.example/t1","extmetadata":{"LicenseShortName":{"value":"Public domain"},"Artist":{"value":"<a href=\"x\">Bob</a>"}}}]}}}}"#.utf8)
        let pages = MemeSearch.parseCommons(commons)
        guard pages.map(\.title) == ["Eins", "Zwei"], pages[0].creator == "Bob", pages[0].license == "Public domain" else { throw fail("commons: \(pages)") }

        // In the editor a meme lands at the playhead, under its name.
        let keep = await MainActor.run { board.url(of: last) }
        let editor = await MainActor.run { EditorModel(project: project(base) { _ in }) }
        await MainActor.run { editor.addVideoOverlay(url: keep, at: 1, center: CGPoint(x: 0.5, y: 0.5), name: "Mein Meme") }
        var placed: VideoOverlay?
        for _ in 0..<250 where placed == nil {
            placed = await MainActor.run { editor.settings.videoOverlays.first }
            if placed == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        guard let o = placed else { throw fail("meme not in the editor") }
        let found = o.name == "Mein Meme" && near(o.x, 0.5) && near(o.duration, last.duration, 0.05)
        guard found else { throw fail("meme in the editor") }
        print("✓ meme board: own files and pictures become clips, places are remembered, search answers are read, memes reach the editor")
    }

    /// Clicks to markings, steps, packs, lanes, keyframes, roll, slip, library and selecting.
    private static func improvementTest(_ base: Project, _ dir: URL) async throws {
        let d = base.info.duration
        guard d >= 3.9 else { print("– improvements skipped (short test video)"); return }
        try await MainActor.run {
            // Recorded clicks become markings: close ones count once, a second run adds nothing.
            var cursor = base.cursor
            cursor.clicks = [ClickEvent(t: 1, x: 0.5, y: 0.5), ClickEvent(t: 1.2, x: 0.51, y: 0.5), ClickEvent(t: 2.5, x: 0.2, y: 0.3)]
            let clicked = EditorModel(project: Project(url: base.url, info: base.info, cursor: cursor, settings: project(base) { _ in }.settings))
            guard clicked.highlightClicks(with: .frame) == 2, clicked.highlightClicks(with: .frame) == 0, clicked.settings.annotations.count == 2 else { throw fail("click highlights: \(clicked.settings.annotations.count)") }
            guard clicked.highlightClicks(with: .touch) == 2, clicked.settings.annotations.contains(where: { $0.kind == .touch && near($0.x, 0.2) && near($0.y, 0.3) }) else { throw fail("click fingers") }

            // Steps count by their place in time.
            let steps = EditorModel(project: project(base) { s in
                s.annotations = [Annotation(kind: .step, start: 2, end: 3), Annotation(kind: .frame, start: 0, end: 3), Annotation(kind: .step, start: 1, end: 3)]
            })
            guard steps.stepNumber(steps.settings.annotations[0]) == 2, steps.stepNumber(steps.settings.annotations[2]) == 1 else { throw fail("step numbers") }

            // Selecting: everything after the playhead.
            let group = EditorModel(project: project(base) { s in
                s.masks = [BlurMask(start: 0.2, end: 0.8), BlurMask(start: 2.5, end: 3)]
                s.annotations = [Annotation(kind: .frame, start: 2.2, end: 2.8)]
            })
            group.seek(to: 2)
            group.selectRightOfPlayhead()
            let later = EditorSelection.mask(group.settings.masks[1].id), earlier = EditorSelection.mask(group.settings.masks[0].id)
            guard group.multiSelection.contains(later), group.multiSelection.contains(.annotation(group.settings.annotations[0].id)), !group.multiSelection.contains(earlier) else { throw fail("select right: \(group.multiSelection)") }
            guard group.timelineItems().contains(where: { $0.row == "mask" && $0.item == earlier }) else { throw fail("timeline items") }

            // Rolling keeps the length, at a plain join and at a cut, and the part keeps its order.
            let total: (EditorModel) -> Double = { $0.timeMap.total }
            let rolled = EditorModel(project: project(base) { $0.splits = [2] })
            let lengthBefore = total(rolled)
            rolled.rollEdge(of: rolled.clipParts[0], isStart: false, dt: 0.5)
            rolled.finishTrimDrag()
            guard near(rolled.settings.splits[0], 2.5), near(total(rolled), lengthBefore, 0.001), rolled.clipParts.count == 2 else { throw fail("roll split: \(rolled.settings.splits)") }
            let rollCut = EditorModel(project: project(base) { s in
                s.cuts = [CutRange(start: 1, end: 2)]
                s.clipOrder = [0, 2]
                s.joinTransitions = [JoinTransition(key: 2, length: 0.2)]
            })
            let cutLength = total(rollCut)
            rollCut.rollEdge(of: rollCut.clipParts[1], isStart: true, dt: 0.3)
            rollCut.finishTrimDrag()
            guard near(rollCut.settings.cuts[0].start, 1.3), near(rollCut.settings.cuts[0].end, 2.3), near(total(rollCut), cutLength, 0.001),
                  rollCut.settings.clipOrder == [0, 2.3], near(rollCut.settings.joinTransitions[0].key, 2.3) else { throw fail("roll cut: \(rollCut.settings.cuts), \(String(describing: rollCut.settings.clipOrder))") }

            // Slipping: same place, same length, another piece; it stops before a cut would vanish.
            let slipped = EditorModel(project: project(base) { $0.cuts = [CutRange(start: 0.5, end: 1), CutRange(start: 2, end: 2.5)] })
            let slipLength = total(slipped)
            let middle = slipped.clipParts[1]
            slipped.slipPart(middle, dt: -0.2)
            guard near(slipped.settings.cuts[0].end, 1.2), near(slipped.settings.cuts[1].start, 2.2), near(total(slipped), slipLength, 0.001) else { throw fail("slip: \(slipped.settings.cuts)") }
            slipped.slipPart(middle, dt: -5)
            guard near(slipped.settings.cuts[1].start, 2.4), near(slipped.settings.cuts[0].end, 1.4) else { throw fail("slip limit: \(slipped.settings.cuts)") }
            slipped.finishTrimDrag()
            guard slipped.slipOrigin == nil else { throw fail("slip origin") }
            let joined = EditorModel(project: project(base) { $0.splits = [2] })
            joined.slipPart(joined.clipParts[0], dt: 0.3)
            joined.finishTrimDrag()
            guard joined.settings.splits == [2], joined.settings.cuts.isEmpty else { throw fail("slip without room") }

            // Lanes: neighbors only on the same lane, always a free lane above.
            func overlay(_ start: Double, lane: Int?) -> VideoOverlay {
                var o = VideoOverlay(file: "a.mov", name: "a", start: start, duration: 1, fileDuration: 1)
                o.free = true
                o.lane = lane
                return o
            }
            let lanes = EditorModel(project: project(base) { $0.videoOverlays = [overlay(0, lane: nil), overlay(1, lane: 1), overlay(2, lane: nil)] })
            guard lanes.mediaRows == 3, lanes.laneNeighbours(of: lanes.settings.videoOverlays[0].id).count == 1 else { throw fail("lanes: \(lanes.mediaRows)") }
            lanes.setLane(.video(lanes.settings.videoOverlays[0].id), 9)
            guard lanes.settings.videoOverlays[0].lane == EditSettings.maxMediaLanes - 1 else { throw fail("lane limit") }

            // Keyframes: place and in between; a changed place lands on the keyframe.
            let keyed = EditorModel(project: project(base) { s in
                var o = overlay(0, lane: nil)
                o.duration = 3
                o.x = 0.2
                s.videoOverlays = [o]
            })
            let id = keyed.settings.videoOverlays[0].id
            keyed.seek(to: keyed.sourceTime(0.5))
            keyed.addKey(.video(id))
            keyed.seek(to: keyed.sourceTime(2.5))
            keyed.addKey(.video(id))
            keyed.place(.video(id), x: 0.8)
            let list = keyed.keys(.video(id))
            guard list.count == 2, near(list[0].x, 0.2), near(list[1].x, 0.8), near(keyed.settings.videoOverlays[0].x, 0.2) else { throw fail("keyframes: \(list)") }
            guard near(keyed.settings.videoOverlays[0].moved(at: 1.5).x, 0.5, 0.01), near(keyed.settings.videoOverlays[0].moved(at: 0).x, 0.2), near(keyed.settings.videoOverlays[0].moved(at: 3).x, 0.8) else { throw fail("keyframe values") }
            keyed.clearKeys(.video(id))
            guard keyed.keys(.video(id)).isEmpty, near(keyed.settings.videoOverlays[0].x, 0.8) else { throw fail("clear keyframes") }

            // The library lists a file once and uses it without another copy.
            let shelf = EditorModel(project: project(base) { _ in })
            let folder = base.url.appendingPathComponent("media", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = dir.appendingPathComponent("regal.png")
            try NSBitmapImageRep(cgImage: CIContext().createCGImage(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)), from: CGRect(x: 0, y: 0, width: 8, height: 8))!).representation(using: .png, properties: [:])?.write(to: source)
            let before = shelf.mediaLibrary.count
            shelf.addToLibrary([source])
            guard shelf.mediaLibrary.count == before + 1, let stored = shelf.mediaLibrary.first(where: { EditorModel.libraryName($0) == "regal" }), shelf.importMedia(stored) == "media/\(stored.lastPathComponent)", shelf.mediaLibrary.count == before + 1 else { throw fail("library: \(shelf.mediaLibrary)") }
            try? FileManager.default.removeItem(at: stored)
        }

        // A zoom on a fixed point goes there, whatever the mouse does; the frame and the strength belong together.
        try await MainActor.run {
            var fixed = ZoomSegment(start: 1, end: 3, scale: 2, isAuto: false)
            fixed.focusX = 0.2
            fixed.focusY = 0.3
            let zoomed = EditorModel(project: project(base) { $0.zoomSegments = [fixed] })
            let area = zoomed.renderer.zoomArea(focus: fixed.focus!, scale: 2, at: 2)
            // Near the edge the frame stays inside the recording, like the camera.
            guard near(Double(area.midX), max(0.2, Double(area.width) / 2), 0.001), near(Double(area.midY), max(0.3, Double(area.height) / 2), 0.001),
                  near(zoomed.renderer.zoomScale(forWidth: area.width, at: 2), 2, 0.001) else { throw fail("zoom area: \(area)") }
            zoomed.selectedZoomID = fixed.id
            zoomed.setZoomArea(fixed.id, area: CGRect(x: 0.5, y: 0.4, width: area.width * 2 / 3, height: area.height * 2 / 3))
            let set = zoomed.settings.zoomSegments[0]
            guard near(set.scale, 3, 0.01), near(set.focusX ?? 0, 0.5 + Double(area.width) / 3, 0.001) else { throw fail("zoom from frame: \(set)") }
            zoomed.setZoomFixed(fixed.id, false)
            guard zoomed.settings.zoomSegments[0].focus == nil else { throw fail("zoom back to the mouse") }
            let noMouse = EditorModel(project: Project(url: base.url, info: base.info, cursor: CursorTrack(), settings: project(base) { _ in }.settings))
            noMouse.addZoom(start: 1)
            guard noMouse.settings.zoomSegments.last?.focus == CGPoint(x: 0.5, y: 0.5), !noMouse.hasCursorData else { throw fail("zoom without a mouse") }
            guard try JSONDecoder().decode(ZoomSegment.self, from: Data(#"{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","start":1,"end":2,"scale":2,"isAuto":true}"#.utf8)).focus == nil else { throw fail("old zoom") }
        }
        // The camera of a fixed zoom: in the middle of the zoom it looks at the fixed point.
        var still = ZoomSegment(start: 0.5, end: 3.5, scale: 2, isAuto: false)
        still.focusX = 0.3
        still.focusY = 0.6
        let lens = FrameRenderer(project: project(base) { $0.zoomSegments = [still]; $0.padding = 0; $0.showCursor = false })
        let atMiddle = lens.normalizedPoint(fromOutput: CGPoint(x: lens.outputSize.width / 2, y: lens.outputSize.height / 2), at: 2)
        let expected = lens.zoomArea(focus: still.focus!, scale: 2, at: 0.5)
        guard abs(atMiddle.x - expected.midX) < 0.01, abs(atMiddle.y - expected.midY) < 0.01 else { throw fail("fixed zoom camera: \(atMiddle) vs \(expected)") }

        // A followed mask: between its points, and it moves along with the content.
        var mask = BlurMask(start: 0, end: 2)
        mask.track = [MaskPoint(t: 0, x: 0.1, y: 0.1), MaskPoint(t: 2, x: 0.5, y: 0.3)]
        guard near(Double(mask.place(at: 1).x), 0.3), near(Double(mask.place(at: 5).y), 0.3), near(Double(mask.place(at: -1).x), 0.1) else { throw fail("mask place") }
        // Keyframes set by hand, also for the size; moving the block takes them along.
        try await MainActor.run {
            let hand = EditorModel(project: project(base) { $0.masks = [BlurMask(start: 0.5, end: 3)] })
            let id = hand.settings.masks[0].id
            hand.seek(to: 1)
            hand.addMaskKey(id)
            hand.seek(to: 2)
            let shown = hand.settings.masks[0].rect(at: 2)
            hand.moveMask(id, shownAt: shown, to: CGRect(x: 0.6, y: 0.5, width: 0.2, height: 0.3))
            let m = hand.settings.masks[0]
            guard m.track?.count == 2, near(Double(m.rect(at: 1.5).minX), (0.35 + 0.6) / 2, 0.001), near(Double(m.rect(at: 1.5).width), (0.3 + 0.2) / 2, 0.001),
                  near(Double(m.rect(at: 2.5).height), 0.3, 0.001), hand.maskKey(id) != nil else { throw fail("mask keyframes: \(String(describing: m.track))") }
            hand.moveMask(id, shownAt: m.rect(at: 2), to: m.rect(at: 2).offsetBy(dx: 0.05, dy: 0), wholePath: true)
            guard near(hand.settings.masks[0].track?[0].x ?? 0, 0.4, 0.001), near(hand.settings.masks[0].track?[1].x ?? 0, 0.65, 0.001) else { throw fail("mask whole path") }
            hand.jumpMaskKey(id, forward: false)
            guard near(hand.currentTime, 1, 0.01) else { throw fail("jump to keyframe: \(hand.currentTime)") }
            let later = hand.settings.masks[0].shifted(by: 1)
            guard near(later.start, 1.5), near(later.track?[0].t ?? 0, 2) else { throw fail("mask shifted") }
            hand.removeMaskKey(id)
            guard hand.settings.masks[0].track?.count == 1 else { throw fail("remove mask keyframe") }
        }
        let moving = dir.appendingPathComponent("moving.mov")
        try? FileManager.default.removeItem(at: moving)
        let writer = try AVAssetWriter(outputURL: moving, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
        writer.add(input)
        guard writer.startWriting() else { throw fail("moving video") }
        writer.startSession(atSourceTime: .zero)
        let drawing = CIContext()
        for i in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw fail("moving pool") }
            var frame: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &frame)
            guard let frame else { throw fail("moving frame") }
            let x = 100 + CGFloat(i) * 5
            let box = CIImage(color: CIColor(red: 1, green: 0.8, blue: 0)).cropped(to: CGRect(x: x, y: 140, width: 80, height: 80))
            let cross = CIImage(color: .blue).cropped(to: CGRect(x: x + 30, y: 150, width: 20, height: 60))
            drawing.render(cross.composited(over: box).composited(over: CIImage(color: CIColor(red: 0.15, green: 0.15, blue: 0.15)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))), to: frame)
            adaptor.append(frame, withPresentationTime: CMTime(value: Int64(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        var start = BlurMask(start: 0, end: 1.9)
        start.width = 80.0 / 640; start.height = 80.0 / 360
        start.x = 100.0 / 640; start.y = (360 - 220) / 360.0
        do {
            let path = try await MaskTracker.track(url: moving, mask: start)
            guard let end = path.last, path.count > 10, abs(end.x - (100 + 5 * end.t * 30) / 640) < 0.06, abs(end.y - start.y) < 0.06 else { throw fail("mask following: \(path.count), \(String(describing: path.last))") }
            print("✓ mask following: the mask stays on content that moves")
        } catch let error as NSError where error.domain != "selftest" {
            print("– mask following skipped (Vision: \(error.localizedDescription))")
        }

        // Lanes in the picture: the higher lane is on top, whatever the order in the list.
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        var upper = VideoOverlay(file: "a.mov", name: "a", start: 0.5, duration: 2, fileDuration: 2)
        upper.free = true; upper.x = 0.5; upper.y = 0.5; upper.width = 0.4; upper.lane = 1; upper.shadow = false; upper.frame = .none
        var lower = upper
        lower.id = UUID()
        lower.lane = nil
        let layered = project(base) { $0.videoOverlays = [upper, lower]; $0.showCursor = false; $0.exportShortSide = 720 }
        let picture = FrameRenderer(project: layered)
        let image = picture.render(source: nil, camera: nil, time: 1.5, overlays: [upper.id: blue, lower.id: red])
        let center = picture.outputSize
        var px = [UInt8](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: center.width / 2, y: center.height / 2, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        guard px[2] > 200, px[0] < 60 else { throw fail("lanes in the picture: \(px)") }
        guard FrameRenderer.mediaDissolves(layered.settings, map: layered.settings.editMap(duration: d)).isEmpty else { throw fail("dissolve across lanes") }

        // A pack brings intro, outro and the design along; a plain style leaves them.
        var kit = project(base) { _ in }.settings
        var card = TextOverlay(kind: .titleCard, start: 0, end: 2, title: "Willkommen")
        card.placement = .intro
        kit.texts = [card]
        kit.textDesign = TextDesign()
        var target = project(base) { _ in }.settings
        var old = TextOverlay(kind: .titleCard, start: 0, end: 1, title: "Alt")
        old.placement = .intro
        target.texts = [old]
        var pack = StylePreset(name: "Paket", settings: kit)
        var plain = target
        StyleLibrary.apply(pack, to: &plain, projectURL: base.url)
        guard plain.intro?.title == "Alt" else { throw fail("plain style changed the intro") }
        pack.isPack = true
        StyleLibrary.apply(pack, to: &target, projectURL: base.url)
        guard target.intro?.title == "Willkommen", target.intro?.id != card.id, target.texts.count == 1, target.textDesign != nil else { throw fail("pack: \(target.texts.map(\.title))") }

        // Older projects open, new fields are kept.
        var saved = project(base) { $0.script = "Hallo" }.settings
        saved.cameraBackground = nil
        guard try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(saved)).script == "Hallo" else { throw fail("script not saved") }
        print("✓ editing: clicks to markings, steps, selecting, roll, slip, lanes, keyframes, library and packs")
    }
}
