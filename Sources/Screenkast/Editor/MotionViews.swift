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

/// Lets a mask follow what it covers.
struct MaskFollowRow: View {
    @ObservedObject var editor: EditorModel
    let mask: BlurMask

    var body: some View {
        Section("Inhalt verfolgen") {
            if editor.trackingMask == mask.id {
                ProgressView("Wird verfolgt …").controlSize(.small)
            } else {
                Button { editor.trackMask(mask.id) } label: { Label(mask.track == nil ? "Maske dem Inhalt folgen lassen" : "Neu verfolgen", systemImage: "scope") }
                    .disabled(editor.trackingMask != nil)
                    .help("Setze die Maske am Anfang ihres Bereichs auf den Inhalt. Sie wandert dann mit, wenn er sich bewegt, zum Beispiel beim Scrollen.")
                if mask.track != nil {
                    Button("Verfolgung entfernen", role: .destructive) { editor.updateMask(id: mask.id) { $0.track = nil } }
                }
            }
            if let message = editor.maskMessage {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
