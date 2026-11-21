import SwiftUI
import AppKit

/// Which logo shows its settings (popover in the control window).
final class LiveOverlayEditing: ObservableObject {
    @Published var logo: UUID?
}

/// The saved logos and banners as a row of tiles: a click shows or hides one.
struct LiveOverlayStrip: View {
    @ObservedObject var live: LiveModel
    @ObservedObject var library: LiveOverlayLibrary
    @StateObject private var editing = LiveOverlayEditing()

    private let tileHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Logos und Banner").font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    Button("Logos hinzufügen …") { live.addLogos() }
                    Button("Banner erstellen …") { live.newBanner() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Logos aus Bilddateien hinzufügen oder einen Banner mit Name und Logo erstellen")
            }
            if library.logos.isEmpty && library.banners.isEmpty {
                Text("Speichere hier Logos und Banner (ein Streifen mit Name und Logo). Dann blendest du sie mit einem Klick ein und wechselst zwischen ihnen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(library.logos) { logoTile($0) }
                        ForEach(library.banners) { bannerTile($0) }
                    }
                    .padding(2)
                }
                .frame(height: tileHeight + 4)
            }
        }
    }

    private func tile<Content: View>(active: Bool, width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.lane)
            content()
        }
        .frame(width: width, height: tileHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(active ? Theme.focus : Theme.stroke, lineWidth: active ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if active {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.black, Theme.focus)
                    .offset(x: 3, y: -3)
            }
        }
        .contentShape(Rectangle())
    }

    private func logoTile(_ logo: LiveLogo) -> some View {
        let active = live.shownLogoID == logo.id
        return Button { live.toggle(logo: logo) } label: {
            tile(active: active, width: 58) {
                if let image = library.thumbnail(logo) {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(6)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help("\(logo.name): Klick blendet das Logo ein oder aus. Rechtsklick: anpassen oder löschen.")
        .contextMenu {
            Button("Anpassen …") { editing.logo = logo.id }
            Divider()
            Button("Löschen", role: .destructive) { library.remove(logo: logo.id) }
        }
        .popover(isPresented: Binding(get: { editing.logo == logo.id }, set: { if !$0 { editing.logo = nil } }), arrowEdge: .bottom) {
            LiveLogoSettings(library: library, logoID: logo.id)
        }
    }

    private func bannerTile(_ banner: LiveBanner) -> some View {
        let active = live.shownBannerID == banner.id
        return Button { live.toggle(banner: banner) } label: {
            tile(active: active, width: 124) {
                if let image = library.bannerThumbnail(banner) {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Banner „\(banner.label)“: Klick blendet ihn ein oder aus. Rechtsklick: bearbeiten, duplizieren oder löschen.")
        .contextMenu {
            Button("Bearbeiten …") { live.editBanner(banner.id) }
            Button("Duplizieren") { if let copy = library.duplicate(banner: banner.id) { live.editBanner(copy.id) } }
            Divider()
            Button("Löschen", role: .destructive) { library.remove(banner: banner.id) }
        }
    }
}

/// Corner, size and opacity of a logo.
struct LiveLogoSettings: View {
    @ObservedObject var library: LiveOverlayLibrary
    let logoID: UUID

    private func binding<Value>(_ path: WritableKeyPath<LiveLogo, Value>, _ fallback: Value) -> Binding<Value> {
        Binding(get: { library.logo(logoID)?[keyPath: path] ?? fallback },
                set: { value in
                    guard var logo = library.logo(logoID) else { return }
                    logo[keyPath: path] = value
                    library.update(logo)
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(library.logo(logoID)?.name ?? "Logo").font(.headline).lineLimit(1)
            Picker("Ecke", selection: binding(\.corner, .topRight)) {
                ForEach(CameraCorner.allCases) { Text($0.label).tag($0) }
            }
            LabeledSlider(title: "Größe", value: binding(\.size, 0.14), range: 0.05...0.4, format: { "\(Int($0 * 100)) %" })
            LabeledSlider(title: "Deckkraft", value: binding(\.opacity, 0.9), range: 0.2...1, format: { "\(Int($0 * 100)) %" })
        }
        .padding(14)
        .frame(width: 260)
    }
}

/// A banner in its own window, with a preview in a 16:9 frame.
struct LiveBannerEditor: View {
    @ObservedObject var live: LiveModel
    @ObservedObject var library: LiveOverlayLibrary
    let bannerID: UUID

    private let previewWidth: CGFloat = 520

    private func binding<Value>(_ path: WritableKeyPath<LiveBanner, Value>, _ fallback: Value) -> Binding<Value> {
        Binding(get: { library.banner(bannerID)?[keyPath: path] ?? fallback },
                set: { value in
                    guard var banner = library.banner(bannerID) else { return }
                    banner[keyPath: path] = value
                    library.update(banner)
                })
    }

    private func colorBinding(_ path: WritableKeyPath<LiveBanner, RGBAColor>, _ fallback: RGBAColor) -> Binding<Color> {
        let inner = binding(path, fallback)
        return Binding(get: { inner.wrappedValue.color }, set: { inner.wrappedValue = RGBAColor($0) })
    }

    var body: some View {
        if let banner = library.banner(bannerID) {
            VStack(alignment: .leading, spacing: 12) {
                preview(banner)
                TextField("Zeile 1, z. B. dein Name", text: binding(\.title, ""))
                    .textFieldStyle(.roundedBorder)
                TextField("Zeile 2 (kann leer bleiben), z. B. Rolle oder Webseite", text: binding(\.subtitle, ""))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Picker("Logo rechts", selection: binding(\.logoID, nil)) {
                        Text("Ohne").tag(UUID?.none)
                        ForEach(library.logos) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Button("Logo hinzufügen …") {
                        if let added = live.pickLogos().first { binding(\.logoID, nil).wrappedValue = added.id }
                    }
                }
                HStack(spacing: 16) {
                    Picker("Position", selection: binding(\.atTop, false)) {
                        Text("Unten").tag(false)
                        Text("Oben").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    Picker("Schrift", selection: binding(\.font, .system)) {
                        ForEach(TextFont.allCases) { Text($0.label).tag($0) }
                    }
                }
                LabeledSlider(title: "Höhe", value: binding(\.height, 0.11), range: 0.06...0.2, format: { "\(Int($0 * 100)) % des Bildes" })
                HStack(spacing: 16) {
                    ColorPicker("Hintergrund", selection: colorBinding(\.background, LiveBanner().background), supportsOpacity: true)
                    ColorPicker("Text", selection: colorBinding(\.text, .white), supportsOpacity: false)
                    Toggle("Linie", isOn: Binding(get: { banner.accent != nil }, set: { on in
                        binding(\.accent, nil).wrappedValue = on ? (LiveBanner().accent ?? .white) : nil
                    }))
                    .help("Eine dünne Linie auf der Seite zum Bild hin")
                    if banner.accent != nil {
                        ColorPicker("", selection: Binding(get: { (banner.accent ?? .white).color },
                                                           set: { binding(\.accent, nil).wrappedValue = RGBAColor($0) }), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
                Divider()
                HStack {
                    Button("Löschen", role: .destructive) {
                        library.remove(banner: bannerID)
                        live.closeBannerEditor()
                    }
                    Spacer()
                    Button(live.shownBannerID == bannerID ? "Im Live-Bild ausblenden" : "Im Live-Bild zeigen") { live.toggle(banner: banner) }
                    Button("Fertig") { live.closeBannerEditor() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(width: previewWidth + 36)
            .tint(Theme.brand)
        } else {
            Text("Dieser Banner wurde gelöscht.").padding(30)
        }
    }

    /// The banner where it will lie in the picture.
    private func preview(_ banner: LiveBanner) -> some View {
        let height = previewWidth * 9 / 16
        return ZStack(alignment: banner.atTop ? .top : .bottom) {
            LinearGradient(colors: [Color(white: 0.32), Color(white: 0.18)], startPoint: .top, endPoint: .bottom)
            Text("Live-Bild").font(.title3).foregroundStyle(.white.opacity(0.35)).frame(maxWidth: .infinity, maxHeight: .infinity)
            if let image = library.bannerPicture(library.resolved(banner)) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: previewWidth)
            }
        }
        .frame(width: previewWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
