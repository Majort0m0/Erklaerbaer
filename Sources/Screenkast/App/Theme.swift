import SwiftUI
import AppKit

/// The look of Erklärbär: colors from the app icon (deep indigo → violet with a yellow focus
/// ring), calm surfaces as rounded cards on a slightly darker canvas, one set of radii and gaps.
enum Theme {
    // MARK: Brand

    /// Violet of the icon – accent of controls (sliders, toggles, prominent buttons).
    static let brand = adaptive(light: NSColor(srgbRed: 0.40, green: 0.27, blue: 0.86, alpha: 1),
                                dark: NSColor(srgbRed: 0.58, green: 0.47, blue: 1.0, alpha: 1))
    /// Deep indigo of the icon.
    static let brandDeep = Color(red: 0.11, green: 0.13, blue: 0.32)
    /// Yellow focus ring of the icon – the selection.
    static let focus = Color(red: 1, green: 0.8, blue: 0.08)
    /// Recording red.
    static let record = Color(red: 1, green: 0.23, blue: 0.23)
    static let brandGradient = LinearGradient(colors: [Color(red: 0.16, green: 0.17, blue: 0.42), Color(red: 0.45, green: 0.27, blue: 0.82)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Surfaces

    /// Window background behind the cards.
    static let canvas = adaptive(light: NSColor(srgbRed: 0.918, green: 0.922, blue: 0.937, alpha: 1),
                                 dark: NSColor(srgbRed: 0.075, green: 0.078, blue: 0.094, alpha: 1))
    /// Cards: preview stage, timeline, inspector, library.
    static let panel = adaptive(light: NSColor(srgbRed: 0.988, green: 0.988, blue: 0.992, alpha: 1),
                                dark: NSColor(srgbRed: 0.125, green: 0.129, blue: 0.149, alpha: 1))
    /// Areas inside a card (lane headers, grouped boxes).
    static let raised = adaptive(light: NSColor(srgbRed: 0.945, green: 0.949, blue: 0.961, alpha: 1),
                                 dark: NSColor(srgbRed: 0.165, green: 0.169, blue: 0.192, alpha: 1))
    /// Stage behind the video.
    static let stage = adaptive(light: NSColor(srgbRed: 0.882, green: 0.886, blue: 0.906, alpha: 1),
                                dark: NSColor(srgbRed: 0.055, green: 0.059, blue: 0.071, alpha: 1))
    /// Hairlines around cards.
    static let stroke = adaptive(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.07))
    /// Empty lanes.
    static let lane = adaptive(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.045))
    static let laneHover = adaptive(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))

    // MARK: Metrics

    /// Gap between the cards and to the window edge.
    static let gap: CGFloat = 10
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 8
    static let laneRadius: CGFloat = 6

    // MARK: Lanes

    /// Color of a timeline lane (header tile and blocks).
    static func color(_ panel: EditorPanel) -> Color {
        switch panel {
        case .video: return .blue
        case .camera: return .cyan
        case .zoom: return .purple
        case .cursor: return Color(red: 0.95, green: 0.62, blue: 0.1)
        case .masks: return .orange
        case .annotations: return .red
        case .texts: return .teal
        case .media: return .mint
        case .captions: return .indigo
        case .logo: return .gray
        }
    }

    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension View {
    /// A card: rounded panel with a hairline and a soft shadow.
    ///
    /// The shadow belongs to the background shape only: a shadow on the whole card would make
    /// macOS render the card's content (live camera, video, hover changes) offscreen again and
    /// again, which shows as flickering white tiles where the mouse moves.
    func card(_ fill: Color = Theme.panel, radius: CGFloat = Theme.cardRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return clipShape(shape)
            .background(shape.fill(fill).shadow(color: .black.opacity(0.06), radius: 6, y: 2))
            .overlay(shape.strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// Small colored square with a symbol (lane headers, lists).
struct IconTile: View {
    let icon: String
    let color: Color
    var size: CGFloat = 18
    var active = true

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(active ? Color.white : color)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(active ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.16))))
    }
}

/// Flat icon button with a soft hover background (toolbars).
struct GhostButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        GhostButtonBody(configuration: configuration, active: active)
    }

    private struct GhostButtonBody: View {
        let configuration: Configuration
        let active: Bool
        @Environment(\.isEnabled) private var enabled
        @StateObject private var hover = HoverFlag()

        var body: some View {
            configuration.label
                .foregroundStyle(active ? Theme.brand : enabled ? Color.primary.opacity(0.82) : Color.secondary.opacity(0.45))
                .padding(.horizontal, 6)
                .frame(minHeight: 28)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(active ? Theme.brand.opacity(0.15)
                          : configuration.isPressed ? Theme.laneHover.opacity(1.6) : hover.on && enabled ? Theme.laneHover : .clear))
                .contentShape(Rectangle())
                .onHover { hover.on = $0 }
        }
    }
}

/// Hover state for views that can't use @State (no macros with the Command Line Tools).
final class HoverFlag: ObservableObject {
    @Published var on = false
}
