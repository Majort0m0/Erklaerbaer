import AppKit
import SwiftUI

/// One meter that follows the levels (only it redraws a dozen times a second).
private struct SourceMeter: View {
    @ObservedObject var levels: LiveLevels
    let pick: @MainActor (LiveLevels) -> Float
    var width: CGFloat = 70

    var body: some View {
        LevelMeter(level: pick(levels)).frame(width: width, height: 6)
    }
}

/// The sound in short, inside the live control window: levels, mute and the way to the mixer.
struct LiveSoundStrip: View {
    @ObservedObject var live: LiveModel
    @ObservedObject var audio: LiveAudio

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("Ton").font(.subheadline.weight(.semibold))
                Image(systemName: "mic").foregroundStyle(.secondary).font(.caption)
                SourceMeter(levels: audio.levels, pick: { $0.voice }, width: 54)
                    .help("Deine Stimme")
                if audio.meetingState == .running {
                    Image(systemName: "person.2").foregroundStyle(.secondary).font(.caption)
                    SourceMeter(levels: audio.levels, pick: { $0.meeting }, width: 54)
                        .help("Was ins Meeting geht")
                }
                Spacer(minLength: 4)
                Button {
                    audio.toggleMute()
                } label: {
                    Label(audio.settings.muted ? "Stumm" : "Stumm", systemImage: audio.settings.muted ? "mic.slash.fill" : "mic.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(audio.settings.muted ? Theme.record : .primary)
                }
                .keyboardShortcut("m", modifiers: [])
                .help(audio.settings.muted ? "Deine Stimme geht nicht ins Meeting. Wieder einschalten (Taste M)" : "Deine Stimme im Meeting stumm schalten (Taste M)")
                Button("Mischpult") { live.openMixer() }
                    .help("Lautstärke jeder Quelle fürs Meeting und für dein Ohr")
            }
            if let ear = audio.ear {
                Label(ear.headphones ? "Im Ohr: \(ear.name)" : "Lautsprecher: \(ear.name)", systemImage: ear.headphones ? "headphones" : "speaker.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ForEach(LiveSoundNotes.notes(live: live, audio: audio, short: true), id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Hints about the sound that need attention.
enum LiveSoundNotes {
    @MainActor
    static func notes(live: LiveModel, audio: LiveAudio, short: Bool) -> [String] {
        var result: [String] = []
        if !live.microphoneID.isEmpty, AudioDevices.isBluetoothMicrophone(uniqueID: live.microphoneID) {
            result.append(short ? "Du sprichst über das Bluetooth-Mikrofon: Die Kopfhörer klingen dann dumpf. Besser das Mikrofon des Macs wählen."
                                : "Du sprichst über das Mikrofon der AirPods (Bluetooth). Dann schalten sie in den Telefon-Modus und klingen dumpf, auch im Ohr. Besser: mit dem Mikrofon des Macs sprechen und die AirPods nur zum Hören nutzen.")
        }
        if let problem = audio.earProblem { result.append(problem) }
        if case .failed(let text) = audio.meetingState { result.append(text) }
        if !short, let problem = audio.appProblem { result.append(problem) }
        return result
    }
}

/// The mixer: every source with its level, its volume in the meeting and in the ear.
struct LiveMixerView: View {
    @ObservedObject var live: LiveModel
    @ObservedObject var audio: LiveAudio
    @ObservedObject private var mic = VirtualMicrophone.shared

    private let sliderWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text("Quelle")
                    Text("Pegel")
                    Text("Ins Meeting")
                    Text("Ins Ohr")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider()
                channel(icon: "mic", title: "Stimme", detail: microphoneName, meter: { $0.voice }, value: $audio.settings.voice,
                        earAllowed: audio.voiceInEarAllowed,
                        earHelp: audio.voiceInEarAllowed ? "Dich selbst leise mithören. Meist besser aus." : "Nur mit Kopfhörern: Aus Lautsprechern nähme das Mikrofon deine Stimme wieder auf.")
                if live.isDeviceSource {
                    channel(icon: "ipad", title: "iPad", detail: nil, meter: { $0.device }, value: $audio.settings.device, earAllowed: true, earHelp: "Den Ton des iPads hören")
                }
                channel(icon: "face.smiling", title: "Memes", detail: nil, meter: { $0.memes }, value: $audio.settings.memes, earAllowed: true, earHelp: "Den Ton der Memes hören")
                Divider()
                GridRow {
                    Text("Programme").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Color.clear.frame(width: 1, height: 1)
                    Text("Nur eingeschaltete gehen ins Meeting").font(.caption).foregroundStyle(.secondary).gridCellColumns(2)
                }
                if audio.apps.isEmpty {
                    GridRow {
                        Text("Spielt ein Programm Ton ab – Musik, ein Video, eine Präsentation –, erscheint es hier.")
                            .font(.caption).foregroundStyle(.secondary).gridCellColumns(4)
                    }
                }
                ForEach(audio.apps) { app in appRow(app) }
                Divider()
                GridRow {
                    Label("Ins Meeting", systemImage: "person.2").font(.body.weight(.semibold))
                    SourceMeter(levels: audio.levels, pick: { $0.meeting })
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(get: { audio.settings.muted }, set: { audio.settings.muted = $0 })) {
                            Label("Stimme stumm", systemImage: audio.settings.muted ? "mic.slash.fill" : "mic")
                        }
                        .toggleStyle(.button)
                        .tint(Theme.record)
                        .keyboardShortcut("m", modifiers: [])
                        .help("Deine Stimme nicht ins Meeting schicken (Taste M); Memes, iPad und Programme gehen weiter")
                        Text(meetingStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    .gridCellColumns(2)
                }
            }
            notes
        }
        .padding(16)
        .frame(width: 640)
        .tint(Theme.brand)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let ear = audio.ear {
                Image(systemName: ear.headphones ? "headphones" : "speaker.wave.2").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ear.name).lineLimit(1)
                    Text(ear.headphones ? "Kopfhörer: Deine Stimme bleibt aus dem Ohr, außer du schaltest sie ein." : "Lautsprecher: Was hier läuft, hört auch das Mikrofon.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Kopfhörer", isOn: Binding(get: { ear.headphones }, set: { audio.setHeadphones($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Falls Erklärbär falsch geraten hat: Sind das Kopfhörer?")
            } else {
                Text("Keine Tonausgabe gefunden").foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var microphoneName: String? {
        live.microphoneID.isEmpty ? "Kein Mikrofon gewählt" : live.app.microphones.first { $0.uniqueID == live.microphoneID }?.localizedName
    }

    private var meetingStatus: String {
        switch audio.meetingState {
        case .running: return "Mikrofon „\(VirtualCameraIDs.cameraName)“ läuft"
        case .missing: return "Mikrofon „\(VirtualCameraIDs.cameraName)“ meldet sich nicht"
        case .failed: return "Fehler, siehe unten"
        case .off:
            return mic.status == .ready ? "Mikrofon „\(VirtualCameraIDs.cameraName)“ ist aus" : "Mikrofon „\(VirtualCameraIDs.cameraName)“ ist nicht eingerichtet"
        }
    }

    @ViewBuilder
    private func channel(icon: String, title: String, detail: String?, meter: @escaping @MainActor (LiveLevels) -> Float,
                         value: Binding<LiveMixSettings.Channel>, earAllowed: Bool, earHelp: String) -> some View {
        GridRow {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .frame(minWidth: 120, alignment: .leading)
            SourceMeter(levels: audio.levels, pick: meter)
            fader(on: value.meetingOn, level: value.meeting, help: "\(title) ins Meeting")
            fader(on: value.earOn, level: value.ear, help: earHelp)
                .disabled(!earAllowed)
                .opacity(earAllowed ? 1 : 0.45)
        }
    }

    private func fader(on: Binding<Bool>, level: Binding<Double>, help: String) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: on).toggleStyle(.checkbox).labelsHidden()
            Slider(value: level, in: LiveMixSettings.range)
                .controlSize(.small)
                .frame(width: sliderWidth)
                .disabled(!on.wrappedValue)
            Text(Self.decibels(level.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(on.wrappedValue ? .primary : .secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .help(help)
    }

    static func decibels(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded) dB" : "\(rounded) dB"
    }

    @ViewBuilder
    private func appRow(_ app: AudioApps.App) -> some View {
        let isMeeting = app.id == audio.meetingApp
        GridRow {
            HStack(spacing: 6) {
                if let icon = AudioApps.icon(app.id) {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                } else {
                    Image(systemName: "app").foregroundStyle(.secondary).frame(width: 20)
                }
                Text(app.name).lineLimit(1)
                if app.playing {
                    Image(systemName: "speaker.wave.2.fill").font(.caption2).foregroundStyle(.green).help("Spielt gerade Ton ab")
                }
            }
            .frame(minWidth: 120, alignment: .leading)
            .contextMenu {
                Button(isMeeting ? "Ist das Meeting-Programm ✓" : "Ist das Meeting-Programm") { mic.meetingApp = app.id }
            }
            if isMeeting {
                Color.clear.frame(width: 70, height: 6)
                Text("Meeting-Programm: Die Stimmen der anderen gehen nie zurück ins Meeting")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                SourceMeter(levels: audio.levels, pick: { $0.apps[app.id] ?? 0 })
                fader(on: Binding(get: { audio.settings.app(app.id).meetingOn }, set: { on in audio.settings.apps[app.id, default: LiveMixSettings.newApp].meetingOn = on }),
                      level: Binding(get: { audio.settings.app(app.id).meeting }, set: { db in audio.settings.apps[app.id, default: LiveMixSettings.newApp].meeting = db }),
                      help: "Ton von \(app.name) ins Meeting schicken")
            }
            Text("direkt")
                .font(.caption).foregroundStyle(.secondary)
                .help("\(app.name) spielt selbst auf deinen Kopfhörern oder Lautsprechern, wie gewohnt.")
        }
    }

    @ViewBuilder
    private var notes: some View {
        let apps = VirtualMicrophone.runningApps()
        HStack(spacing: 6) {
            Text("Meeting läuft in").font(.caption).foregroundStyle(.secondary)
            Picker("Meeting läuft in", selection: $mic.meetingApp) {
                Text("–").tag("")
                if !mic.meetingApp.isEmpty, !apps.contains(where: { $0.id == mic.meetingApp }) {
                    Text(mic.meetingApp).tag(mic.meetingApp)
                }
                ForEach(apps, id: \.id) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 200)
            .help("Das Meeting-Programm: Sein Ton geht nie ins Meeting, sonst hören die anderen sich als Echo.")
        }
        VStack(alignment: .leading, spacing: 4) {
            if VirtualMicrophone.browsers.contains(mic.meetingApp) {
                Text("Das Meeting läuft im Browser: Alles aus diesem Browser bleibt draußen, auch Videos in anderen Tabs. Solche Videos in einem anderen Browser abspielen.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(LiveSoundNotes.notes(live: live, audio: audio, short: false), id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Control from an iPhone or iPad: switch, QR code, allowed devices and requests to allow.
struct LiveRemoteSection: View {
    @ObservedObject var remote: LiveRemote
    @AppStorage("liveRemoteCodeShown") private var codeShown = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "iphone.radiowaves.left.and.right").foregroundStyle(.secondary).frame(width: 18)
                Text("Mit iPhone oder iPad steuern")
                Spacer()
                Toggle("Fernsteuerung", isOn: $remote.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help("Zeigt eine Steuerung im WLAN, die du mit iPhone oder iPad öffnest")
            }
            ForEach(remote.requests) { request in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text("„\(request.name)“ möchte Erklärbär steuern.").font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Ablehnen") { remote.answer(request, allow: false) }.controlSize(.small)
                    Button("Erlauben") { remote.answer(request, allow: true) }.controlSize(.small).buttonStyle(.borderedProminent)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.14)))
            }
            if remote.enabled {
                if let url = remote.pairingURL {
                    DisclosureGroup(isExpanded: $codeShown) {
                        HStack(alignment: .top, spacing: 12) {
                            if let image = LiveRemote.qrImage(for: url, size: 132) {
                                Image(nsImage: image)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 132, height: 132)
                                    .padding(6)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Mit der Kamera von iPhone oder iPad scannen. Beide Geräte müssen im selben WLAN sein.")
                                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                                Text("Neue Geräte erlaubst du hier einmal. Tipp: In Safari „Zum Home-Bildschirm“ wählen, dann startet die Steuerung wie eine App.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Button("Neuer Code") { remote.newCode() }
                                    .controlSize(.small)
                                    .help("Der alte QR-Code verbindet dann keine neuen Geräte mehr; erlaubte Geräte bleiben erlaubt")
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Text("QR-Code").font(.caption.weight(.semibold))
                    }
                }
                ForEach(remote.devices) { device in
                    HStack(spacing: 6) {
                        Image(systemName: device.name == "iPad" ? "ipad" : "iphone").foregroundStyle(.secondary).frame(width: 18)
                        Text(device.name)
                        if remote.connected.contains(device.id) {
                            Circle().fill(Color.green).frame(width: 7, height: 7).help("Verbunden")
                        }
                        Spacer()
                        Button("Trennen") { remote.remove(device) }
                            .controlSize(.small)
                            .help("Dieses Gerät darf nicht mehr steuern (bis du es wieder erlaubst)")
                    }
                    .font(.callout)
                }
            }
            if let problem = remote.problem {
                Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.lane))
    }
}
