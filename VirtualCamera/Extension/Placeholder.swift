import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// What the camera shows while Erklärbär sends no live picture.
enum Placeholder {
    static func picture(width: Int, height: Int) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &made) == kCVReturnSuccess,
              let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height), s = h / 1080

        // Deep indigo to violet with the yellow ring, like the app icon.
        let colors = [CGColor(srgbRed: 0.16, green: 0.17, blue: 0.42, alpha: 1), CGColor(srgbRed: 0.45, green: 0.27, blue: 0.82, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        }
        let center = CGPoint(x: w / 2, y: h * 0.6)
        let radius = 120 * s
        context.setFillColor(CGColor(srgbRed: 0.11, green: 0.13, blue: 0.32, alpha: 0.55))
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        context.setStrokeColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.08, alpha: 1))
        context.setLineWidth(12 * s)
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))

        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        draw("🐻", font: CTFontCreateWithName("Apple Color Emoji" as CFString, 130 * s, nil), color: white, centerX: center.x, centerY: center.y, in: context)
        let regular = CTFontCreateUIFontForLanguage(.system, 40 * s, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 40 * s, nil)
        let title = CTFontCreateUIFontForLanguage(.emphasizedSystem, 92 * s, nil) ?? regular
        draw("Erklärbär", font: title, color: white, centerX: w / 2, centerY: h * 0.33, in: context)
        draw("Starte in Erklärbär den Live-Modus – dann erscheint hier dein Live-Bild.", font: regular,
             color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.82), centerX: w / 2, centerY: h * 0.23, in: context)
        return buffer
    }

    private static func draw(_ text: String, font: CTFont, color: CGColor, centerX: CGFloat, centerY: CGFloat, in context: CGContext) {
        let attributes = [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: color] as [NSAttributedString.Key: Any]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: centerX - bounds.width / 2 - bounds.minX, y: centerY - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
    }
}
