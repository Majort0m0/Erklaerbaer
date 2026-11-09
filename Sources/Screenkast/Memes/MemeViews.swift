import AppKit
import SwiftUI

/// The ten places. A click plays a filled place; an empty one asks what to put there.
struct MemeBoardView: View {
    @ObservedObject var board = MemeBoard.shared
    /// Digit keys press the places (where the surrounding view does not handle them itself).
    var usesKeys = false
    let play: (MemeSlot) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(0..<MemeBoard.count, id: \.self) { tile($0) }
            }
            if let problem = board.problem {
                Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !board.credits.isEmpty {
                Button("Quellenangaben kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(board.credits, forType: .string)
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Autoren und Lizenzen der belegten Plätze, zum Beispiel für die Videobeschreibung")
            }
        }
    }

    private func key(_ i: Int) -> String { String((i + 1) % 10) }

    @ViewBuilder
    private func tile(_ i: Int) -> some View {
        let slot = board.slots[i]
        let button = Button {
            if let slot { play(slot) } else { MemeSearchWindow.shared.open(slot: i) }
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.lane)
                if board.busy.contains(i) {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let slot, let image = board.thumbnail(of: slot) {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(height: 42).frame(maxWidth: .infinity).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    Image(systemName: "plus").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text(key(i))
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(3)
            }
            .frame(height: 42)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(slot.map { "\($0.title) (Taste \(key(i))) – Rechtsklick zum Ändern" } ?? "Platz \(key(i)): klicken, um ein Meme zu suchen oder eine eigene Datei zu wählen")
        .contextMenu {
            Button("Meme suchen …") { MemeSearchWindow.shared.open(slot: i) }
            Button("Eigene Datei …") { board.chooseFile(for: i) }
            if slot != nil {
                Divider()
                Button("Platz leeren") { board.clear(i) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await board.assign(i, file: url) }
            return true
        }
        if usesKeys, let digit = key(i).first {
            button.keyboardShortcut(KeyEquivalent(digit), modifiers: [])
        } else {
            button
        }
    }
}

/// Window for finding something for one place.
@MainActor
final class MemeSearchWindow: NSObject, ObservableObject {
    static let shared = MemeSearchWindow()
    @Published var slot = 0
    @Published var query = ""
    @Published var results: [MemeResult] = []
    @Published var searching = false
    @Published var message: String?
    private var window: NSWindow?

    func open(slot: Int) {
        self.slot = slot
        let window = self.window ?? makeWindow()
        self.window = window
        window.title = "Meme für Platz \((slot + 1) % 10)"
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.sharingType = .none   // not to be seen in a meeting
        window.contentView = NSHostingView(rootView: MemeSearchView(model: self))
        window.center()
        return window
    }

    func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searching = true
        message = nil
        Task {
            defer { searching = false }
            do {
                results = try await MemeSearch.search(text)
                if results.isEmpty { message = "Nichts gefunden. Englische Suchbegriffe liefern meist mehr." }
            } catch {
                message = "Die Suche hat nicht geklappt: \(error.localizedDescription)"
            }
        }
    }

    func choose(_ result: MemeResult) {
        let place = slot
        window?.orderOut(nil)
        Task { await MemeBoard.shared.assign(place, result: result) }
    }

    func chooseOwnFile() {
        window?.orderOut(nil)
        MemeBoard.shared.chooseFile(for: slot)
    }
}

struct MemeSearchView: View {
    @ObservedObject var model: MemeSearchWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Suchen, am besten auf Englisch (z. B. cat, dance, thumbs up)", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.search() }
                Button("Suchen") { model.search() }.keyboardShortcut(.defaultAction)
                Button("Eigene Datei …") { model.chooseOwnFile() }
            }
            Text("Freie Inhalte von Openverse und Wikimedia Commons. Bei vielen Lizenzen musst du im Video die Quelle nennen, die Angaben kannst du unter dem Board kopieren.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.searching { ProgressView().frame(maxWidth: .infinity) }
            if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 10)], spacing: 10) {
                    ForEach(model.results) { result in
                        Button { model.choose(result) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                AsyncImage(url: result.preview) { image in
                                    image.resizable().scaledToFit()   // uncut: the real format is what will be shown
                                } placeholder: {
                                    Rectangle().fill(Theme.lane)
                                }
                                .frame(height: 96).frame(maxWidth: .infinity).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                Text(result.title).font(.caption).lineLimit(1)
                                Text(result.license).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(result.credit)
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 480, minHeight: 380)
        .tint(Theme.brand)
    }
}
