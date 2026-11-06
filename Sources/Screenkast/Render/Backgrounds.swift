import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import SwiftUI

/// Background presets (own color pairs, no third-party assets).
enum Backgrounds {
    struct Preset {
        var name: String
        var from: (Double, Double, Double)
        var to: (Double, Double, Double)
    }

    static let presets: [Preset] = [
        Preset(name: "Abendrot", from: (0.98, 0.45, 0.37), to: (0.99, 0.74, 0.45)),
        Preset(name: "Ozean", from: (0.10, 0.45, 0.72), to: (0.40, 0.84, 0.92)),
        Preset(name: "Violett", from: (0.36, 0.16, 0.58), to: (0.66, 0.36, 0.98)),
        Preset(name: "Mitternacht", from: (0.05, 0.10, 0.16), to: (0.18, 0.31, 0.40)),
        Preset(name: "Minze", from: (0.07, 0.56, 0.52), to: (0.30, 0.88, 0.55)),
        Preset(name: "Pfirsich", from: (0.92, 0.58, 0.63), to: (1.00, 0.87, 0.85)),
        Preset(name: "Graphit", from: (0.13, 0.14, 0.15), to: (0.28, 0.29, 0.31)),
        Preset(name: "Dämmerung", from: (0.27, 0.40, 0.86), to: (0.69, 0.42, 0.70)),
    ]

    static func gradientImage(index: Int, size: CGSize) -> CIImage {
        let p = presets[max(0, min(presets.count - 1, index))]
        let rect = CGRect(origin: .zero, size: size)
        let g = CIFilter.linearGradient()
        g.point0 = CGPoint(x: 0, y: size.height)
        g.point1 = CGPoint(x: size.width, y: 0)
        g.color0 = CIColor(red: p.from.0, green: p.from.1, blue: p.from.2)
        g.color1 = CIColor(red: p.to.0, green: p.to.1, blue: p.to.2)
        var img = (g.outputImage ?? CIImage(color: .gray)).cropped(to: rect)

        // Soft light spot for depth.
        let r = CIFilter.radialGradient()
        r.center = CGPoint(x: size.width * 0.25, y: size.height * 0.85)
        r.radius0 = 0
        r.radius1 = Float(max(size.width, size.height) * 0.75)
        r.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.22)
        r.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        if let light = r.outputImage?.cropped(to: rect) {
            img = light.composited(over: img)
        }
        return img
    }

    /// Scale an image to cover `size` (aspect fill, centered).
    static func fill(_ image: CIImage?, size: CGSize) -> CIImage? {
        guard let image, image.extent.width > 0, image.extent.height > 0, image.extent.isInfinite == false else { return nil }
        let e = image.extent
        let scale = max(size.width / e.width, size.height / e.height)
        let w = e.width * scale, h = e.height * scale
        return image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (size.width - w) / 2, y: (size.height - h) / 2))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// File URL of the user's current desktop picture (call on the main thread).
    @MainActor static func wallpaperURL() -> URL? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              CIImage(contentsOf: url) != nil else { return nil }
        return url
    }

    /// SwiftUI swatch for the picker.
    static func swatch(index: Int) -> LinearGradient {
        let p = presets[index]
        return LinearGradient(colors: [Color(red: p.from.0, green: p.from.1, blue: p.from.2),
                                       Color(red: p.to.0, green: p.to.1, blue: p.to.2)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
