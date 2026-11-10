import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import Vision

/// Composes one output frame: background, shadow, rounded screen recording,
/// smoothed cursor, click rings and the zoom "camera". Used for both the
/// live preview and the export (via `AVVideoComposition`), so what you see is
/// what gets exported.
final class FrameRenderer: @unchecked Sendable {
    struct CursorSprite {
        var image: CIImage
        var pointSize: CGSize
        var hotSpot: CGPoint   // points, origin top-left
    }

    private struct State {
        var info: RecordingInfo
        var track: CursorTrack
        var settings: EditSettings
        var motion: MotionPaths
        var sprites: [CursorSprite]
        /// Source ↔ timeline time (fades and lengths are in timeline time, so items inside an
        /// inserted clip or a freeze frame fade like everywhere else).
        var map: TimeMap
    }

    private let lock = NSLock()
    private var state: State
    private var backgroundCache: (key: String, image: CIImage)?
    private var sceneCache: (key: String, image: CIImage)?
    private let rasterContext = CIContext(options: [.cacheIntermediates: false])
    private let fallbackCursor: CursorSprite
    private let ringImage: CIImage
    private let captionImages = CaptionImageCache()
    private let captionBlocks = CaptionBlockCache()
    private let textBlocks = TextBlockCache()
    /// Project folder (images, logo) and caches for pictures and arrows.
    private let projectURL: URL
    private var imageCache: [String: CIImage] = [:]
    private let maskSmoother = MaskSmoother()
    private var arrowCache: [String: CIImage] = [:]
    private var shapeCache: [String: CIImage] = [:]
    /// Frame size of each inserted clip (learned while rendering it; used by the preview handles).
    private var insertSizes: [UUID: CGSize] = [:]

    /// The project has a camera recording (side by side layout).
    let hasCamera: Bool

    init(project: Project) {
        projectURL = project.url
        hasCamera = project.cameraURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        fallbackCursor = Self.makeFallbackCursor()
        ringImage = Self.makeRingImage()
        var sprites: [CursorSprite] = []
        for info in project.cursor.images {
            let url = project.url.appendingPathComponent(info.file)
            if let img = CIImage(contentsOf: url) {
                sprites.append(CursorSprite(image: img,
                                            pointSize: CGSize(width: info.width, height: info.height),
                                            hotSpot: CGPoint(x: info.hotX, y: info.hotY)))
            } else {
                sprites.append(fallbackCursor)
            }
        }
        state = State(info: project.info,
                      track: project.cursor,
                      settings: project.settings,
                      motion: MotionPaths(track: project.cursor, duration: project.info.duration,
                                          smoothing: project.settings.cursorSmoothing),
                      sprites: sprites,
                      map: project.settings.editMap(duration: project.info.duration))
    }

    func update(settings: EditSettings) {
        lock.lock()
        let old = state.settings
        state.settings = settings
        if old.speeds != settings.speeds || old.freezes != settings.freezes || old.inserts != settings.inserts {
            state.map = settings.editMap(duration: state.info.duration)
        }
        let needsMotion = old.cursorSmoothing != settings.cursorSmoothing
        let track = state.track, duration = state.info.duration
        lock.unlock()
        if needsMotion {
            let motion = MotionPaths(track: track, duration: duration, smoothing: settings.cursorSmoothing)
            lock.lock(); state.motion = motion; lock.unlock()
        }
    }

    /// Smoothed cursor position (normalized to the capture) at source time `t`.
    func cursorPosition(at t: Double) -> CGPoint? {
        lock.lock(); defer { lock.unlock() }
        return state.motion.cursor(at: t)
    }

    var outputSize: CGSize {
        lock.lock(); defer { lock.unlock() }
        return Self.outputSize(info: state.info, settings: state.settings)
    }

    static func outputSize(info: RecordingInfo, settings: EditSettings) -> CGSize {
        OutputGeometry.size(aspect: settings.aspect, shortSide: settings.exportShortSide,
                            sourceSize: CGSize(width: info.pixelWidth, height: info.pixelHeight))
    }

    // MARK: Rendering

    /// Rotation of the main video (imported phone videos), applied to its frames.
    var sourceRotation: Int { lock.withLock { state.info.rotation ?? 0 } }

    func render(source rawSource: CIImage, time t: Double) -> CIImage {
        render(source: rawSource, camera: nil, time: t)
    }

    /// - Parameter contentAlpha: opacity of the recording (screen, cursor, camera) over the
    ///   background; used for the fade next to intro/outro title cards.
    /// - Parameter plain: an inserted clip instead of the recording (no zoom, cursor, masks, camera).
    /// - Parameter overlays: current frames of the video overlays (by overlay id).
    func render(source maybeSource: CIImage?, camera rawCamera: CIImage?, time t: Double, contentAlpha: Double = 1, plain: Bool = false,
                overlays: [UUID: CIImage] = [:]) -> CIImage {
        lock.lock()
        let st = state
        lock.unlock()
        let s = st.settings
        let out = Self.outputSize(info: st.info, settings: s)
        let outRect = CGRect(origin: .zero, size: out)
        let rawCamera = rawCamera.map { backgrounded($0, settings: s, time: t) }
        let rawSource = maybeSource ?? CIImage(color: .black)
            .cropped(to: CGRect(x: 0, y: 0, width: st.info.pixelWidth, height: st.info.pixelHeight))

        var normalized = rawSource.transformed(by: CGAffineTransform(translationX: -rawSource.extent.minX, y: -rawSource.extent.minY))
        // Masks and annotations belong to the recording or to the inserted clip they start in.
        let insert = plain ? st.map.insertID(atSource: t) : nil
        if let insert, maybeSource != nil { lock.withLock { insertSizes[insert] = normalized.extent.size } }
        if !s.color.isNeutral, plain ? s.color.applyToMedia : s.color.applyToScreen {
            normalized = Self.graded(normalized, s.color)
        }
        let camera = rawCamera.map { s.color.applyToCamera && !s.color.isNeutral ? Self.graded($0, s.color) : $0 }
        let T = st.map.timeline(t)
        let masks = s.masks.filter { st.map.insertID(atSource: $0.start) == insert }
        let annotations = s.annotations.filter { st.map.insertID(atSource: $0.start) == insert }
        let source = applyAnnotations(applyMasks(normalized, time: t, masks: masks), time: T, annotations: annotations, map: st.map)
        let camState = Self.cameraState(at: t, settings: s)
        let regions = camera != nil && !plain ? Self.splitRegions(out: out, split: camState.split) : nil
        // In a scene the video fills the screen of the device.
        let sceneArea = Self.sceneRects(s, info: st.info, out: out)
        let mockupScreen = sceneArea?.screen
        let layout = FrameLayout(out: out, sourceSize: source.extent.size, padding: sceneArea == nil ? s.padding : 0, contentY: s.contentY,
                                 region: sceneArea?.video ?? regions?.screen)
        let ref = layout.ref, pad = layout.pad, fit = layout.fit, content = layout.content
        func toOutput(_ p: CGPoint) -> CGPoint { layout.toOutput(p) }

        // Zoom camera
        let view = Self.camera(at: t, layout: layout, segments: plain ? [] : s.zoomSegments, motion: st.motion)
        let z = view.zoom
        let zoomT = view.transform

        // 1. Background
        var image = mockupScreen.flatMap { scene(s.mockup, size: out, screen: $0) } ?? background(style: s.background, blur: s.backgroundBlur, size: out)
        if z > 1.0001 { image = image.transformed(by: zoomT) }

        // An enlarged video shows only what lies on the screen of the device.
        let visibleContent = mockupScreen.map { content.intersection($0) } ?? content
        let screenRect = visibleContent.applying(zoomT)
        let radius = (mockupScreen.flatMap { s.mockup?.cornerRadius(screen: $0) } ?? s.cornerRadius * ref) * z

        // 2. Shadow
        if s.shadow > 0.01 && pad > 0.5 && mockupScreen == nil {
            let shape = roundedRect(screenRect, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35 + 0.5 * s.shadow))
            let sigma = (10 + 30 * s.shadow) * ref * z
            let shadow = shape
                .applyingGaussianBlur(sigma: sigma)
                .transformed(by: CGAffineTransform(translationX: 0, y: -(6 + 14 * s.shadow) * ref * z))
            image = shadow.composited(over: image)
        }

        // 3. Screen recording, rounded
        let screen = source.transformed(by: CGAffineTransform(scaleX: fit, y: fit)
            .concatenating(CGAffineTransform(translationX: content.minX, y: content.minY))
            .concatenating(zoomT))
        if radius > 0.5 {
            let mask = roundedRect(screenRect, radius: radius, color: .white)
            image = screen.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
                .composited(over: image)
        } else {
            image = screen.cropped(to: screenRect).composited(over: image)
        }

        // 3b. Camera motion blur while zooming/panning. Shutter: up to one frame at 60 fps.
        let shutter = 1.0 / 60 * min(1, s.motionBlur)
        if s.motionBlur > 0.01 && !plain {
            image = cameraMotionBlur(image, current: view,
                                     previous: Self.camera(at: t - shutter, layout: layout, segments: s.zoomSegments, motion: st.motion),
                                     out: out)
        }

        // Size of one captured point in output pixels.
        let pointToOut = st.info.pointPixelScale * fit * z

