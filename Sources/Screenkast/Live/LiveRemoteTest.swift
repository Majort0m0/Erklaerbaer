import AppKit
import Foundation
import WebKit

/// `--remotetest`: starts the remote control without windows and goes through pairing, the event stream
/// and commands over HTTP, as the iPhone would. `--remoteserve <seconds>`: only serves the page (new
/// devices are allowed automatically) to look at it in a browser.
/// Run the bare binary (not the app): it keeps its own settings then.
enum LiveRemoteTest {
    @MainActor
    static func commandLine(serveFor seconds: Double? = nil) -> Int32 {
        var code: Int32 = 1
        var done = false
        Task { @MainActor in
            defer { done = true }
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            AppModel.snapshotMode = true
            let app = AppModel()
            let live = LiveModel(app: app)
            defer { withExtendedLifetime(app) {} }
            let remote = live.remote
            remote.startForTesting(live)
            var waited = 0
            while remote.pairingURL == nil && waited < 50 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            guard let url = remote.pairingURL, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let secret = components.fragment?.replacingOccurrences(of: "k=", with: "") else {
                print("✗ Kein Server:", remote.problem ?? "?")
                return
            }
            print("Adresse für den QR-Code:", url.absoluteString.replacingOccurrences(of: secret, with: "…"))
            let base = URL(string: "http://127.0.0.1:\(components.port ?? 0)")!
            if let seconds {
                remote.autoAllow = true
                print("Bedient die Seite \(Int(seconds)) s lang: \(base.absoluteString)/#k=\(secret)")
                try? await Task.sleep(for: .seconds(seconds))
                code = 0
                return
            }
            var checks: [(String, Bool)] = []
            func check(_ name: String, _ ok: Bool) {
                checks.append((name, ok))
                print(ok ? "✓" : "✗", name)
            }
            // Leftovers of an earlier, broken-off run.
            for old in remote.devices where old.id == "test-device" || old.id == "other" { remote.remove(old) }
            do {
                let (page, pageResponse) = try await get(base.appendingPathComponent("/"))
                check("Seite wird ausgeliefert", (pageResponse as? HTTPURLResponse)?.statusCode == 200 && String(decoding: page, as: UTF8.self).contains("Erklärbär Live"))
                let wrong = try await post(base.appendingPathComponent("/api/pair"), ["secret": "falsch", "device": "test-device", "name": "iPhone"])
                check("Falscher Code verbindet nicht", wrong["status"] as? String == "expired")
                let asked = try await post(base.appendingPathComponent("/api/pair"), ["secret": secret, "device": "test-device", "name": "iPhone"])
                check("Neues Gerät muss am Mac erlaubt werden", asked["status"] as? String == "waiting" && remote.requests.count == 1)
                let (unauthorized, unauthorizedResponse) = try await get(base.appendingPathComponent("/api/hello"))
                check("Ohne Schlüssel kein Zugriff", (unauthorizedResponse as? HTTPURLResponse)?.statusCode == 401 && !unauthorized.isEmpty)
                guard let request = remote.requests.first else { throw RecorderError.writerFailed("keine Anfrage") }
                remote.answer(request, allow: true)
                let answer = try await getJSON(base.appendingPathComponent("/api/pair/\(asked["request"] as? String ?? "")"))
                let token = answer["token"] as? String ?? ""
                check("Nach dem Erlauben gibt es einen Schlüssel", answer["status"] as? String == "approved" && !token.isEmpty)
                let hello = try await getJSON(base.appendingPathComponent("/api/hello"), token: token)
                check("Mit Schlüssel Zugriff", hello["ok"] as? Bool == true)
                // Event stream: the first state arrives by itself.
                var connectedWhileOpen = false
                let state = try await firstEvent(base: base, token: token, name: "state") { connectedWhileOpen = remote.connected.contains("test-device") }
                check("Zustand kommt über den Ereignis-Strom", state?["live"] as? Bool == true && state?["memes"] is [Any] && state?["sources"] is [Any])
                check("Gerät gilt als verbunden", connectedWhileOpen)
                live.config.scene = .source
                _ = try await post(base.appendingPathComponent("/api/command"), ["action": "scene", "value": "webcam"], token: token)
                check("Szene lässt sich umschalten", live.config.scene == .webcam)
                let before = live.audio.settings.voice
                _ = try await post(base.appendingPathComponent("/api/command"), ["action": "mix", "source": "voice", "path": "meeting", "db": -12], token: token)
                check("Lautstärke lässt sich einstellen", live.audio.settings.voice.meeting == -12)
                live.audio.settings.voice = before
                let wasMuted = live.audio.settings.muted
                _ = try await post(base.appendingPathComponent("/api/command"), ["action": "mute", "value": !wasMuted], token: token)
                check("Stumm lässt sich schalten", live.audio.settings.muted == !wasMuted)
                live.audio.settings.muted = wasMuted
                // Nothing changes: no new state, but the status (pictures per second) keeps coming.
                try await Task.sleep(for: .seconds(1))   // the changes of the steps before are through
                let quiet = try await countEvents(base: base, token: token, seconds: 2.6)
                check("Ohne Änderung kein neuer Zustand, nur Status (\(quiet))", quiet["state"] == 1 && (quiet["status"] ?? 0) >= 2)
                // Settings of the control window.
                let savedConfig = live.config
                let fullState = try await firstEvent(base: base, token: token, name: "state") {}
                check("Zustand enthält Quellen, Webcams, Rahmen und Mikrofone",
                      fullState?["videoSources"] is [String: Any] && fullState?["cameras"] is [Any] && fullState?["mockups"] is [Any] && fullState?["microphones"] is [Any])
                func set(_ key: String, _ value: Any) async throws -> Bool {
                    let answer = try await post(base.appendingPathComponent("/api/command"), ["action": "set", "key": key, "value": value], token: token)
                    return answer["ok"] as? Bool == true
                }
                _ = try await set("mockup", "tv")
                check("Rahmen lässt sich wählen", live.config.mockup == .tv)
                _ = try await set("mockup", "")
                check("Rahmen lässt sich abwählen", live.config.mockup == nil)
                _ = try await set("bubbleSize", 0.5)
                _ = try await set("bubble", ["x": 0.2, "y": 0.3])
                check("Webcam: Größe und Position", live.config.bubbleSize == 0.5 && live.config.bubbleX == 0.2 && live.config.bubbleY == 0.3)
                _ = try await set("bubbleSize", 5)
                check("Webcam-Größe bleibt im erlaubten Bereich", live.config.bubbleSize == 0.9)
                _ = try await set("memeSpot", "topLeft")
                _ = try await set("clicks", false)
                _ = try await set("trail", true)
                _ = try await set("backgroundEdge", 0.7)
                check("Meme-Position, Effekte und Kante", live.config.memeSpot == .topLeft && !live.config.clicks && live.config.trail && live.config.backgroundEdge == 0.7)
                let unknown = try await set("gibtsnicht", true)
                let badSource = try await set("source", "unsinn")
                check("Unbekannte Einstellungen werden abgelehnt", !unknown && !badSource)
                if let logo = live.overlays.logos.first {
                    _ = try await post(base.appendingPathComponent("/api/command"), ["action": "logoSettings", "id": logo.id.uuidString, "corner": "bottomLeft", "size": 0.3, "opacity": 0.5], token: token)
                    let changed = live.overlays.logo(logo.id)
                    check("Logo: Ecke, Größe und Deckkraft", changed?.corner == .bottomLeft && changed?.size == 0.3 && changed?.opacity == 0.5)
                    live.overlays.update(logo)
                }
                // A picture from the phone as the background.
                let hadBackground = live.backgroundFile
                let picture = NSImage(size: NSSize(width: 64, height: 36), flipped: false) { rect in
                    NSColor.systemTeal.setFill()
                    rect.fill()
                    return true
                }
                var upload = URLRequest(url: base.appendingPathComponent("/api/background"))
                upload.httpMethod = "POST"
                upload.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                upload.setValue("image/png", forHTTPHeaderField: "Content-Type")
                upload.httpBody = NSBitmapImageRep(data: picture.tiffRepresentation!)!.representation(using: .png, properties: [:])
                let (_, uploadResponse) = try await URLSession.shared.data(for: upload)
                let uploaded = live.backgroundFile
                check("Hintergrundbild vom Telefon", (uploadResponse as? HTTPURLResponse)?.statusCode == 200 && uploaded != nil && uploaded != hadBackground
                      && live.config.background == true)
                var junk = URLRequest(url: base.appendingPathComponent("/api/background"))
                junk.httpMethod = "POST"
                junk.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                junk.httpBody = Data("kein Bild".utf8)
                let (_, junkResponse) = try await URLSession.shared.data(for: junk)
                check("Kein Bild wird abgelehnt", (junkResponse as? HTTPURLResponse)?.statusCode == 400 && live.backgroundFile == uploaded)
                if let uploaded, hadBackground == nil {
                    try? FileManager.default.removeItem(at: uploaded)
                    UserDefaults.standard.removeObject(forKey: "liveBackground")
                }
                live.config = savedConfig
                let meetingProgram = live.audio.meetingApp
                if !meetingProgram.isEmpty {
                    _ = try await post(base.appendingPathComponent("/api/command"), ["action": "mix", "source": "app:\(meetingProgram)", "path": "meeting", "on": true], token: token)
                    check("Meeting-Programm lässt sich nicht einschalten", live.audio.settings.apps[meetingProgram]?.meetingOn != true)
                }
                let again = try await post(base.appendingPathComponent("/api/pair"), ["secret": secret, "device": "test-device", "name": "iPhone"])
                check("Bekanntes Gerät bekommt ohne Rückfrage einen neuen Schlüssel", again["status"] as? String == "approved")
                if let device = remote.devices.first(where: { $0.id == "test-device" }) { remote.remove(device) }
                let (_, removedResponse) = try await get(base.appendingPathComponent("/api/hello"), token: again["token"] as? String)
                check("Getrenntes Gerät hat keinen Zugriff mehr", (removedResponse as? HTTPURLResponse)?.statusCode == 401)
                remote.newCode()
                let stale = try await post(base.appendingPathComponent("/api/pair"), ["secret": secret, "device": "other", "name": "iPad"])
                check("Alter QR-Code gilt nach „Neuer Code“ nicht mehr", stale["status"] as? String == "expired")
            } catch {
                check("Fehler: \(error.localizedDescription)", false)
            }
            remote.detach()
            code = checks.allSatisfy(\.1) ? 0 : 1
            print(code == 0 ? "✓ Fernsteuerung: \(checks.count) Prüfungen bestanden" : "✗ Fernsteuerung: nicht alles bestanden")
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return code
    }

    private static func get(_ url: URL, token: String? = nil) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await URLSession.shared.data(for: request)
    }

