import SwiftUI
import AppKit

/// Finding words in the transcript and its parts between chapters (no view state: testable).
enum TranscriptTools {
    /// Lower case, without accents ("Möchtest" → "mochtest").
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
    }

    /// The runs of words that contain `query` – also across words ("eine app"), case and accents
    /// ignored – in order, not overlapping.
    static func matches(in words: [String], query: String) -> [ClosedRange<Int>] {
        let q = fold(query).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !q.isEmpty, !words.isEmpty else { return [] }
        var joined = ""
        var starts: [Int] = []
        for (i, w) in words.enumerated() {
            if i > 0 { joined += " " }
            starts.append(joined.utf16.count)
            joined += fold(w.trimmingCharacters(in: .whitespaces))
        }
        let text = joined as NSString, needle = q as NSString
        var result: [ClosedRange<Int>] = []
        var from = 0
        while from < text.length {
            let found = text.range(of: needle as String, options: .literal, range: NSRange(location: from, length: text.length - from))
            guard found.location != NSNotFound else { break }
            let first = (starts.lastIndex { $0 <= found.location }) ?? 0
            let last = (starts.lastIndex { $0 < found.location + found.length }) ?? first
            result.append(first...max(first, last))
            from = found.location + max(1, found.length)
        }
        return result
    }

    /// The words in parts: those before the first chapter (no chapter), then each chapter with
    /// the words from its time to the next one (a chapter without words has an empty part).
    /// `time` maps source times to timeline times, where words and chapters are compared (inside
    /// an inserted clip all of them share a tiny source range).
    static func parts(wordStarts: [Double], chapters: [Chapter], time: (Double) -> Double = { $0 }) -> [(chapter: Chapter?, words: Range<Int>)] {
        let starts = wordStarts.map(time)
        let sorted = chapters.map { ($0, time($0.time)) }.sorted { $0.1 < $1.1 }
        func firstWord(from t: Double) -> Int { starts.firstIndex { $0 >= t - 0.05 } ?? starts.count }
        var parts: [(chapter: Chapter?, words: Range<Int>)] = []
        let lead = sorted.first.map { firstWord(from: $0.1) } ?? starts.count
        if lead > 0 || sorted.isEmpty { parts.append((nil, 0..<lead)) }
        for (k, c) in sorted.enumerated() {
            let a = max(parts.last?.words.upperBound ?? 0, firstWord(from: c.1))
            let b = k + 1 < sorted.count ? max(a, firstWord(from: sorted[k + 1].1)) : starts.count
            parts.append((c.0, a..<b))
        }
        return parts
    }
}

/// What is searched in the transcript, which chapters are folded and where the list should scroll.
@MainActor
final class TranscriptSearch: ObservableObject {
    /// (SCREENKAST_SNAPSHOT_SEARCH: a search for pictures of the panel.)
    @Published var query = ProcessInfo.processInfo.environment["SCREENKAST_SNAPSHOT_SEARCH"] ?? ""
    /// Index of the current match (−1: none chosen yet).
    @Published var current = -1
    /// A word ("w12") or chapter ("c<id>") the transcript scrolls to.
    @Published var scrollTarget: String?
    /// Folded parts ("c<id>", "anfang").
    @Published var collapsed: Set<String> = []
    /// While playing, the list follows the spoken word.
    @Published var follow = true

    static func key(_ chapter: Chapter?) -> String { chapter.map { "c" + $0.id.uuidString } ?? "anfang" }

    // Caches (the panel is drawn again with every frame while playing).
    private var matchKey = "", matchCache: [ClosedRange<Int>] = []
    private var partsKey: [Double] = [], partsChapters: [Chapter] = [], partsCache: [(chapter: Chapter?, words: Range<Int>)] = []

    func matches(_ words: [TranscriptWord]) -> [ClosedRange<Int>] {
        let key = "\(query)|\(words.count)|\(words.first?.start ?? 0)|\(words.last?.end ?? 0)|\(words.last?.text ?? "")"
        if key != matchKey {
            matchKey = key
            matchCache = TranscriptTools.matches(in: words.map(\.text), query: query)
        }
        return matchCache
    }

    func parts(_ words: [TranscriptWord], chapters: [Chapter], time: (Double) -> Double) -> [(chapter: Chapter?, words: Range<Int>)] {
        // Keyed by where words and chapters lie on the timeline (edits move them).
        let key = [Double(words.count), time(words.first?.start ?? 0), time(words.last?.start ?? 0)] + chapters.map { time($0.time) }
        if key != partsKey || chapters != partsChapters {
            partsKey = key
            partsChapters = chapters
            partsCache = TranscriptTools.parts(wordStarts: words.map(\.start), chapters: chapters, time: time)
        }
        return partsCache
    }
}