        // 4. Click rings (under the cursor)
        if s.clickEffect && !plain {
            for click in st.track.clicks where t >= click.t && t - click.t < 0.55 && click.isInsideCapture
                && (mockupScreen == nil || screenRect.contains(toOutput(CGPoint(x: click.x, y: click.y)).applying(zoomT))) {
                let age = (t - click.t) / 0.55
                let eased = 1 - pow(1 - age, 3)
                let r = (6 + 22 * eased) * pointToOut * max(1, s.cursorScale * 0.75)
                let pos = toOutput(st.motion.cursor(at: click.t) ?? CGPoint(x: click.x, y: click.y)).applying(zoomT)
                let ring = ringImage
                    .transformed(by: CGAffineTransform(scaleX: 2 * r / ringImage.extent.width, y: 2 * r / ringImage.extent.height))
                    .transformed(by: CGAffineTransform(translationX: pos.x - r, y: pos.y - r))
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(1 - age))])
                image = ring.composited(over: image)
            }
        }

        // 5. Cursor
        // (In a scene not where an enlarged video is cut off by the device.)
        if s.showCursor, !plain, let p = st.motion.cursor(at: t),
           p.x > -0.01, p.x < 1.01, p.y > -0.01, p.y < 1.01, mockupScreen == nil || screenRect.contains(toOutput(p).applying(zoomT)) {
            var alpha = 1.0
            if s.hideIdleCursor {
                let idle = st.track.idleTime(at: t)
                alpha = 1 - AutoZoom.smootherstep((idle - 1.5) / 0.4)
            }
            if alpha > 0.01 {
                let idx = st.track.imageIndex(at: t)
                let sprite = (idx >= 0 && idx < st.sprites.count) ? st.sprites[idx] : fallbackCursor
                var press = 1.0
                for click in st.track.clicks where t >= click.t && t - click.t < 0.3 {
                    let a = (t - click.t) / 0.3
                    press = min(press, 1 - 0.18 * sin(a * .pi))
                }
                let k = pointToOut * s.cursorScale * press
                let w = sprite.pointSize.width * k, h = sprite.pointSize.height * k
                func placed(_ pos: CGPoint) -> CIImage {
                    let origin = CGPoint(x: pos.x - sprite.hotSpot.x * k, y: pos.y + sprite.hotSpot.y * k - h)
                    return sprite.image
                        .transformed(by: CGAffineTransform(scaleX: w / sprite.image.extent.width, y: h / sprite.image.extent.height))
                        .transformed(by: CGAffineTransform(translationX: origin.x - sprite.image.extent.minX * w / sprite.image.extent.width,
                                                           y: origin.y - sprite.image.extent.minY * h / sprite.image.extent.height))
                }
                let pos = toOutput(p).applying(zoomT)
                var cursor = placed(pos)
                // Cursor motion blur: average of sub-frame positions over the shutter time.
                if s.motionBlur > 0.01 {
                    let earlier = toOutput(st.motion.cursor(at: t - shutter) ?? p).applying(zoomT)
                    let travel = hypot(pos.x - earlier.x, pos.y - earlier.y)
                    if travel > 2 {
                        let samples = min(16, max(3, Int(travel / 1.5)))
                        var sum = CIImage.empty()
                        let weight = CIVector(x: 0, y: 0, z: 0, w: 1 / CGFloat(samples))
                        for i in 0..<samples {
                            let ti = t - shutter * Double(i) / Double(samples - 1)
                            let pi = toOutput(st.motion.cursor(at: ti) ?? p).applying(zoomT)
                            // Alpha-only weight (unpremultiplied matrix) → sum of copies = average.
                            let copy = placed(pi).applyingFilter("CIColorMatrix", parameters: ["inputAVector": weight])
                            sum = copy.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: sum])
                        }
                        cursor = sum
                    }
                }
                let shadow = placed(pos)
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.35)])
                    .applyingGaussianBlur(sigma: 1.5 * k)
                    .transformed(by: CGAffineTransform(translationX: 0, y: -1.2 * k))
                cursor = cursor.composited(over: shadow)
                if alpha < 0.999 {
                    cursor = cursor.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))])
                }
                // Highlight around the pointer (under the cursor; the spotlight darkens everything else).
                // A range of the cursor lane overrides the setting for the whole video.
                let hot = CGPoint(x: pos.x, y: pos.y)
                let T = st.map.timeline(t)
                let range = s.cursorRanges.first { r in st.map.run(r.start, r.end).map { $0.contains(T) } ?? false }
                let effect = range?.effect ?? s.cursorEffect
                var fade = 1.0
                if let range {
                    let run = st.map.run(range.start, range.end)
                    let a = run?.lowerBound ?? T, b = run?.upperBound ?? T
                    fade = max(0, min(1, (T - a) / 0.2, (b - T) / 0.2))
                }
                let alpha = alpha * fade
                let radius = 42 * pointToOut * CGFloat(range?.size ?? s.cursorEffectSize) * max(1, CGFloat(s.cursorScale) * 0.6)
                switch effect {
                case .hidden:
                    // Fades out over 0.2 s at the edges of the range.
                    cursor = Self.withAlpha(cursor, 1 - fade)
                case .none:
                    break
                case .halo:
                    let halo = CIFilter.radialGradient()
                    halo.center = hot; halo.radius0 = Float(radius * 0.55); halo.radius1 = Float(radius)
                    halo.color0 = CIColor(red: 1, green: 0.85, blue: 0.1, alpha: 0.45); halo.color1 = CIColor(red: 1, green: 0.85, blue: 0.1, alpha: 0)
                    if let g = halo.outputImage?.cropped(to: CGRect(x: hot.x - radius, y: hot.y - radius, width: 2 * radius, height: 2 * radius)) {
                        image = Self.withAlpha(g, alpha).composited(over: image)
                    }
                case .spotlight:
                    let light = CIFilter.radialGradient()
                    light.center = hot; light.radius0 = Float(radius * 1.6); light.radius1 = Float(radius * 2.1)
                    light.color0 = .white; light.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
                    let dim = 1 - 0.55 * CGFloat(alpha)
                    let dark = image.applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: dim, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: dim, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: dim, w: 0)])
                    if let mask = light.outputImage?.cropped(to: outRect) {
                        image = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: dark, kCIInputMaskImageKey: mask])
                            .cropped(to: outRect)
                    }
                case .lens:
                    // The area around the pointer, enlarged twice, in a round lens.
                    let r = radius * 1.7
                    let lensRect = CGRect(x: hot.x - r, y: hot.y - r, width: 2 * r, height: 2 * r)
                    let zoomed = image.transformed(by: CGAffineTransform(translationX: -hot.x, y: -hot.y)
                        .concatenating(CGAffineTransform(scaleX: 2, y: 2))
                        .concatenating(CGAffineTransform(translationX: hot.x, y: hot.y)))
                    let disk = shape(.ellipse, lensRect, radius: 0, color: .white)
                    var lens = zoomed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                                    kCIInputMaskImageKey: disk]).cropped(to: lensRect)
                    let ring = shape(.ellipse, lensRect.insetBy(dx: -3 * ref, dy: -3 * ref), radius: 0, color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.95))
                    let shadowDisk = shape(.ellipse, lensRect, radius: 0, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45))
                        .applyingGaussianBlur(sigma: 10 * ref).transformed(by: CGAffineTransform(translationX: 0, y: -5 * ref))
                    lens = lens.composited(over: ring).composited(over: shadowDisk)
                    image = Self.withAlpha(lens, alpha).composited(over: image)
                }
                image = cursor.composited(over: image)
            }
        }

        // 5b. Video overlays (picture in picture, second window)
        image = videoOverlays(over: image, time: T, settings: s, map: st.map, frames: overlays, out: out, lane: 0)

        // 6. Camera (fixed in the output, not affected by zoom): bubble, larger bubble or full frame by layout.
        if let camera {
            let cam = camState
            if let regions, cam.split > 0.001 {
                image = Self.withAlpha(cameraInRegion(camera, region: regions.camera, settings: s, out: out), cam.split).composited(over: image)
            }
            if cam.full > 0.001 {
                image = image.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: fullFrameCamera(camera, settings: s, out: out), kCIInputTimeKey: cam.full]).cropped(to: outRect)
            }
            let bubbleAlpha = cam.alpha * (1 - cam.full)
            if bubbleAlpha > 0.001 {
                image = Self.withAlpha(cameraBubble(camera, settings: s, out: out, ref: ref, scale: cam.scale), bubbleAlpha)
                    .composited(over: image)
            }
        }

        // Fade of the whole recording next to intro/outro cards.
        if contentAlpha < 0.999 {
            let bg = background(style: s.background, blur: s.backgroundBlur, size: out)
            image = bg.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: image.cropped(to: outRect),
                                                                           kCIInputTimeKey: max(0, contentAlpha)])
        }

        // 6b. Lower thirds and covering title cards, pictures and the logo (fixed in the output)
        image = textOverlays(over: image, time: T, settings: s, map: st.map, out: out)
        image = imageOverlays(over: image, time: T, settings: s, map: st.map, out: out, lane: 0)
        // Higher media lanes lie above the first one, each one complete before the next.
        for lane in 1..<EditSettings.maxMediaLanes where s.images.contains(where: { $0.lane == lane }) || s.videoOverlays.contains(where: { $0.lane == lane }) {
            image = videoOverlays(over: image, time: T, settings: s, map: st.map, frames: overlays, out: out, lane: lane)
            image = imageOverlays(over: image, time: T, settings: s, map: st.map, out: out, lane: lane)
        }
        image = logo(over: image, settings: s, out: out)

        // 7. Keyboard shortcut badge (above the captions when they are at the bottom)
        let caption = s.showCaptions ? captionPlacement(at: t, settings: s, map: st.map, out: out) : nil
        if s.showShortcuts, let key = st.track.keys?.last(where: { t >= $0.t && t - $0.t < 1.3 }) {
            let short = min(out.width, out.height)
            let badge = captionImages.image(text: key.label, fontSize: 0.05 * short, maxWidth: out.width * 0.5)
            let age = t - key.t
            let fade = min(1, age / 0.08, (1.3 - age) / 0.25)
            let pop = 1 + 0.08 * max(0, 1 - age / 0.12)   // tiny pop when pressed
            let low = s.captionStyle.y > 0.75
            let y = caption.map { low ? $0.rect.maxY + short * 0.02 : out.height * 0.07 } ?? out.height * 0.07
            var placed = badge
                .transformed(by: CGAffineTransform(scaleX: pop, y: pop))
                .transformed(by: CGAffineTransform(translationX: (out.width - badge.extent.width * pop) / 2, y: y))
            if fade < 0.999 {
                placed = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, fade)))])
            }
            image = placed.composited(over: image)
        }

        // 8. Captions (on top of everything)
        if let c = caption {
            var placed = c.image.transformed(by: CGAffineTransform(translationX: c.rect.minX - c.image.extent.minX, y: c.rect.minY - c.image.extent.minY))
            if abs(c.scale - 1) > 0.001 {
                placed = placed.transformed(by: CGAffineTransform(translationX: -c.rect.midX, y: -c.rect.midY)
                    .concatenating(CGAffineTransform(scaleX: c.scale, y: c.scale))
                    .concatenating(CGAffineTransform(translationX: c.rect.midX, y: c.rect.midY)))
            }
            image = Self.withAlpha(placed, c.alpha).composited(over: image)
        }

        return image.cropped(to: outRect)
    }

    // MARK: Captions

    /// The caption shown at source time `t`: its image, where it sits (CI coordinates), the pop
    /// scale and the opacity.
    /// Fades and the pop are in timeline time (captions also run over inserted clips).
    private func captionPlacement(at t: Double, settings s: EditSettings, map: TimeMap, out: CGSize)
        -> (image: CIImage, rect: CGRect, scale: CGFloat, alpha: Double)? {
        guard let caption = s.captions.first(where: { t >= $0.start && t <= $0.end }) else { return nil }
        let style = s.captionStyle
        let tokens = s.captionTokens(caption)
        guard !tokens.isEmpty else { return nil }
        let current = tokens.lastIndex { t >= $0.start - 0.001 } ?? 0
        let short = min(out.width, out.height)
        var size = 0.042 * short * CGFloat(s.captionSize)
        var words = tokens.map(\.text)
        var highlight: Int?
        var unitStart = caption.start
        let captionRun = map.run(caption.start, caption.end)
        let T = map.timeline(t), T0 = captionRun?.lowerBound ?? map.timeline(caption.start), T1 = captionRun?.upperBound ?? map.timeline(caption.end)
        var alpha = max(0, min(1, (T - T0) / 0.12, (T1 - T) / 0.12))
        switch style.mode {
        case .sentence:
            break
        case .highlight:
            highlight = current
        case .chunks:
            let groups = EditSettings.captionGroups(words)
            let g = groups.first { $0.contains(current) } ?? 0..<words.count
            words = Array(words[g])
            highlight = current - g.lowerBound
            unitStart = tokens[g.lowerBound].start
            size *= 1.25
            alpha = min(1, (T1 - T) / 0.08)
        case .word:
            words = [words[current]]
            unitStart = tokens[current].start
            size *= 1.6
            alpha = min(1, (T1 - T) / 0.08)
        }
        let image = captionBlocks.image(words: words, highlight: highlight, style: style, fontSize: size, maxWidth: out.width * 0.84)
        let w = image.extent.width, h = image.extent.height
        let cx = CGFloat(style.x) * out.width, cy = (1 - CGFloat(style.y)) * out.height
        let rect = CGRect(x: min(max(0, cx - w / 2), max(0, out.width - w)), y: min(max(0, cy - h / 2), max(0, out.height - h)),
                          width: w, height: h)
        var scale: CGFloat = 1
        if style.pop, style.mode == .chunks || style.mode == .word {
            let age = (T - map.timeline(unitStart)) / 0.14
            scale = age < 1 ? 0.82 + 0.18 * CGFloat(1 - pow(1 - max(0, age), 3)) * 1.04 : 1
        }
        return (image, rect, scale, max(0, alpha))
    }

    /// Where the caption sits at source time `t` (CI coordinates), nil if none is shown.
    func captionFrame(at t: Double) -> CGRect? {
        lock.lock(); let st = state; lock.unlock()
        guard st.settings.showCaptions else { return nil }
        return captionPlacement(at: t, settings: st.settings, map: st.map, out: Self.outputSize(info: st.info, settings: st.settings))?.rect
    }

    // MARK: Text overlays and title cards

    private static func withAlpha(_ image: CIImage, _ alpha: Double) -> CIImage {
        guard alpha < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, alpha)))])
    }

    /// - Parameter T: timeline time.
    private func textOverlays(over base: CIImage, time T: Double, settings s: EditSettings, map: TimeMap, out: CGSize) -> CIImage {
        var image = base
        let short = min(out.width, out.height)
        for o in s.overlayTexts {
            guard let r = o.isFree ? o.start...max(o.start, o.end) : map.run(o.start, o.end) else { continue }
            let a = r.lowerBound, b = r.upperBound
            guard T >= a, T <= b else { continue }
            let fadeIn = min(1, (T - a) / TextOverlay.fade)
            let fadeOut = min(1, (b - T) / TextOverlay.fade)
            let motionIn = o.motionIn ?? .standard, motionOut = o.motionOut ?? .standard
            let window = max(0.01, min(0.5, (b - a) / 2))
            let inP = min(1, max(0, (T - a) / window)), outP = min(1, max(0, (b - T) / window))
            var layer: CIImage
            var box: CGRect
            switch o.kind {
            case .lowerThird:
                let block = lowerThirdBlock(o, out: out)
                layer = Self.placeLowerThird(block, o, out: out, appear: motionIn == .standard ? fadeIn : 1, short: short)
                box = Self.lowerThirdRect(size: block.extent.size, o, out: out)
            case .titleCard:
                layer = cardImage(o, settings: s, out: out, textAlpha: 1, rise: 0)
                box = CGRect(origin: .zero, size: out)
            }
            if motionIn != .standard, inP < 1 { layer = Self.moved(layer, motionIn, progress: inP, box: box, out: out) }
            if motionOut != .standard, outP < 1 { layer = Self.moved(layer, motionOut, progress: outP, box: box, out: out) }
            let alpha = max(0, min(motionIn == .standard ? fadeIn : Self.motionAlpha(motionIn, inP),
                                   motionOut == .standard ? fadeOut : Self.motionAlpha(motionOut, outP)))
            image = Self.withAlpha(layer, alpha).composited(over: image)
        }
        return image
    }

    private static func motionAlpha(_ motion: TextMotion, _ progress: Double) -> Double {
        switch motion {
        case .fade: return progress
        case .pop: return min(1, progress * 2.5)
        default: return 1
        }
    }

    /// A text on its way in or out: `progress` 1 is its resting place.
    private static func moved(_ layer: CIImage, _ motion: TextMotion, progress: Double, box: CGRect, out: CGSize) -> CIImage {
        let e = CGFloat(1 - pow(1 - max(0, min(1, progress)), 3))
        switch motion {
        case .standard, .fade, .none: return layer
        case .fromLeft: return layer.transformed(by: CGAffineTransform(translationX: -(box.maxX + 4) * (1 - e), y: 0))
        case .fromRight: return layer.transformed(by: CGAffineTransform(translationX: (out.width - box.minX + 4) * (1 - e), y: 0))
        case .fromBottom: return layer.transformed(by: CGAffineTransform(translationX: 0, y: -(box.maxY + 4) * (1 - e)))
        case .fromTop: return layer.transformed(by: CGAffineTransform(translationX: 0, y: (out.height - box.minY + 4) * (1 - e)))
        case .wipe: return layer.cropped(to: CGRect(x: box.minX, y: box.minY - 40, width: max(1, box.width * e), height: box.height + 80))
        case .pop:
            // Slightly past the full size, then settling.
            let p = CGFloat(max(0, min(1, progress))) - 1
            let scale = 0.65 + 0.35 * (1 + 2.7 * p * p * p + 1.7 * p * p)
            return layer.transformed(by: CGAffineTransform(translationX: -box.midX, y: -box.midY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: box.midX, y: box.midY)))
        }
    }

    /// Where a lower third sits in the output (Core Image coordinates, bottom-left origin).
    func lowerThirdFrame(_ o: TextOverlay) -> CGRect {
        lock.lock(); let st = state; lock.unlock()
        let out = Self.outputSize(info: st.info, settings: st.settings)
        return Self.lowerThirdRect(size: lowerThirdBlock(o, out: out).extent.size, o, out: out)
    }

    /// The rendered box of a lower third (text, design and an optional picture).
    private func lowerThirdBlock(_ o: TextOverlay, out: CGSize) -> CIImage {
        let short = min(out.width, out.height)
        let pic = o.image.flatMap { pictureCG($0) }
        return textBlocks.image(title: o.title, subtitle: o.subtitle, design: o.look, align: o.align,
                                titleSize: 0.042 * short * CGFloat(o.size), maxWidth: out.width * 0.62, box: true,
                                picture: pic.map { (o.image ?? "", $0) })
    }

    /// Box position from the anchor; slides in a little while it appears.
    static func lowerThirdRect(size: CGSize, _ o: TextOverlay, out: CGSize) -> CGRect {
        let ax = CGFloat(o.x) * out.width
        var x: CGFloat
        switch o.align {
        case .left: x = ax
        case .center: x = ax - size.width / 2
        case .right: x = ax - size.width
        }
        x = min(max(0, x), max(0, out.width - size.width))
        // y is measured from the top; Core Image's origin is bottom-left.
        var y = out.height - CGFloat(o.y) * out.height - size.height / 2
        y = min(max(0, y), max(0, out.height - size.height))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private static func placeLowerThird(_ block: CIImage, _ o: TextOverlay, out: CGSize, appear: Double, short: CGFloat) -> CIImage {
        let rect = lowerThirdRect(size: block.extent.size, o, out: out)
        let eased = 1 - pow(1 - max(0, min(1, appear)), 3)
        let slide = CGFloat(1 - eased) * short * 0.03
        let dx: CGFloat = o.align == .left ? -slide : o.align == .right ? slide : 0
        let dy: CGFloat = o.align == .center ? -slide : 0
        return block.transformed(by: CGAffineTransform(translationX: rect.minX + dx - block.extent.minX,
                                                       y: rect.minY + dy - block.extent.minY))
    }

    /// Full-screen title card: background plus centered title and subtitle.
    private func cardImage(_ o: TextOverlay, settings s: EditSettings, out: CGSize, textAlpha: Double, rise: Double) -> CIImage {
        let outRect = CGRect(origin: .zero, size: out)
        let bg = o.look.cardBackground.map { CIImage(color: CIColor(cgColor: $0.cgColor)).cropped(to: outRect) }
            ?? background(style: s.background, blur: s.backgroundBlur, size: out)
        let short = min(out.width, out.height)
        let block = textBlocks.image(title: o.title, subtitle: o.subtitle, design: o.look, align: .center,
                                     titleSize: 0.085 * short * CGFloat(o.size), maxWidth: out.width * 0.8, box: false,
                                     picture: o.image.flatMap { f in pictureCG(f).map { (f, $0) } })
        let x = (out.width - block.extent.width) / 2
        let y = (out.height - block.extent.height) / 2 - CGFloat(rise) * short * 0.02
        let text = block.transformed(by: CGAffineTransform(translationX: x - block.extent.minX, y: y - block.extent.minY))
        return Self.withAlpha(text, textAlpha).composited(over: bg).cropped(to: outRect)
    }

    /// Intro/outro card at `localTime` seconds into it. The text fades in and out; a card with
    /// its own background also fades to the project background towards the recording, unless
    /// the card cross-dissolves with the recording (`fadeToRecording` false).
    func renderCard(_ instructionCard: TextOverlay, localTime lt: Double, fadeToRecording: Bool = true) -> CIImage {
        lock.lock(); let st = state; lock.unlock()
        let s = st.settings
        // Text and style edits apply right away; the composition only knows the card's id and length.
        let card = s.texts.first { $0.id == instructionCard.id } ?? instructionCard
        let out = Self.outputSize(info: st.info, settings: s)
        let length = max(0.1, card.length)
        let textIn = min(1, max(0, (lt - 0.1) / 0.5))
        let textOut = min(1, max(0, (length - lt) / 0.45))
        let rise = 1 - (1 - pow(1 - textIn, 3))
        var image = cardImage(card, settings: s, out: out, textAlpha: min(textIn, textOut), rise: rise)
        if fadeToRecording, card.look.cardBackground != nil {
            // Towards the recording: intro fades out at its end, outro fades in at its start.
            let toRecording = card.placement == .intro ? (length - lt) / TextOverlay.fade : lt / TextOverlay.fade
            if toRecording < 1 {
                let bg = background(style: s.background, blur: s.backgroundBlur, size: out)
                image = bg.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: image,
                                                                               kCIInputTimeKey: max(0, toRecording)])
            }
        }
        // The logo stays on intro and outro too.
        return logo(over: image, settings: s, out: out).cropped(to: CGRect(origin: .zero, size: out))
    }

    /// Shutter simulation for camera moves: averages copies of the frame placed along the
    /// path the content travelled between `previous` and `current` (zoom and pan alike).
    /// Blur length therefore equals the real on-screen displacement during the shutter.
    private func cameraMotionBlur(_ image: CIImage, current: Camera, previous: Camera, out: CGSize) -> CIImage {
        // A maps a point of the current output to where that content was at the shutter start.
        let A = current.transform.inverted().concatenating(previous.transform)
        let corners = [CGPoint.zero, CGPoint(x: out.width, y: 0), CGPoint(x: 0, y: out.height), CGPoint(x: out.width, y: out.height)]
        let maxShift = corners.map { hypot($0.applying(A).x - $0.x, $0.applying(A).y - $0.y) }.max() ?? 0
        guard maxShift > 1.5 else { return image }
        let samples = min(12, max(3, Int(ceil(maxShift / 2))))
        let outRect = CGRect(origin: .zero, size: out)
        let base = image.clampedToExtent()
        let w = 1 / CGFloat(samples)
        var sum = CIImage.empty()
        for i in 0..<samples {
            let u = CGFloat(i) / CGFloat(samples - 1)   // 0 = shutter start, 1 = now
            let f = 1 - u
            // B = I + f·(A − I): the frame as seen at shutter time u.
            let B = CGAffineTransform(a: 1 + f * (A.a - 1), b: f * A.b, c: f * A.c, d: 1 + f * (A.d - 1),
                                      tx: f * A.tx, ty: f * A.ty)
            // CIColorMatrix works on unpremultiplied colors: scaling alpha alone weights the
            // premultiplied pixel by w, so the sum of all copies is the average.
            let copy = base.transformed(by: B).cropped(to: outRect).applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: w)])
            sum = copy.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: sum])
        }
        return sum.cropped(to: outRect)
    }

    /// Pixelates/blurs mask regions in the source frame (before layout, so masks follow the zoom).
    private func applyMasks(_ src: CIImage, time t: Double, masks: [BlurMask]) -> CIImage {
        var img = src
        let W = src.extent.width, H = src.extent.height
        for m in masks where t >= m.start && t <= m.end {
            let at = m.rect(at: t)
            let r = CGRect(x: at.minX * W, y: (1 - at.minY - at.height) * H, width: at.width * W, height: at.height * H)
                .integral.intersection(src.extent)
            guard !r.isNull, r.width > 2, r.height > 2 else { continue }
            let effect: CIImage
            switch m.style {
            case .pixelate:
                let block = max(8, min(r.width, r.height) / 6, W / 90)
                effect = img.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: block, kCIInputCenterKey: CIVector(x: r.minX, y: r.minY)])
            case .blur:
                effect = img.cropped(to: r).clampedToExtent().applyingGaussianBlur(sigma: max(10, W / 110))
            }
            img = effect.cropped(to: r).composited(over: img)
        }
        return img
    }

    // MARK: Annotations (arrow, frame, spotlight on the recording)

    /// - Parameter T: timeline time (fades are 0.2 timeline seconds, also inside inserted clips).
    private func applyAnnotations(_ src: CIImage, time T: Double, annotations: [Annotation], map: TimeMap) -> CIImage {
        var img = src
        let W = src.extent.width, H = src.extent.height
        let unit = max(W, H) / 400
        for a in annotations {
            guard let stretch = map.run(a.start, a.end) else { continue }
            let a0 = stretch.lowerBound, a1 = stretch.upperBound
            guard T >= a0, T <= a1 else { continue }
            let animated = a.animated ?? true
            let age = T - a0
            let drawing = a.kind == .arrow ? 0.38 : 0.55
            let progress = animated && a.kind != .spotlight ? min(1, age / drawing) : 1
            // Drawn on screen instead of fading in; all go out with a short fade.
            let alpha = max(0, min(1, animated && a.kind != .spotlight ? 1 : (T - a0) / 0.2, (a1 - T) / 0.2))
            let (r, g, b) = a.color.rgb
            let color = CIColor(red: r, green: g, blue: b)
            let rect = CGRect(x: min(a.x, a.x + a.width) * W, y: (1 - max(a.y, a.y + a.height)) * H,
                              width: abs(a.width) * W, height: abs(a.height) * H)
            let line = 3 * unit * CGFloat(a.thickness)
            switch a.kind {
            case .frame:
                guard rect.width > 2, rect.height > 2 else { continue }
                let eased = 1 - pow(1 - progress, 2)
                let strokes = Sketch.outline(rect, shape: a.outline, line: line, handDrawn: a.handDrawn ?? true, seed: Sketch.seed(a.id))
                let frame = sketchImage(a, strokes, progress: eased, line: line, halo: false, key: "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))")
                img = Self.withAlpha(frame, alpha).composited(over: img).cropped(to: src.extent)
            case .spotlight:
                guard rect.width > 2, rect.height > 2 else { continue }
                let mask = shape(a.outline, rect, radius: a.outline == .rectangle ? 0 : min(rect.width, rect.height) * 0.15, color: .white)
                    .applyingGaussianBlur(sigma: unit * 3).cropped(to: src.extent)
                let dim = 1 - 0.62 * alpha
                let dark = img.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: dim, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: dim, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: dim, w: 0)])
                img = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: dark, kCIInputMaskImageKey: mask])
                    .cropped(to: src.extent)
            case .arrow:
                let from = CGPoint(x: a.x * W, y: (1 - a.y) * H)
                let to = CGPoint(x: (a.x + a.width) * W, y: (1 - a.y - a.height) * H)
                let length = hypot(to.x - from.x, to.y - from.y)
                guard length > 4 else { continue }
                let eased = 1 - pow(1 - progress, 2)
                let strokes = Sketch.arrow(from: from, to: to, line: line * 1.4, handDrawn: a.handDrawn ?? true, seed: Sketch.seed(a.id))
                var arrow = sketchImage(a, strokes, progress: eased, line: line * 1.4, halo: true, key: "\(Int(from.x)),\(Int(from.y)),\(Int(to.x)),\(Int(to.y))")
                // Once drawn it keeps nudging towards what it points at.
                if animated, age > drawing {
                    let push = line * 2.4 * (0.5 - 0.5 * cos((age - drawing) * 2 * .pi / 1.05))
                    arrow = arrow.transformed(by: CGAffineTransform(translationX: (to.x - from.x) / length * push, y: (to.y - from.y) / length * push))
                }
                img = Self.withAlpha(arrow, alpha).composited(over: img)
            case .step:
                let number = (annotations.filter { $0.kind == .step }.sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }.firstIndex { $0.id == a.id } ?? 0) + 1
                let radius = 11 * unit * CGFloat(a.thickness), art = min(radius, 120)
                let key = "step|\(number)|\(a.color.rawValue)|\(Int(art))"
                var badge = lock.withLock { arrowCache[key] }
                if badge == nil {
                    let made = TouchArt.step(number, r: art, color: (CGFloat(r), CGFloat(g), CGFloat(b)))
                    lock.withLock {
                        if arrowCache.count > 24 { arrowCache.removeAll() }
                        arrowCache[key] = made
                    }
                    badge = made
                }
                // Pops up and settles.
                let p = CGFloat(min(1, age / 0.22)), overshoot = p < 1 ? 0.6 + 0.5 * p + 0.2 * sin(p * .pi) : 1.0
                let size = radius / art * (animated ? min(1.12, overshoot) : 1)
                if let badge {
                    let placed = badge.transformed(by: CGAffineTransform(scaleX: size, y: size).concatenating(CGAffineTransform(translationX: a.x * W, y: (1 - a.y) * H)))
                    img = Self.withAlpha(placed, alpha).composited(over: img)
                }
            case .touch:
                let from = CGPoint(x: a.x * W, y: (1 - a.y) * H)
                let to = CGPoint(x: (a.x + a.width) * W, y: (1 - a.y - a.height) * H)
                img = touches(over: img, a, from: from, to: to, radius: 9 * unit * CGFloat(a.thickness), age: age, length: a1 - a0, alpha: alpha)
            }
        }
        // A marking reaching over the edge must not enlarge the picture: it would be placed differently.
        return img.cropped(to: src.extent)
    }

    /// Finger gesture: the way it has come, ripples, the touch points and (optionally) the fingers.
    private func touches(over base: CIImage, _ a: Annotation, from: CGPoint, to: CGPoint, radius r: CGFloat, age: Double, length: Double, alpha: Double) -> CIImage {
        var img = base
        let (cr, cg, cb) = a.color.rgb
        let color = (CGFloat(cr), CGFloat(cg), CGFloat(cb))
        let pose = TouchAnimation.pose(a.touchGesture, from: from, to: to, gap: r * 2.5, age: age, length: length, repeats: a.repeats ?? false)
        let art = min(r, 96)
        func cached(_ name: String, _ make: () -> CIImage) -> CIImage {
            let key = "touch|\(name)|\(a.color.rawValue)|\(Int(art))"
            if let image = lock.withLock({ arrowCache[key] }) { return image }
            let image = make()
            lock.withLock {
                if arrowCache.count > 24 { arrowCache.removeAll() }
                arrowCache[key] = image
            }
            return image
        }
        for trail in pose.trails {
            let way = Sketch.image([trail], progress: 1, line: r * 0.42, color: color, halo: false)
            img = Self.withAlpha(way, 0.55 * alpha * Double(pose.fingers.first?.alpha ?? 1)).composited(over: img)
        }
        for ripple in pose.ripples {
            let scale = (0.75 + 1.5 * ripple.progress) * r / art
            let ring = cached("ring") { TouchArt.ring(r: art, color: color) }
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: ripple.at.x, y: ripple.at.y)))
            img = Self.withAlpha(ring, Double(pow(1 - ripple.progress, 1.4)) * alpha).composited(over: img)
        }
        let showFinger = a.touchLook == .finger
        let twoFingers = pose.fingers.count > 1
        for (i, finger) in pose.fingers.enumerated() {
            let scale = finger.scale * r / art * (showFinger ? 0.72 : 1)
            let dot = cached("dot") { TouchArt.dot(r: art, color: color) }
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: finger.at.x, y: finger.at.y)))
            img = Self.withAlpha(dot, Double(finger.alpha) * alpha).composited(over: img)
            if showFinger {
                // From the lower right, like a right hand. (Turned by `turn`, the finger runs along (sin, -cos).)
                var turn = 0.5
                if a.touchGesture.isPinch, twoFingers {
                    // Pointing away from the middle and a little downwards, like thumb and index finger.
                    let m = CGPoint(x: pose.fingers.map(\.at.x).reduce(0, +) / 2, y: pose.fingers.map(\.at.y).reduce(0, +) / 2)
                    let d = max(1, hypot(finger.at.x - m.x, finger.at.y - m.y))
                    turn = Double(atan2((finger.at.x - m.x) / d, 0.8 - (finger.at.y - m.y) / d))
                } else if twoFingers {
                    turn = i == 0 ? 0.42 : 0.58
                }
                let size = finger.scale * r / art
                let shape = cached("finger") { TouchArt.finger(r: art) }
                    .transformed(by: CGAffineTransform(scaleX: size, y: size)
                        .concatenating(CGAffineTransform(rotationAngle: CGFloat(turn)))
                        .concatenating(CGAffineTransform(translationX: finger.at.x, y: finger.at.y)))
                img = Self.withAlpha(shape, Double(finger.alpha) * alpha * 0.95).composited(over: img)
            }
        }
        if let hold = pose.hold, let finger = pose.fingers.first {
            let ring = (0...72).map { i -> CGPoint in
                let t = CGFloat(i) / 72 * 2 * .pi + .pi / 2
                return CGPoint(x: finger.at.x + cos(t) * r * 1.45, y: finger.at.y + sin(t) * r * 1.45)
            }
            img = Self.withAlpha(Sketch.image([ring], progress: hold, line: r * 0.2, color: color, halo: true), alpha).composited(over: img)
        }
        return img
    }

    /// The finished line drawing is kept; the few frames while it is being drawn are made as needed.
    private func sketchImage(_ a: Annotation, _ strokes: [Sketch.Stroke], progress: CGFloat, line: CGFloat, halo: Bool, key geometry: String) -> CIImage {
        let (r, g, b) = a.color.rgb
        guard progress >= 1 else { return Sketch.image(strokes, progress: progress, line: line, color: (r, g, b), halo: halo) }
        let key = "\(a.id)|\(geometry)|\(Int(line * 4))|\(a.color.rawValue)|\(a.handDrawn ?? true)|\(a.outline.rawValue)"
        if let cached = lock.withLock({ arrowCache[key] }) { return cached }
        let image = Sketch.image(strokes, progress: 1, line: line, color: (r, g, b), halo: halo)
        lock.withLock {
            if arrowCache.count > 24 { arrowCache.removeAll() }
            arrowCache[key] = image
        }
        return image
    }

    // MARK: Pictures and logo

    /// A picture from the project folder (cached).
    func picture(_ file: String) -> CIImage? {
        if let cached = lock.withLock({ imageCache[file] }) { return cached }
        guard let image = CIImage(contentsOf: projectURL.appendingPathComponent(file), options: [.applyOrientationProperty: true]) else { return nil }
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        lock.withLock { imageCache[file] = normalized }
        return normalized
    }

    /// Where a picture overlay sits in the output (Core Image coordinates).
    func imageFrame(_ o: ImageOverlay, out: CGSize) -> CGRect? {
        guard let img = picture(o.file), img.extent.width > 0 else { return nil }
        let w = CGFloat(o.width) * out.width
        let h = w * img.extent.height / img.extent.width
        return CGRect(x: CGFloat(o.x) * out.width - w / 2, y: (1 - CGFloat(o.y)) * out.height - h / 2, width: w, height: h)
    }

    /// Where the logo sits in the output (Core Image coordinates).
    func watermarkFrame(_ w: Watermark, out: CGSize) -> CGRect? {
        guard let img = picture(w.file), img.extent.width > 0 else { return nil }
        let short = min(out.width, out.height)
        let width = CGFloat(w.size) * short
        let height = width * img.extent.height / img.extent.width
        let margin = 0.035 * short
        let left = w.corner == .topLeft || w.corner == .bottomLeft
        let bottom = w.corner == .bottomLeft || w.corner == .bottomRight
        return CGRect(x: left ? margin : out.width - margin - width, y: bottom ? margin : out.height - margin - height,
                      width: width, height: height)
    }

    private func imageOverlays(over base: CIImage, time T: Double, settings s: EditSettings, map: TimeMap, out: CGSize, lane: Int) -> CIImage {
        var image = base
        let short = min(out.width, out.height)
        let dissolves = Self.mediaDissolves(s, map: map)
        for placed in s.images.filter({ ($0.lane ?? 0) == lane }).sorted(by: { Self.imageStart($0, map) < Self.imageStart($1, map) }) {
            guard let r = placed.isFree ? placed.start...max(placed.start, placed.end) : map.run(placed.start, placed.end) else { continue }
            let a = r.lowerBound, b = r.upperBound
            let o = placed.moved(at: T - a)
            guard T >= a, T <= b, let img = picture(o.file), let rect = imageFrame(o, out: out) else { continue }
            let fade = max(0, min(1, (T - a) / max(0.3, dissolves[o.id]?.fadeIn ?? 0), (b - T) / max(0.3, dissolves[o.id]?.fadeOut ?? 0)))
            let framed = framedPicture(img, in: rect, frame: o.frame ?? .none, shadow: o.shadow ?? false, short: short)
            image = Self.withAlpha(framed, fade * o.opacity).composited(over: image)
        }
        return image
    }

    /// The logo in its corner, on every frame of the video.
    private func logo(over base: CIImage, settings s: EditSettings, out: CGSize) -> CIImage {
        guard let w = s.watermark, let img = picture(w.file), let rect = watermarkFrame(w, out: out) else { return base }
        let placed = img
            .transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: rect.width / img.extent.width, y: rect.height / img.extent.height))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return Self.withAlpha(placed, w.opacity).composited(over: base)
    }

    private static func imageStart(_ o: ImageOverlay, _ map: TimeMap) -> Double { o.isFree ? o.start : (map.run(o.start, o.end)?.lowerBound ?? 0) }
    private static func overlayStart(_ o: VideoOverlay, _ map: TimeMap) -> Double { o.isFree ? o.start : map.timeline(o.start) }

    private static func spot(_ x: Double, _ y: Double, _ w: Double) -> CGRect { CGRect(x: x - w / 2, y: y - w / 2, width: w, height: w) }

    private static func sameSpot(_ a: CGRect, _ b: CGRect) -> Bool {
        let common = a.intersection(b)
        return !common.isNull && common.width * common.height >= 0.4 * min(a.width * a.height, b.width * b.height)
    }

    /// True if two video clips cover about the same place, so that they replace each other.
    static func sameSpot(_ a: VideoOverlay, _ b: VideoOverlay) -> Bool { sameSpot(spot(a.x, a.y, a.width), spot(b.x, b.y, b.width)) }

    /// Clips pushed over each other on the media lane dissolve into each other: the one on top
    /// fades over the length of the overlap. (Pictures lie above videos, so a picture that ends
    /// over a later video fades out instead.) Clips at different places in the picture stay apart.
    static func mediaDissolves(_ s: EditSettings, map: TimeMap) -> [UUID: (fadeIn: Double, fadeOut: Double)] {
        guard s.images.count + s.videoOverlays.count > 1 else { return [:] }
        struct Item { let id: UUID; let start: Double; let end: Double; let isImage: Bool; let box: CGRect; let lane: Int }
        var items: [Item] = s.images.compactMap { o in
            guard let r = o.isFree ? o.start...max(o.start, o.end) : map.run(o.start, o.end) else { return nil }
            return Item(id: o.id, start: r.lowerBound, end: r.upperBound, isImage: true, box: spot(o.x, o.y, o.width), lane: o.lane ?? 0)
        }
        items += s.videoOverlays.filter { !$0.synced }.compactMap { o in
            var a = o.start, b = o.start + o.duration
            if !o.isFree {
                let pieces = s.linkedPieces(start: o.start, duration: o.duration, map: s.timeMap(duration: map.duration), kept: s.keptSegments(duration: map.duration))
                guard let first = pieces.first, let last = pieces.last else { return nil }
                a = first.timeline.lowerBound
                b = last.timeline.upperBound
            }
            return Item(id: o.id, start: a, end: b, isImage: false, box: spot(o.x, o.y, o.width), lane: o.lane ?? 0)
        }
        var result: [UUID: (fadeIn: Double, fadeOut: Double)] = [:]
        let sorted = items.sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
        for (i, a) in sorted.enumerated() {
            for b in sorted[(i + 1)...] where b.start < a.end - 0.01 && b.end > a.end + 0.01 {
                guard a.lane == b.lane, sameSpot(a.box, b.box) else { continue }
                let overlap = min(EditSettings.maxDissolve, a.end - b.start)
                if a.isImage && !b.isImage {
                    result[a.id, default: (0, 0)].fadeOut = max(result[a.id]?.fadeOut ?? 0, overlap)
                } else {
                    result[b.id, default: (0, 0)].fadeIn = max(result[b.id]?.fadeIn ?? 0, overlap)
                }
            }
        }
        return result
    }

    // MARK: Video overlays

    /// Where a video overlay sits in the output (Core Image coordinates).
    static func videoOverlayFrame(_ o: VideoOverlay, out: CGSize) -> CGRect {
        let w = CGFloat(o.width) * out.width
        let h = w / CGFloat(max(0.1, o.aspect))
        return CGRect(x: CGFloat(o.x) * out.width - w / 2, y: (1 - CGFloat(o.y)) * out.height - h / 2, width: w, height: h)
    }

    /// - Parameter T: timeline time.
    private func videoOverlays(over base: CIImage, time T: Double, settings s: EditSettings, map: TimeMap,
                               frames: [UUID: CIImage], out: CGSize, lane: Int) -> CIImage {
        guard !frames.isEmpty else { return base }
        var image = base
        let short = min(out.width, out.height)
        let dissolves = Self.mediaDissolves(s, map: map)
        for placed in s.videoOverlays.filter({ ($0.lane ?? 0) == lane }).sorted(by: { (Self.overlayStart($0, map), $0.id.uuidString) < (Self.overlayStart($1, map), $1.id.uuidString) }) {
            var o = placed
            var a = o.start, b = o.start + o.duration
            if !o.isFree {
                let pieces = s.linkedPieces(start: o.start, duration: o.duration, map: s.timeMap(duration: map.duration), kept: s.keptSegments(duration: map.duration))
                guard let first = pieces.first, let last = pieces.last, pieces.contains(where: { $0.timeline.contains(T) }) else { continue }
                a = first.timeline.lowerBound
                b = last.timeline.upperBound
            }
            guard T >= a, T <= b, let raw = frames[o.id], raw.extent.width > 1 else { continue }
            o = o.moved(at: T - a)
            var frame = raw.transformed(by: CGAffineTransform(translationX: -raw.extent.minX, y: -raw.extent.minY))
            if s.color.applyToMedia, !s.color.isNeutral { frame = Self.graded(frame, s.color) }
            let fade = max(0, min(1, (T - a) / max(0.25, dissolves[o.id]?.fadeIn ?? 0), (b - T) / max(0.25, dissolves[o.id]?.fadeOut ?? 0)))
            let rect = Self.videoOverlayFrame(o, out: out)
            image = Self.withAlpha(framedPicture(frame, in: rect, frame: o.frame, shadow: o.shadow, short: short), fade * o.opacity)
                .composited(over: image)
        }
        return image
    }

    // MARK: Picture frames

    /// `img` filling `rect` (aspect fill), with a frame and shadow.
    private func framedPicture(_ img: CIImage, in rect: CGRect, frame: PictureFrame, shadow: Bool, short: CGFloat) -> CIImage {
        let W = max(1, img.extent.width), H = max(1, img.extent.height)
        func fill(_ r: CGRect) -> CIImage {
            let scale = max(r.width / W, r.height / H)
            return img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: r.midX - W * scale / 2, y: r.midY - H * scale / 2))
                .cropped(to: r)
        }
        var outline = rect
        var radius: CGFloat = 0
        var result: CIImage
        switch frame {
        case .none:
            result = fill(rect)
        case .rounded:
            radius = min(rect.width, rect.height) * 0.07
            result = fill(rect).applyingFilter("CISourceInCompositing", parameters: [
                kCIInputBackgroundImageKey: roundedRect(rect, radius: radius, color: .white)])
        case .border:
            let line = max(2, short * 0.008)
            radius = min(rect.width, rect.height) * 0.05
            outline = rect.insetBy(dx: -line, dy: -line)
            let inner = fill(rect).applyingFilter("CISourceInCompositing", parameters: [
                kCIInputBackgroundImageKey: roundedRect(rect, radius: max(0, radius - line), color: .white)])
            result = inner.composited(over: roundedRect(outline, radius: radius + line, color: .white))
            radius += line
        case .polaroid:
            let m = max(3, min(rect.width, rect.height) * 0.05)
            outline = CGRect(x: rect.minX - m, y: rect.minY - m * 3.2, width: rect.width + 2 * m, height: rect.height + m * 4.2)
            radius = m * 0.4
            result = fill(rect).composited(over: roundedRect(outline, radius: radius, color: CIColor(red: 0.98, green: 0.98, blue: 0.96)))
        case .circle:
            let d = min(rect.width, rect.height)
            outline = CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
            radius = d / 2
            result = fill(outline).applyingFilter("CISourceInCompositing", parameters: [
                kCIInputBackgroundImageKey: shape(.ellipse, outline, radius: 0, color: .white)])
        }
        if shadow {
            let ref = short / 1080
            let s = (frame == .circle ? shape(.ellipse, outline, radius: 0, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.5))
                     : roundedRect(outline, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.5)))
                .applyingGaussianBlur(sigma: 16 * ref)
                .transformed(by: CGAffineTransform(translationX: 0, y: -7 * ref))
            result = result.composited(over: s)
        }
        return result
    }

    /// Filled rectangle, rounded rectangle or ellipse.
    private func shape(_ kind: AnnotationShape, _ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        switch kind {
        case .rectangle: return CIImage(color: color).cropped(to: rect)
        case .rounded: return roundedRect(rect, radius: radius, color: color)
        case .ellipse:
            guard rect.width > 0.5, rect.height > 0.5 else { return .empty() }
            // Unit disk from a radial gradient (1 px soft edge at radius 1000), scaled to the rect.
            let key = "disk"
            let disk: CIImage = lock.withLock { shapeCache[key] } ?? {
                let g = CIFilter.radialGradient()
                g.center = .zero
                g.radius0 = 998
                g.radius1 = 1000
                g.color0 = CIColor.white
                g.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
                let img = (g.outputImage ?? .empty()).cropped(to: CGRect(x: -1000, y: -1000, width: 2000, height: 2000))
                lock.withLock { shapeCache[key] = img }
                return img
            }()
            return disk
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: color.red, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: color.green, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: color.blue, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: color.alpha)])
                .transformed(by: CGAffineTransform(scaleX: rect.width / 2000, y: rect.height / 2000))
                .transformed(by: CGAffineTransform(translationX: rect.midX, y: rect.midY))
        }
    }

    // MARK: Color grading

    /// Exposure, contrast, saturation, warmth and vibrance.
    static func graded(_ img: CIImage, _ g: ColorGrade) -> CIImage {
        guard !g.isNeutral else { return img }
        var out = img
        if abs(g.exposure) > 0.005 {
            out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: g.exposure])
        }
        if abs(g.contrast - 1) > 0.005 || abs(g.saturation - 1) > 0.005 {
            out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: g.saturation,
                                                                     kCIInputContrastKey: g.contrast,
                                                                     kCIInputBrightnessKey: 0])
        }
        if abs(g.temperature) > 0.005 {
            // Warmer: the picture is treated as if shot under colder light (target white point lower).
            out = out.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - CGFloat(g.temperature) * 2600, y: 0)])
        }
        if abs(g.vibrance) > 0.005 {
            out = out.applyingFilter("CIVibrance", parameters: ["inputAmount": g.vibrance])
        }
        return out.cropped(to: img.extent)
    }

    /// A project picture as CGImage (pictures in lower thirds and title cards).
    private func pictureCG(_ file: String) -> CGImage? {
        guard let img = picture(file) else { return nil }
        let key = "cg:" + file
        if let cached = lock.withLock({ imageCache[key] }), let cg = cached.cgImage { return cg }
        guard let cg = rasterContext.createCGImage(img, from: img.extent) else { return nil }
        lock.withLock { imageCache[key] = CIImage(cgImage: cg) }
        return cg
    }

    // MARK: Mapping for UI overlays

    /// Layout and zoom of the frame shown at source time `t` (an inserted clip: its own size, no zoom).
    private func frameGeometry(at t: Double) -> (out: CGSize, layout: FrameLayout, camera: Camera) {
        lock.lock(); let st = state; let sizes = insertSizes; lock.unlock()
        let out = Self.outputSize(info: st.info, settings: st.settings)
        let insert = st.map.insertID(atSource: t)
        let size = insert.flatMap { sizes[$0] } ?? CGSize(width: st.info.pixelWidth, height: st.info.pixelHeight)
        let regions = hasCamera && insert == nil ? Self.splitRegions(out: out, split: Self.cameraState(at: t, settings: st.settings).split) : nil
        let scene = Self.sceneRects(st.settings, info: st.info, out: out)
        let layout = FrameLayout(out: out, sourceSize: size, padding: scene == nil ? st.settings.padding : 0, contentY: st.settings.contentY,
                                 region: scene?.video ?? regions?.screen)
        let cam = Self.camera(at: t, layout: layout, segments: insert == nil ? st.settings.zoomSegments : [], motion: st.motion)
        return (out, layout, cam)
    }

    /// Normalized capture point → output pixel (top-left origin) at time t, including zoom.
    func outputPoint(_ p: CGPoint, at t: Double) -> CGPoint {
        let (out, layout, cam) = frameGeometry(at: t)
        let q = layout.toOutput(p).applying(cam.transform)
        return CGPoint(x: q.x, y: out.height - q.y)
    }

    /// Inverse of `outputPoint`.
    func normalizedPoint(fromOutput q: CGPoint, at t: Double) -> CGPoint {
        let (out, layout, cam) = frameGeometry(at: t)
        let c = CGPoint(x: q.x, y: out.height - q.y).applying(cam.transform.inverted())
        return CGPoint(x: (c.x - layout.content.minX) / layout.content.width,
                       y: 1 - (c.y - layout.content.minY) / layout.content.height)
    }

    static func cameraRect(settings s: EditSettings, out: CGSize, cameraAspect: CGFloat, scale: CGFloat = 1) -> (rect: CGRect, radius: CGFloat) {
        let short = min(out.width, out.height)
        let h = min(CGFloat(s.cameraSize) * short * scale, short * 0.85)
        let w: CGFloat, radius: CGFloat
        switch s.cameraShape {
        case .circle: w = h; radius = h / 2
        case .roundedSquare: w = h; radius = h * 0.22
        case .rectangle: w = h * cameraAspect; radius = h * 0.08
        case .cutout:
            // The person stands on the bottom edge, taller than a bubble.
            let ch = min(h * 1.7, out.height * 0.9), cw = ch * cameraAspect
            let margin = 0.02 * short
            if let cx = s.cameraX, let cy = s.cameraY {
                let x = min(max(CGFloat(cx) * out.width - cw / 2, 0), out.width - cw)
                let y = min(max((1 - CGFloat(cy)) * out.height - ch / 2, 0), out.height - ch)
                return (CGRect(x: x, y: y, width: cw, height: ch), 0)
            }
            let left = s.cameraCorner == .topLeft || s.cameraCorner == .bottomLeft
            let bottom = s.cameraCorner == .bottomLeft || s.cameraCorner == .bottomRight
            return (CGRect(x: left ? margin : out.width - margin - cw, y: bottom ? 0 : out.height - ch, width: cw, height: ch), 0)
        }
        let margin = 0.04 * short
        if let cx = s.cameraX, let cy = s.cameraY {
            // Free position: center given in output fractions (top-left origin), kept inside the frame.
            let x = min(max(CGFloat(cx) * out.width - w / 2, 0), out.width - w)
            let y = min(max((1 - CGFloat(cy)) * out.height - h / 2, 0), out.height - h)
            return (CGRect(x: x, y: y, width: w, height: h), radius)
        }
        let left = s.cameraCorner == .topLeft || s.cameraCorner == .bottomLeft
        let bottom = s.cameraCorner == .bottomLeft || s.cameraCorner == .bottomRight
        let x = left ? margin : out.width - margin - w
        let y = bottom ? margin : out.height - margin - h   // CI: origin bottom-left
        return (CGRect(x: x, y: y, width: w, height: h), radius)
    }

    /// How the camera is shown at `t`: bubble size factor, bubble opacity and full-frame amount.
    /// Layout ranges blend in and out over 0.4 s around their edges.
    static func cameraState(at t: Double, settings s: EditSettings) -> (scale: CGFloat, alpha: Double, full: Double, split: Double) {
        let base = (scale: 1.0, alpha: s.cameraVisible ? 1.0 : 0.0, full: 0.0)
        var r = base
        var split = 0.0
        let blend = 0.4
        for range in s.cameraLayouts {
            let w = RenderInstruction.smooth(min((t - (range.start - blend / 2)) / blend, (range.end + blend / 2 - t) / blend))
            guard w > 0 else { continue }
            let target: (Double, Double, Double)
            switch range.layout {
            case .normal: target = (1, 1, 0)
            case .large: target = (1.9, 1, 0)
            case .fullscreen: target = (1, 1, 1)
            case .hidden: target = (1, 0, 0)
            case .split: target = (1, 0, 0); split += w
            }
            r.scale += w * (target.0 - base.scale)
            r.alpha += w * (target.1 - base.alpha)
            r.full += w * (target.2 - base.full)
        }
        return (CGFloat(max(0.2, r.scale)), min(1, max(0, r.alpha)), min(1, max(0, r.full)), min(1, max(0, split)))
    }

    /// Side by side: the recording's part of the output (Core Image coordinates), nil = all of it.
    static func splitRegions(out: CGSize, split: Double) -> (screen: CGRect, camera: CGRect)? {
        guard split > 0.001 else { return nil }
        let k = CGFloat(min(1, split))
        if out.height > out.width {
            // Portrait: recording at the top, camera below.
            let h = out.height * (1 - 0.46 * k)
            return (CGRect(x: 0, y: out.height - h, width: out.width, height: h), CGRect(x: 0, y: 0, width: out.width, height: out.height - h))
        }
        let w = out.width * (1 - 0.4 * k)
        return (CGRect(x: 0, y: 0, width: w, height: out.height), CGRect(x: w, y: 0, width: out.width - w, height: out.height))
    }

    /// The camera filling a region (side by side layout), with rounded corners.
    private func cameraInRegion(_ raw: CIImage, region: CGRect, settings s: EditSettings, out: CGSize) -> CIImage {
        var cam = raw.transformed(by: CGAffineTransform(translationX: -raw.extent.minX, y: -raw.extent.minY))
        let W = max(1, cam.extent.width), H = max(1, cam.extent.height)
        if s.cameraMirror { cam = cam.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: W, ty: 0)) }
        let short = min(out.width, out.height)
        let pad = CGFloat(s.padding) * short * 0.6
        let r = region.insetBy(dx: pad, dy: pad)
        guard r.width > 4, r.height > 4 else { return .empty() }
        let scale = max(r.width / W, r.height / H)
        cam = cam.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: r.midX - W * scale / 2, y: r.midY - H * scale / 2))
        let radius = CGFloat(s.cornerRadius) * short / 1080 * 1.2
        return cam.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: roundedRect(r, radius: radius, color: .white)])
    }

    /// Mask of the person in a camera frame (Vision, on the Mac), scaled to the frame.
    private func personMask(_ cam: CIImage, calm: Double? = nil, time: Double = 0) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: cam, options: [:])
        guard (try? handler.perform([request])) != nil, let found = request.results?.first?.pixelBuffer else { return nil }
        let mask: CIImage
        if let calm {
            mask = LiveCompositor.maskImage(maskSmoother.blend(found, calm: calm, time: time))
        } else {
            mask = CIImage(cvPixelBuffer: found)
        }
        return mask.transformed(by: CGAffineTransform(scaleX: cam.extent.width / mask.extent.width, y: cam.extent.height / mask.extent.height))
            .transformed(by: CGAffineTransform(translationX: cam.extent.minX, y: cam.extent.minY))
    }

    /// The camera with the picture behind the person (no green screen: the person is found by macOS).
    private func backgrounded(_ cam: CIImage, settings s: EditSettings, time: Double) -> CIImage {
        guard s.cameraShape != .cutout, let file = s.cameraBackground, let back = picture(file),
              let found = personMask(cam, calm: s.cameraBackgroundCalm ?? 0.5, time: time) else { return cam }
        let mask = LiveCompositor.sharpened(found, edge: s.cameraBackgroundEdge ?? 0.5)
        let e = cam.extent
        let scale = max(e.width / max(1, back.extent.width), e.height / max(1, back.extent.height))
        var filled = back.transformed(by: CGAffineTransform(translationX: -back.extent.midX, y: -back.extent.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: e.midX, y: e.midY)))
        // A mirrored camera must not mirror the writing on the picture.
        if s.cameraMirror { filled = filled.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * e.midX, ty: 0)) }
        return cam.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: filled.cropped(to: e),
            kCIInputMaskImageKey: mask.clampedToExtent().applyingGaussianBlur(sigma: 1.2).cropped(to: e),
        ]).cropped(to: e)
    }

    /// The camera filling the whole frame (aspect fill).
    private func fullFrameCamera(_ raw: CIImage, settings s: EditSettings, out: CGSize) -> CIImage {
        var cam = raw.transformed(by: CGAffineTransform(translationX: -raw.extent.minX, y: -raw.extent.minY))
        let W = max(1, cam.extent.width), H = max(1, cam.extent.height)
        if s.cameraMirror { cam = cam.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: W, ty: 0)) }
        let scale = max(out.width / W, out.height / H)
        return cam.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (out.width - W * scale) / 2, y: (out.height - H * scale) / 2))
            .cropped(to: CGRect(origin: .zero, size: out))
    }

    private func cameraBubble(_ raw: CIImage, settings s: EditSettings, out: CGSize, ref: CGFloat, scale bubbleScale: CGFloat = 1) -> CIImage {
        var cam = raw.transformed(by: CGAffineTransform(translationX: -raw.extent.minX, y: -raw.extent.minY))
        let W = max(1, cam.extent.width), H = max(1, cam.extent.height)
        let (rect, radius) = Self.cameraRect(settings: s, out: out, cameraAspect: W / H, scale: bubbleScale)
        if s.cameraMirror {
            cam = cam.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: W, ty: 0))
        }
        // The person without background, standing in the rect (aspect fit, bottom aligned). If the
        // person segmentation of macOS fails, the plain camera picture is shown instead.
        if s.cameraShape == .cutout, let mask = personMask(cam) {
            let person = cam.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                           kCIInputMaskImageKey: mask.applyingGaussianBlur(sigma: 1.2).cropped(to: cam.extent)])
            let scale = min(rect.width / W, rect.height / H)
            var placed = person.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: rect.midX - W * scale / 2, y: rect.minY))
            if s.cameraShadow {
                let shadow = placed.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5)])
                    .applyingGaussianBlur(sigma: 14 * ref)
                placed = placed.composited(over: shadow)
            }
            return placed
        }
        // Aspect fill into the bubble.
        let scale = max(rect.width / W, rect.height / H)
        cam = cam
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: rect.midX - W * scale / 2, y: rect.midY - H * scale / 2))
        let mask = roundedRect(rect, radius: radius, color: .white)
        var bubble = cam.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        // Thin light rim
        let rim = roundedRect(rect, radius: radius, color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.35))
            .applyingFilter("CISourceOutCompositing", parameters: [
                kCIInputBackgroundImageKey: roundedRect(rect.insetBy(dx: 1.5 * ref, dy: 1.5 * ref),
                                                        radius: max(0, radius - 1.5 * ref), color: .white)])
        bubble = rim.composited(over: bubble)
        if s.cameraShadow {
            let shadow = roundedRect(rect, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.55))
                .applyingGaussianBlur(sigma: 18 * ref)
                .transformed(by: CGAffineTransform(translationX: 0, y: -8 * ref))
            bubble = bubble.composited(over: shadow)
        }
        return bubble
    }

    // MARK: Helpers

    private func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let f = CIFilter.roundedRectangleGenerator()
        f.extent = rect
        f.radius = Float(min(radius, min(rect.width, rect.height) / 2))
        f.color = color
        return f.outputImage ?? CIImage.empty()
    }

    /// Screen of the chosen scene and the area the video is fitted into.
    static func sceneRects(_ s: EditSettings, info: RecordingInfo, out: CGSize) -> (screen: CGRect, video: CGRect)? {
        guard let kind = s.mockup else { return nil }
        let video = CGFloat(info.pixelWidth) / CGFloat(max(1, info.pixelHeight))
        let placement = s.mockupPlacement
        let screen = kind.screen(out: out, aspect: video, placement: placement)
        return (screen, kind.videoRegion(screen: screen, placement: placement))
    }

    /// The scene around the video, drawn once for this size.
    private func scene(_ kind: MockupKind?, size: CGSize, screen: CGRect) -> CIImage? {
        guard let kind else { return nil }
        let key = "\(kind.rawValue)|\(Int(size.width))x\(Int(size.height))|\(screen)"
        lock.lock()
        if let cache = sceneCache, cache.key == key { lock.unlock(); return cache.image }
        lock.unlock()
        guard let cg = MockupScene.image(kind, size: size, screen: screen) else { return nil }
        let image = CIImage(cgImage: cg)
        lock.lock()
        sceneCache = (key, image)
        lock.unlock()
        return image
    }

    private func background(style: BackgroundStyle, blur: Double, size: CGSize) -> CIImage {
        let key = "\(style)|\(blur)|\(Int(size.width))x\(Int(size.height))"
        lock.lock()
        if let cache = backgroundCache, cache.key == key { lock.unlock(); return cache.image }
        lock.unlock()

        let rect = CGRect(origin: .zero, size: size)
        var img: CIImage
        switch style {
        case .gradient(let index):
            img = Backgrounds.gradientImage(index: index, size: size)
        case .color(let r, let g, let b):
            img = CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: rect)
        case .image(let path):
            img = Backgrounds.fill(CIImage(contentsOf: URL(fileURLWithPath: path)), size: size)
                ?? Backgrounds.gradientImage(index: 0, size: size)
        }
        if blur > 0.01 {
            img = img.clampedToExtent()
                .applyingGaussianBlur(sigma: blur * 40 * min(size.width, size.height) / 1080)
                .cropped(to: rect)
        }
        // Rasterize once so the per-frame cost is a plain texture draw.
        if let cg = rasterContext.createCGImage(img, from: rect) {
            img = CIImage(cgImage: cg)
        }
        lock.lock()
        backgroundCache = (key, img)
        lock.unlock()
        return img
    }

    /// Built-in arrow, used when no system cursor image was captured.
    static func makeFallbackCursor() -> CursorSprite {
        let scale: CGFloat = 4
        let size = CGSize(width: 20, height: 28)
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        // Flip so we can draw with a top-left origin.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        let path = CGMutablePath()
        let pts: [CGPoint] = [CGPoint(x: 2, y: 2), CGPoint(x: 2, y: 22), CGPoint(x: 7, y: 17.5),
                              CGPoint(x: 10.5, y: 25.5), CGPoint(x: 13.8, y: 24), CGPoint(x: 10.4, y: 16.2),
                              CGPoint(x: 16.5, y: 16.2)]
        path.addLines(between: pts)
        path.closeSubpath()
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.6)
        ctx.drawPath(using: .fillStroke)
        let cg = ctx.makeImage()!
        return CursorSprite(image: CIImage(cgImage: cg), pointSize: size, hotSpot: CGPoint(x: 2, y: 2))
    }

    static func makeRingImage() -> CIImage {
        let n = 256
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let r = CGRect(x: 14, y: 14, width: n - 28, height: n - 28)
        ctx.setFillColor(NSColor(white: 0.5, alpha: 0.18).cgColor)
        ctx.fillEllipse(in: r)
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.4).cgColor)
        ctx.setLineWidth(16)
        ctx.strokeEllipse(in: r)
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.95).cgColor)
        ctx.setLineWidth(8)
        ctx.strokeEllipse(in: r)
        return CIImage(cgImage: ctx.makeImage()!)
    }
}