    private static func getJSON(_ url: URL, token: String? = nil) async throws -> [String: Any] {
        let (data, _) = try await get(url, token: token)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func post(_ url: URL, _ body: [String: Any], token: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Counts the events of a stream that is open for some seconds (the first state included).
    private static func countEvents(base: URL, token: String, seconds: Double) async throws -> [String: Int] {
        var components = URLComponents(url: base.appendingPathComponent("/api/events"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "t", value: token)]
        let url = components.url!
        final class Counts: @unchecked Sendable {
            let lock = NSLock()
            var values: [String: Int] = [:]
        }
        let counts = Counts()
        let reader = Task {
            let (bytes, _) = try await URLSession.shared.bytes(from: url)
            for try await line in bytes.lines where line.hasPrefix("event: ") {
                counts.lock.withLock { counts.values[String(line.dropFirst(7)), default: 0] += 1 }
            }
        }
        try await Task.sleep(for: .seconds(seconds))
        reader.cancel()
        return counts.lock.withLock { counts.values }
    }

    /// Reads the event stream until the first event with this name.
    @MainActor
    private static func firstEvent(base: URL, token: String, name: String, whileOpen: () -> Void) async throws -> [String: Any]? {
        var components = URLComponents(url: base.appendingPathComponent("/api/events"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "t", value: token)]
        let (bytes, _) = try await URLSession.shared.bytes(from: components.url!)
        var event = ""
        let deadline = Date().addingTimeInterval(5)
        for try await line in bytes.lines {
            if Date() > deadline { return nil }
            if line.hasPrefix("event: ") { event = String(line.dropFirst(7)) }
            if line.hasPrefix("data: "), event == name {
                whileOpen()
                return try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any]
            }
        }
        return nil
    }
}

/// `--remotesnapshot <folder>`: the remote page in phone and tablet width (pictures in the folder), with
/// JavaScript errors printed.
enum LiveRemoteSnapshot {
    @MainActor
    static func commandLine(folder: URL) -> Int32 {
        var code: Int32 = 1
        var done = false
        Task { @MainActor in
            defer { done = true }
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            AppModel.snapshotMode = true
            let app = AppModel()
            let live = LiveModel(app: app)
            defer { withExtendedLifetime(app) {} }
            live.remote.startForTesting(live)
            live.remote.autoAllow = true
            for _ in 0..<50 where live.remote.pairingURL == nil { try? await Task.sleep(for: .milliseconds(100)) }
            guard let url = live.remote.pairingURL, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                print("✗ Kein Server")
                return
            }
            components.host = "127.0.0.1"
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var ok = true
            for (name, size, tab) in [("telefon", CGSize(width: 390, height: 1500), "stage"), ("telefon-bild", CGSize(width: 390, height: 1700), "picture"),
                                      ("telefon-ton", CGSize(width: 390, height: 1500), "sound"), ("tablet", CGSize(width: 1180, height: 820), "picture")] {
                let view = WKWebView(frame: CGRect(origin: .zero, size: size))
                let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -5000, y: -5000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = view
                window.orderFrontRegardless()
                view.load(URLRequest(url: components.url!))
                try? await Task.sleep(for: .seconds(3))
                let errors = try? await view.evaluateJavaScript("""
                    (function(){ var shown = !document.getElementById('app').classList.contains('hidden');
                      document.querySelector('[data-tab=\(tab)]').click();
                      var gear = document.querySelector('[data-logo-edit]'); if (gear && '\(tab)' === 'stage') gear.click();
                      return shown ? 'ok' : document.getElementById('pairText').textContent; })()
                    """)
                print(name, "→", errors.map { "\($0)" } ?? "Fehler beim Auswerten")
                if "\(errors ?? "")" != "ok" { ok = false }
                try? await Task.sleep(for: .seconds(0.8))
                let configuration = WKSnapshotConfiguration()
                configuration.rect = CGRect(origin: .zero, size: size)
                if let image = try? await view.takeSnapshot(configuration: configuration),
                   let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: folder.appendingPathComponent("\(name).png"))
                }
                window.orderOut(nil)
            }
            // Choosing in a list while the Mac sends new states: the choice must neither jump back nor get lost.
            do {
                let saved = live.config
                live.config.scene = .source
                live.config.mockup = nil
                let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 900))
                let window = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: 390, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = view
                window.orderFrontRegardless()
                view.load(URLRequest(url: components.url!))
                try? await Task.sleep(for: .seconds(3))
                _ = try? await view.evaluateJavaScript("""
                    document.querySelector('[data-tab=picture]').click();
                    var m = document.getElementById('mockup');
                    m.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true}));
                    m.focus(); m.value = 'tv'; m.dispatchEvent(new Event('change', {bubbles: true})); 'ok'
                    """)
                // Meanwhile other things change on the Mac (new states go out).
                for step in 0..<4 {
                    live.config.trail = step % 2 == 0
                    try? await Task.sleep(for: .milliseconds(120))
                }
                let during = try? await view.evaluateJavaScript("document.getElementById('mockup').value") as? String
                try? await Task.sleep(for: .seconds(1))
                _ = try? await view.evaluateJavaScript("document.getElementById('mockup').blur(); 'ok'")
                try? await Task.sleep(for: .seconds(2.8))
                let after = try? await view.evaluateJavaScript("document.getElementById('mockup').value") as? String
                let applied = live.config.mockup == .tv
                // And back from the Mac: the list follows once it is no longer in use.
                live.config.mockup = .laptop
                try? await Task.sleep(for: .seconds(1))
                let follows = try? await view.evaluateJavaScript("document.getElementById('mockup').value") as? String
                let fine = during == "tv" && applied && after == "tv" && follows == "laptop"
                print(fine ? "✓" : "✗", "Rahmen wählen, während der Mac Neues schickt: in der Liste \(during ?? "?"), am Mac \(applied ? "übernommen" : "NICHT übernommen"), danach \(after ?? "?"), Änderung am Mac kommt an: \(follows ?? "?")")
                if !fine { ok = false }
                window.orderOut(nil)
                live.config = saved
            }
            if let device = live.remote.devices.first(where: { $0.name == "Browser" }) { live.remote.remove(device) }
            live.remote.detach()
            code = ok ? 0 : 1
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return code
    }
}