/// "Skript" page of the inspector: remove pauses and filler words, cut by deleting words.
struct TranscriptPanel: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var search = TranscriptSearch()

    var body: some View {
        let pauses = editor.detectedPauses
        let saved = pauses.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        FoldSection(.pauses, summary: pauses.isEmpty ? "keine gefunden" : String(format: "%d · %.1f s kürzer", pauses.count, saved)) {
            LabeledSlider(title: "Pausen ab", value: $editor.pauseOptions.minPause, range: 0.3...3,
                          format: { String(format: "%.1f s", $0) })
            LabeledSlider(title: "Davon behalten", value: $editor.pauseOptions.keep, range: 0...1,
                          format: { String(format: "%.1f s", $0) })
            LabeledSlider(title: "Empfindlichkeit", value: $editor.pauseOptions.sensitivity, range: 0...1,
                          format: { "\(Int($0 * 100)) %" })
            HStack {
                Text(pauses.isEmpty ? "Keine Pausen gefunden" : String(format: "%d Pausen · %.1f s kürzer", pauses.count, saved))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Schneiden") { editor.removePauses() }
                    .disabled(pauses.isEmpty)
            }
            Text("Findet stille Stellen im Mikrofon. Einzelne Schnitte lassen sich danach in der Timeline anpassen oder mit ⌘Z zurücknehmen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if editor.settings.words.isEmpty {
            Section("Transkript") {
                Text("Erkennt die gesprochenen Wörter (auf dem Mac, nichts wird hochgeladen). Danach lässt sich das Video schneiden, indem man Wörter löscht.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Picker("Sprache", selection: $editor.settings.captionLanguage) {
                        Text("Deutsch").tag("de-DE")
                        Text("Englisch").tag("en-US")
                        Text("Französisch").tag("fr-FR")
                        Text("Spanisch").tag("es-ES")
                        Text("Italienisch").tag("it-IT")
                    }
                    .labelsHidden()
                    Button("Transkript erstellen") { editor.generateCaptions() }
                        .disabled(editor.isGeneratingCaptions)
                }
                if editor.isGeneratingCaptions {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(editor.captionStatus ?? "") }.font(.caption)
                }
                if let error = editor.captionError { Text(error).font(.caption).foregroundStyle(.red) }
            }
        } else {
            let fillers = editor.fillerWordIndices
            FoldSection(.fillers, summary: fillers.isEmpty ? "keine gefunden" : "\(fillers.count) gefunden") {
                HStack {
                    Text(fillers.isEmpty ? "Keine gefunden" : "\(fillers.count) Füllwörter und Wiederholungen")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Entfernen") { editor.removeFillerWords() }
                        .disabled(fillers.isEmpty)
                }
                Text("„äh“, „ähm“ … und doppelte Wörter. Die Spracherkennung schreibt nicht jedes „äh“ mit – Pausen entfernen hilft zusätzlich.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                TranscriptDocument(editor: editor, search: search, fillers: Set(fillers)) { selectionBar }
                Text("Wort anklicken springt dorthin, ⇧-Klick wählt bis dorthin aus, ⌫ schneidet die Auswahl heraus. Kapitel sind Überschriften: der Pfeil klappt ihren Text ein (⌥-Klick: alle).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Transkript").font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if let r = editor.transcriptSelection {
            let removed = r.allSatisfy { editor.isWordRemoved($0) }
            HStack {
                Text("\(r.count) \(r.count == 1 ? "Wort" : "Wörter") ausgewählt").foregroundStyle(.secondary)
                Spacer()
                if removed {
                    Button("Wiederherstellen") { editor.restoreWords(r) }
                } else {
                    Button("Herausschneiden (⌫)") { editor.cutWords(r) }
                }
                Button { editor.transcriptSelection = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
            }
        }
    }
}

/// The transcript like a document: chapters are headings with their text below, each one can be
/// folded. While playing, the part being spoken opens, its word is marked and the list follows.
private struct TranscriptDocument<Selection: View>: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var search: TranscriptSearch
    let fillers: Set<Int>
    @ViewBuilder let selectionBar: () -> Selection

    var body: some View {
        let words = editor.settings.words
        let matches = search.matches(words)
        let parts = search.parts(words, chapters: editor.settings.chapters, time: editor.display)
        let current = editor.currentWordIndex
        let currentPart = current.flatMap { i in parts.first { $0.words.contains(i) } }.map { TranscriptSearch.key($0.chapter) }
        let matched = Set(matches.flatMap { Array($0) })
        searchBar(matches, parts: parts)
        selectionBar()
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        let key = TranscriptSearch.key(part.chapter)
                        let open = !search.collapsed.contains(key)
                        if part.chapter != nil || parts.count > 1 {
                            heading(part, key: key, open: open, parts: parts, speaking: currentPart == key).id(key)
                        }
                        if open && !part.words.isEmpty {
                            WordFlow(editor: editor, range: part.words, current: current, fillers: fillers, matches: matched)
                                .padding(.leading, part.chapter != nil || parts.count > 1 ? 18 : 0)
                                .padding(.bottom, 6)
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 560)
            .onChange(of: search.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
                search.scrollTarget = nil
            }
            // While playing: the part being spoken opens, the list keeps the spoken word in view.
            .onChange(of: currentPart) { _, part in
                guard editor.isPlaying, let part, search.collapsed.contains(part) else { return }
                search.collapsed.remove(part)
            }
            .onChange(of: current) { _, word in
                guard editor.isPlaying, search.follow, let word else { return }
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo("w\(word)", anchor: .center) }
            }
        }
    }

    /// A chapter heading: fold arrow, title (click: go there), where it starts in the video.
    private func heading(_ part: (chapter: Chapter?, words: Range<Int>), key: String, open: Bool,
                         parts: [(chapter: Chapter?, words: Range<Int>)], speaking: Bool) -> some View {
        let title = part.chapter.map { $0.title.isEmpty ? "Kapitel" : $0.title } ?? "Anfang"
        let at = part.chapter.flatMap { editor.outputTime(ofSource: $0.time) } ?? (part.chapter == nil ? 0 : nil)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                let all = NSEvent.modifierFlags.contains(.option)
                let keys = all ? parts.map { TranscriptSearch.key($0.chapter) } : [key]
                if open { search.collapsed.formUnion(keys) } else { search.collapsed.subtract(keys) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Text einklappen (⌥-Klick: alle Kapitel)" : "Text ausklappen (⌥-Klick: alle Kapitel)")
            Text(title)
                .font(.system(size: part.chapter == nil ? 12 : 13.5, weight: .bold))
                .foregroundStyle(part.chapter == nil ? Color.secondary : Color.primary)
                .lineLimit(2)
                .onTapGesture {
                    if editor.isPlaying { editor.pause() }
                    if let c = part.chapter { editor.seek(to: c.time) } else if let first = part.words.first { editor.seek(to: editor.settings.words[first].start) }
                }
                .help("Anklicken springt dorthin")
            if speaking {
                Image(systemName: "speaker.wave.2.fill").font(.caption2).foregroundStyle(Theme.brand)
            }
            Spacer(minLength: 4)
            if !open, !part.words.isEmpty {
                Text("\(part.words.count) Wörter").font(.caption2).foregroundStyle(.tertiary)
            }
            Text(at.map { formatTime($0, fractional: false) } ?? "herausgeschnitten")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
        .padding(.bottom, 3)
        .overlay(alignment: .bottom) {
            if part.chapter != nil { Rectangle().fill(Theme.brand.opacity(speaking ? 0.7 : 0.3)).frame(height: 1) }
        }
    }

    /// Search field with the number of matches, previous and next, follow playback, chapters.
    private func searchBar(_ matches: [ClosedRange<Int>], parts: [(chapter: Chapter?, words: Range<Int>)]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Suchen", text: $search.query, prompt: Text("Im Transkript suchen"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit { step(matches, parts: parts, by: NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                .onChange(of: search.query) { _, _ in showFirst(search.matches(editor.settings.words), parts: parts) }
            if !search.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(matches.isEmpty ? "keine" : "\(max(0, search.current) + 1)/\(matches.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(matches.isEmpty ? Color.red : Color.secondary)
                Button { step(matches, parts: parts, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(matches.isEmpty)
                    .help("Voriger Treffer (⇧↩)")
                Button { step(matches, parts: parts, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(matches.isEmpty)
                    .help("Nächster Treffer (↩)")
            }
            Toggle(isOn: $search.follow) { Image(systemName: "text.line.first.and.arrowtriangle.forward") }
                .toggleStyle(.button)
                .help("Mitlaufen: beim Abspielen bleibt das gesprochene Wort im Blick")
            Menu {
                Button("Alle Kapitel ausklappen") { search.collapsed = [] }
                Button("Alle Kapitel einklappen") { search.collapsed = Set(parts.map { TranscriptSearch.key($0.chapter) }) }
                if !editor.settings.chapters.isEmpty {
                    Divider()
                    ForEach(parts.compactMap(\.chapter)) { c in
                        Button(c.title.isEmpty ? "Kapitel" : c.title) {
                            let key = TranscriptSearch.key(c)
                            search.collapsed.remove(key)
                            search.scrollTarget = key
                            if editor.isPlaying { editor.pause() }
                            editor.seek(to: c.time)
                        }
                    }
                }
            } label: { Image(systemName: "list.bullet.indent") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Kapitel: alle ein- oder ausklappen, zu einem springen")
        }
        .buttonStyle(.borderless)
    }

    /// The part a word belongs to, opened so the word can be seen.
    private func reveal(_ word: Int, parts: [(chapter: Chapter?, words: Range<Int>)]) {
        if let part = parts.first(where: { $0.words.contains(word) }) { search.collapsed.remove(TranscriptSearch.key(part.chapter)) }
    }

    /// While typing: the first match from the playhead on comes into view (nothing is selected).
    private func showFirst(_ matches: [ClosedRange<Int>], parts: [(chapter: Chapter?, words: Range<Int>)]) {
        guard !matches.isEmpty else { search.current = -1; return }
        let words = editor.settings.words
        let T = editor.display(editor.currentTime)
        let i = matches.firstIndex { editor.display(words[$0.lowerBound].start) >= T - 0.05 } ?? 0
        search.current = i
        reveal(matches[i].lowerBound, parts: parts)
        search.scrollTarget = "w\(matches[i].lowerBound)"
    }

    /// The next (or previous) match: selected – ⌫ cuts it – and the playhead goes there.
    private func step(_ matches: [ClosedRange<Int>], parts: [(chapter: Chapter?, words: Range<Int>)], by delta: Int) {
        guard !matches.isEmpty else { return }
        let selected = editor.transcriptSelection.flatMap { s in matches.firstIndex(of: s) }
        let base = selected ?? (search.current >= 0 ? search.current - (delta > 0 ? 1 : -1) : (delta > 0 ? -1 : 0))
        let i = ((base + delta) % matches.count + matches.count) % matches.count
        search.current = i
        let r = matches[i]
        editor.selection = nil
        editor.transcriptSelection = r
        if editor.isPlaying { editor.pause() }
        editor.seek(to: editor.settings.words[r.lowerBound].start)
        reveal(r.lowerBound, parts: parts)
        search.scrollTarget = "w\(r.lowerBound)"
    }
}

/// The words (of one part), wrapped like text; each one can be clicked.
private struct WordFlow: View {
    @ObservedObject var editor: EditorModel
    let range: Range<Int>
    /// The word being spoken.
    let current: Int?
    let fillers: Set<Int>
    /// Words of search matches.
    let matches: Set<Int>

    var body: some View {
        let selection = editor.transcriptSelection
        let words = editor.settings.words
        FlowLayout(spacing: 2, lineSpacing: 3) {
            ForEach(range.clamped(to: 0..<words.count), id: \.self) { i in
                let word = words[i]
                let removed = editor.isWordRemoved(i)
                let selected = selection?.contains(i) ?? false
                Text(word.text.trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 12.5))
                    .strikethrough(removed)
                    .foregroundStyle(removed ? Color.secondary.opacity(0.6) : fillers.contains(i) ? Color.orange : Color.primary)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(selected ? Theme.brand.opacity(0.35) : matches.contains(i) ? Color.orange.opacity(0.3)
                                  : i == current ? Color.yellow.opacity(0.45) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { tap(i) }
                    .id("w\(i)")
            }
        }
    }

    private func tap(_ i: Int) {
        editor.selection = nil
        if NSEvent.modifierFlags.contains(.shift), let r = editor.transcriptSelection {
            editor.transcriptSelection = min(r.lowerBound, i)...max(r.upperBound, i)
        } else {
            editor.transcriptSelection = i...i
            if editor.isPlaying { editor.pause() }
            editor.seek(to: editor.settings.words[i].start)
        }
    }
}

/// Lays out views left to right, wrapping into lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x)
            lineHeight = max(lineHeight, size.height)
        }
        return (positions, CGSize(width: min(width, maxX), height: y + lineHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? 260).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrange(subviews, width: bounds.width).positions
        for (view, p) in zip(subviews, positions) {
            view.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }
}