// MARK: - Layout & camera

/// Where the recording sits inside the output frame (before zoom).
struct FrameLayout {
    let out: CGSize
    let content: CGRect
    let fit: CGFloat
    let ref: CGFloat
    let pad: CGFloat

    /// - Parameter contentY: vertical center of the recording (0 top … 1 bottom), nil = centered.
    /// - Parameter region: the part of the output the recording may use (side by side with the camera).
    init(out: CGSize, sourceSize: CGSize, padding: Double, contentY: Double? = nil, region: CGRect? = nil) {
        self.out = out
        let W = max(1, sourceSize.width), H = max(1, sourceSize.height)
        ref = min(out.width, out.height) / 1080
        pad = padding * min(out.width, out.height)
        let area = region ?? CGRect(origin: .zero, size: out)
        fit = max(0.01, min((area.width - 2 * pad) / W, (area.height - 2 * pad) / H))
        let cw = W * fit, ch = H * fit
        var y = area.minY + (area.height - ch) / 2
        if let contentY, region == nil {
            // Core Image's origin is bottom-left; keep the padding to the edges.
            y = min(max(pad, (1 - CGFloat(contentY)) * out.height - ch / 2), max(pad, out.height - pad - ch))
        }
        content = CGRect(x: area.minX + (area.width - cw) / 2, y: y, width: cw, height: ch)
    }

