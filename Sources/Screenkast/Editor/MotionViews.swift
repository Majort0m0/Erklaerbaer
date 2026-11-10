import SwiftUI

/// Layer and keyframes of a picture or video.
struct MotionSection: View {
    @ObservedObject var editor: EditorModel
    let target: MotionTarget
    var showsVolume = false

    var body: some View {
        let keys = editor.keys(target)
        Section("Ebene und Bewegung") {
            Stepper("Medien-Spur \(editor.lane(target) + 1)", value: Binding(get: { editor.lane(target) + 1 }, set: { editor.setLane(target, $0 - 1) }), in: 1...EditSettings.maxMediaLanes)
                .help("Höhere Spuren liegen im Bild weiter oben. Auch durch Ziehen nach oben oder unten in der Timeline.")
            Button { editor.addKey(target) } label: { Label("Keyframe am Abspielkopf", systemImage: "diamond") }
            if keys.isEmpty {
                Text("Setze an zwei Stellen einen Keyframe und ändere dazwischen Position oder Größe im Vorschaubild: Der Clip bewegt sich dann von selbst.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                LabeledSlider(title: "Deckkraft hier", value: Binding(get: { Motion.value(keys, at: editor.clipTime(target))?.opacity ?? 1 }, set: { editor.place(target, opacity: $0) }),
                              range: 0.05...1, format: { "\(Int($0 * 100)) %" })
                if showsVolume {
                    LabeledSlider(title: "Lautstärke hier", value: Binding(get: { Motion.value(keys, at: editor.clipTime(target))?.volume ?? 1 }, set: { editor.place(target, volume: $0) }),
                                  range: 0...1, format: { "\(Int($0 * 100)) %" })
                }
                ForEach(keys) { key in
                    HStack {
                        Image(systemName: "diamond.fill").font(.system(size: 9)).foregroundStyle(Theme.focus)
                        Text(String(format: "%.1f s", key.t)).monospacedDigit()
                        Spacer()
                        Button { editor.removeKey(target, key.id) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                }
                Button("Alle Keyframes entfernen", role: .destructive) { editor.clearKeys(target) }
            }
        }
    }
}

/// Keyframes of a mask: set by hand, or found by following the content.
struct MaskFollowRow: View {
    @ObservedObject var editor: EditorModel
    let mask: BlurMask

    var body: some View {
        let count = mask.track?.count ?? 0
        let here = editor.maskKey(mask.id) != nil
        Section("Bewegung") {
            Button { editor.addMaskKey(mask.id) } label: { Label(here ? "Keyframe hier neu setzen" : "Keyframe am Abspielkopf", systemImage: "diamond") }
            if count == 0 {
                Text("Für etwas, das sich bewegt: an zwei oder mehr Stellen einen Keyframe setzen und die Maske dort im Vorschaubild verschieben und in der Größe ändern. Dazwischen wandert sie gleichmäßig mit.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Button { editor.jumpMaskKey(mask.id, forward: false) } label: { Image(systemName: "chevron.left") }
                        .help("Zum vorigen Keyframe")
                    Text("\(count) Keyframe\(count == 1 ? "" : "s")").monospacedDigit()
                    Button { editor.jumpMaskKey(mask.id, forward: true) } label: { Image(systemName: "chevron.right") }
                        .help("Zum nächsten Keyframe")
                    Spacer()
                    if here {
                        Button("Hier löschen") { editor.removeMaskKey(mask.id) }
                    }
                }
                Text("Verschieben oder Größe ändern im Vorschaubild setzt einen Keyframe an der Stelle des Abspielkopfs. Mit gedrückter ⌥-Taste wandert der ganze Weg mit.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Alle Keyframes entfernen", role: .destructive) { editor.clearMaskKeys(mask.id) }
            }
            if editor.trackingMask == mask.id {
                ProgressView("Wird verfolgt …").controlSize(.small)
            } else {
                Button { editor.trackMask(mask.id) } label: { Label("Automatisch verfolgen", systemImage: "scope") }
                    .disabled(editor.trackingMask != nil)
                    .help("Setzt Keyframes, indem es dem Inhalt folgt. Klappt gut bei ruhigen Bewegungen; bei schnellen danach von Hand nachbessern.")
            }
            if let message = editor.maskMessage {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
