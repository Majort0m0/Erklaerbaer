import SwiftUI

/// Selected topic and search of the help window (shared, so other views can open a topic).
@MainActor
final class HelpModel: ObservableObject {
    static let shared = HelpModel()
    @Published var selection: String? = HelpContent.topics.first?.id
    @Published var query = ""

    var filtered: [HelpTopic] { HelpContent.topics.filter { $0.matches(query) } }
}

/// Opens the help window (on a topic).
struct HelpButton: View {
    var topic: String? = nil
    var title = "Hilfe"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            if let topic { HelpModel.shared.selection = topic }
            openWindow(id: "help")
        } label: {
            Label(title, systemImage: "questionmark.circle")
        }
        .help("Erklärbär-Hilfe öffnen (⌘?)")
    }
}

/// "Erklärbär-Hilfe": topics on the left (with search), the page on the right.
struct HelpView: View {
    @ObservedObject var model = HelpModel.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.filtered) { topic in
                    HStack(spacing: 9) {
                        IconTile(icon: topic.icon, color: topic.color, size: 22)
                        Text(topic.title).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(topic.id)
                }
            }
            .searchable(text: $model.query, placement: .sidebar, prompt: "Hilfe durchsuchen")
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            if let id = model.selection, let topic = HelpContent.topic(id) {
                HelpPage(topic: topic, query: model.query) { next in model.selection = next }
                    .id(topic.id)
            } else {
                ContentUnavailableView("Kein Thema gefunden", systemImage: "magnifyingglass",
                                       description: Text("Anderen Suchbegriff versuchen."))
            }
        }
        .tint(Theme.brand)
        .onChange(of: model.query) { _, _ in
            // Searching shows the first matching topic.
            if let first = model.filtered.first, !model.filtered.contains(where: { $0.id == model.selection }) {
                model.selection = first.id
            }
        }
    }
}

/// One help page.
struct HelpPage: View {
    let topic: HelpTopic
    var query = ""
    let open: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    IconTile(icon: topic.icon, color: topic.color, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(topic.title).font(.largeTitle.weight(.bold))
                        Text(topic.summary).font(.title3).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 6)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    HelpBlockView(block: block)
                }
                nextTopic
            }
            .textSelection(.enabled)
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.panel)
    }

    @ViewBuilder
    private var nextTopic: some View {
        let all = HelpContent.topics
        if let i = all.firstIndex(where: { $0.id == topic.id }), i + 1 < all.count {
            let next = all[i + 1]
            Button {
                open(next.id)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Weiter").font(.caption).foregroundStyle(.secondary)
                        Text(next.title).font(.headline)
                    }
                    Spacer()
                    Image(systemName: "arrow.right").foregroundStyle(Theme.brand)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
        }
    }
}

/// Renders one block of a help page.
struct HelpBlockView: View {
    let block: HelpBlock

    var body: some View {
        switch block {
        case .text(let s):
            Text(markdown(s)).font(.body).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            Text(s).font(.title2.weight(.semibold)).padding(.top, 10)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(Theme.brand.opacity(0.7)).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        Text(markdown(item)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .steps(let items):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(i + 1)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Theme.brand.gradient))
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
                        Text(markdown(item)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .tip(let s):
            callout(icon: "lightbulb.fill", color: Theme.focus, title: "Tipp", text: s)
        case .note(let s):
            callout(icon: "info.circle.fill", color: Theme.brand, title: nil, text: s)
        case .keys(let keys):
            VStack(spacing: 0) {
                ForEach(Array(keys.enumerated()), id: \.offset) { i, key in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(key.0)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke, lineWidth: 1))
                            .frame(width: 170, alignment: .leading)
                        Text(key.1).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    if i < keys.count - 1 { Divider().padding(.leading, 12) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
        }
    }

    private func callout(icon: String, color: Color, title: String?, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 15))
            Text(markdown((title.map { "**\($0):** " } ?? "") + text)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.3), lineWidth: 1))
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