    /// Normalized capture coordinates (top-left origin) → output coordinates (CI, bottom-left origin).
    func toOutput(_ p: CGPoint) -> CGPoint {
        CGPoint(x: content.minX + p.x * content.width, y: content.minY + (1 - p.y) * content.height)
    }
}

struct Camera {
    var zoom: CGFloat
    /// Point of the unzoomed canvas that ends up in the middle of the output.
    var center: CGPoint
    var transform: CGAffineTransform
}

extension FrameRenderer {
    /// Camera for time `t`. The pan target is computed for the segment's *full* zoom (so its
    /// bounds don't change while zooming) and the pan follows the same eased progress as the
    /// zoom. Position and speed therefore change continuously — no jumps when the zoom ramps.
    /// While ramping the view always stays inside the canvas (offset·p ≤ W/2·(1−1/z) for p ≤ 1).
    static func camera(at t: Double, layout: FrameLayout, segments: [ZoomSegment], motion: MotionPaths) -> Camera {
        let out = layout.out, content = layout.content
        let mid = CGPoint(x: out.width / 2, y: out.height / 2)
        guard let dominant = AutoZoom.dominant(at: t, segments: segments) else {
            return Camera(zoom: 1, center: mid, transform: .identity)
        }
        let scale = CGFloat(dominant.segment.scale)
        let p = CGFloat(dominant.progress)
        let z = 1 + (scale - 1) * p
        guard z > 1.0001 else { return Camera(zoom: 1, center: mid, transform: .identity) }

        // Keep the fully zoomed view inside the recording; center it if the recording is too small.
        // Soft limits: the camera eases into the edge instead of stopping abruptly.
        let soften = 90 * layout.ref
        func clampAxis(_ v: CGFloat, half: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
            let a = lo + half, b = hi - half
            guard a < b else { return (lo + hi) / 2 }
            let k = min(soften, (b - a) / 2)
            guard k > 0.5 else { return min(max(v, a), b) }
            if v > b - k { return b - k * exp(-(v - (b - k)) / k) }
            if v < a + k { return a + k * exp(-((a + k) - v) / k) }
            return v
        }
        let f = layout.toOutput(motion.focus(at: t) ?? CGPoint(x: 0.5, y: 0.5))
        let target = CGPoint(x: clampAxis(f.x, half: out.width / (2 * scale), lo: content.minX, hi: content.maxX),
                             y: clampAxis(f.y, half: out.height / (2 * scale), lo: content.minY, hi: content.maxY))
        let start = CGPoint(x: content.midX, y: content.midY)
        let center = CGPoint(x: start.x + (target.x - start.x) * p,
                             y: start.y + (target.y - start.y) * p)
        let transform = CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: z, y: z))
            .concatenating(CGAffineTransform(translationX: mid.x, y: mid.y))
        return Camera(zoom: z, center: center, transform: transform)
    }
}
