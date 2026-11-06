import Foundation
import CoreImage
import CoreText
import AppKit

/// Renders title + subtitle blocks (CoreText → CIImage) in a `TextDesign`, cached per content and size.
final class TextBlockCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: CIImage] = [:]

    /// - Parameters:
    ///   - titleSize: font size of the title in output pixels.
    ///   - box: draw the design's box behind the text (lower thirds).
    ///   - picture: a picture (logo) shown before the text, with its file name for the cache key.
    func image(title: String, subtitle: String, design: TextDesign, align: TextAlign,
               titleSize: CGFloat, maxWidth: CGFloat, box: Bool, picture: (String, CGImage)? = nil) -> CIImage {
        let key = "\(title)\u{1}\(subtitle)\u{1}\(design.key)\(align.rawValue)\(Int(titleSize))|\(Int(maxWidth))|\(box)|\(picture?.0 ?? "")"
        if let img = lock.withLock({ cache[key] }) { return img }
        let img = Self.render(title: title, subtitle: subtitle, design: design, align: align,
                              titleSize: titleSize, maxWidth: maxWidth, box: box, picture: picture?.1)
        lock.withLock {
            if cache.count > 100 { cache.removeAll() }
            cache[key] = img
        }
        return img
    }

    static func font(_ design: TextDesign, size: CGFloat, weight: TextWeight) -> CTFont {
        let w = NSFont.Weight(rawValue: weight.trait)
        let base = design.font == .condensed ? NSFont.systemFont(ofSize: size, weight: w, width: .condensed)
            : NSFont.systemFont(ofSize: size, weight: w)
        var descriptor = base.fontDescriptor
        let systemDesign: NSFontDescriptor.SystemDesign? = switch design.font {
        case .rounded: .rounded
        case .serif: .serif
        case .mono: .monospaced
        default: nil
        }
        if let systemDesign, let d = descriptor.withDesign(systemDesign) { descriptor = d }
        return (NSFont(descriptor: descriptor, size: size) ?? base) as CTFont
    }

    private static func render(title: String, subtitle: String, design: TextDesign, align: TextAlign,
                               titleSize: CGFloat, maxWidth: CGFloat, box: Bool, picture: CGImage?) -> CIImage {
        let subSize = titleSize * (box ? 0.62 : 0.5)
        let titleFont = font(design, size: titleSize, weight: design.weight)
        let subFont = font(design, size: subSize, weight: .regular)

        var alignment: CTTextAlignment = align == .left ? .left : align == .right ? .right : .center
        var spacing = subtitle.isEmpty ? 0 : titleSize * 0.18
        let paragraph = withUnsafeBytes(of: &alignment) { a in
            withUnsafeBytes(of: &spacing) { sp in
                CTParagraphStyleCreate([
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a.baseAddress!),
                    CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: sp.baseAddress!),
                ], 2)
            }
        }
        let text = NSMutableAttributedString()
        func add(_ string: String, font: CTFont, color: CGColor) {
            text.append(NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            ]))
        }
        var shownTitle = title.isEmpty && subtitle.isEmpty ? " " : title
        if design.uppercaseTitle { shownTitle = shownTitle.uppercased() }
        add(shownTitle, font: titleFont, color: design.titleColor.cgColor)
        if !subtitle.isEmpty {
            add("\n" + subtitle, font: subFont, color: design.subtitleColor.cgColor)
        }

        let hasBox = box && design.hasBox
        let accentW = box && design.accent != nil ? titleSize * 0.16 : 0
        let setter = CTFramesetterCreateWithAttributedString(text)
        // A picture takes the height of the text, left of it (or above it on a title card).
        let picAspect = picture.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 0
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let textW = ceil(fit.width), textH = ceil(fit.height)
        let k = CGFloat(design.padding)
        let padX = (hasBox ? titleSize * 0.6 : titleSize * 0.25) * k
        let padY = (hasBox ? titleSize * 0.42 : titleSize * 0.25) * k
        let gap = titleSize * 0.45
        var picSize = CGSize.zero
        if picture != nil {
            if box {
                let h = max(textH, titleSize * 1.2)
                picSize = CGSize(width: h * picAspect, height: h)
            } else {
                let h = titleSize * 2.2
                picSize = CGSize(width: h * picAspect, height: h)
            }
        }
        let contentW: CGFloat, contentH: CGFloat
        if box {
            contentW = textW + (picture != nil ? picSize.width + gap : 0)
            contentH = max(textH, picSize.height)
        } else {
            contentW = max(textW, picSize.width)
            contentH = textH + (picture != nil ? picSize.height + gap : 0)
        }
        let w = Int(contentW + 2 * padX + accentW), h = Int(contentH + 2 * padY)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .empty() }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        let radius = min(CGFloat(design.cornerRadius) * titleSize, CGFloat(h) / 2)
        let boxPath = CGPath(roundedRect: full, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if hasBox {
            ctx.addPath(boxPath)
            ctx.setFillColor(design.box.cgColor)
            ctx.fillPath()
        }
        if let accent = design.accent, box {
            ctx.saveGState()
            if hasBox { ctx.addPath(boxPath); ctx.clip() }
            ctx.setFillColor(accent.cgColor)
            let barH = hasBox ? CGFloat(h) : contentH
            ctx.fill(CGRect(x: 0, y: (CGFloat(h) - barH) / 2, width: accentW, height: barH))
            ctx.restoreGState()
        }
        if design.shadow || (!hasBox && design.titleColor.r + design.titleColor.g + design.titleColor.b > 1.5) {
            ctx.setShadow(offset: CGSize(width: 0, height: -titleSize * 0.04), blur: titleSize * 0.18,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        }
        var textOrigin = CGPoint(x: padX + accentW, y: padY + (contentH - textH) / 2)
        if let picture {
            let picRect: CGRect
            if box {
                let x: CGFloat = align == .right ? padX + accentW + textW + gap : padX + accentW
                picRect = CGRect(x: x, y: padY + (contentH - picSize.height) / 2, width: picSize.width, height: picSize.height)
                if align != .right { textOrigin.x += picSize.width + gap }
            } else {
                picRect = CGRect(x: padX + (contentW - picSize.width) / 2, y: padY + textH + gap, width: picSize.width, height: picSize.height)
                textOrigin = CGPoint(x: padX + (contentW - textW) / 2, y: padY)
            }
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.interpolationQuality = .high
            ctx.draw(picture, in: picRect)
            ctx.restoreGState()
        } else if !box {
            textOrigin.x = padX + (contentW - textW) / 2
        }
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(origin: textOrigin, size: CGSize(width: textW, height: textH)), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        guard let cg = ctx.makeImage() else { return .empty() }
        return CIImage(cgImage: cg)
    }
}

