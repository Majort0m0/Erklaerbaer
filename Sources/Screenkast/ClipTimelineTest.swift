import Foundation
import AVFoundation

/// Selftests for the clip timeline (closed gaps, moved parts, ripple trim), clips tied to the
/// video or free, music across joins, and moving projects.
enum ClipTimelineTest {
    private static func fail(_ m: String) -> NSError {
        NSError(domain: "selftest", code: 97, userInfo: [NSLocalizedDescriptionKey: m])
    }

    static func run(base: Project, dir: URL) async throws {
        try await MainActor.run { try modelTest(base) }
        try await compositionTest(base, dir)
        try locationTest(base, dir)
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
}