// MARK: - Captions

extension EditSettings {
    /// Words of a caption with their times: the transcript's times when its words match the
    /// (possibly edited) caption text, otherwise spread over the caption by word length.
    func captionTokens(_ c: Caption) -> [(text: String, start: Double, end: Double)] {
        let tokens = c.text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let spoken = words.filter { $0.start >= c.start - 0.05 && $0.start < c.end }
        if spoken.count == tokens.count {
            return zip(tokens, spoken).map { ($0, $1.start, $1.end) }
        }
        let weights = tokens.map { Double($0.count) + 1 }
        let total = weights.reduce(0, +)
        var t = c.start
        return zip(tokens, weights).map { token, w in
            let length = (c.end - c.start) * w / total
            defer { t += length }
            return (token, t, t + length)
        }
    }

    /// Word groups for the TikTok look: up to three words, a new group after punctuation.
    static func captionGroups(_ tokens: [String]) -> [Range<Int>] {
        var groups: [Range<Int>] = []
        var start = 0
        for i in tokens.indices {
            let count = i - start + 1
            let chars = tokens[start...i].reduce(0) { $0 + $1.count }
            let ends = tokens[i].last.map { ".,!?:;".contains($0) } ?? false
            if count >= 3 || chars >= 16 || ends || i == tokens.count - 1 {
                groups.append(start..<(i + 1))
                start = i + 1
            }
        }
        return groups
    }
}

/// Renders caption blocks in a `CaptionStyle` (one word may be highlighted), cached.
final class CaptionBlockCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: CIImage] = [:]

    func image(words: [String], highlight: Int?, style: CaptionStyle, fontSize: CGFloat, maxWidth: CGFloat) -> CIImage {
        let key = "\(style.key)|\(Int(fontSize))|\(Int(maxWidth))|\(highlight ?? -1)|" + words.joined(separator: "\u{1}")
        if let img = lock.withLock({ cache[key] }) { return img }
        let img = Self.render(words: words, highlight: highlight, style: style, fontSize: fontSize, maxWidth: maxWidth)
        lock.withLock {
            if cache.count > 300 { cache.removeAll() }
            cache[key] = img
        }
        return img
    }

    private static func render(words: [String], highlight: Int?, style s: CaptionStyle, fontSize: CGFloat, maxWidth: CGFloat) -> CIImage {
        var design = TextDesign()
        design.font = s.font
        let font = TextBlockCache.font(design, size: fontSize, weight: s.weight)
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafeBytes(of: &alignment) { ptr in
            CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                            value: ptr.baseAddress!)], 1)
        }
        func attributed(outline: Bool) -> NSAttributedString {
            let text = NSMutableAttributedString()
            for (i, w) in words.enumerated() {
                let word = (s.uppercase ? w.uppercased() : w) + (i < words.count - 1 ? " " : "")
                var attrs: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
                ]
                if outline {
                    attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = 22
                    attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = CGColor(gray: 0, alpha: 0.92)
                } else {
                    attrs[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] =
                        (i == highlight ? s.highlightColor : s.textColor).cgColor
                }
                text.append(NSAttributedString(string: word.isEmpty ? " " : word, attributes: attrs))
            }
            return text
        }
        let fill = attributed(outline: false)
        let setter = CTFramesetterCreateWithAttributedString(fill)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let hasBox = s.box.a > 0.01
        let padX = hasBox ? fontSize * 0.6 : fontSize * 0.3, padY = hasBox ? fontSize * 0.35 : fontSize * 0.25
        let textW = ceil(fit.width) + 2, textH = ceil(fit.height)
        let w = Int(ceil(textW + 2 * padX)), h = Int(ceil(textH + 2 * padY))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .empty() }
        if hasBox {
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: fontSize * 0.45, cornerHeight: fontSize * 0.45, transform: nil))
            ctx.setFillColor(s.box.cgColor)
            ctx.fillPath()
        } else if !s.outline {
            ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.04), blur: fontSize * 0.2, color: CGColor(gray: 0, alpha: 0.7))
        }
        let rect = CGPath(rect: CGRect(x: padX, y: padY, width: textW, height: textH), transform: nil)
        if s.outline {
            CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed(outline: true)),
                                                 CFRange(location: 0, length: 0), rect, nil), ctx)
        }
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), rect, nil), ctx)
        guard let cg = ctx.makeImage() else { return .empty() }
        return CIImage(cgImage: cg)
    }
}
