import Foundation
import Security
import FoundationModels

// MARK: - Settings

/// Where the AI suggestions come from.
enum AIProvider: String, CaseIterable, Identifiable {
    /// Apple's on-device model (Apple Intelligence): free, nothing leaves the Mac.
    case apple
    /// Claude via the Anthropic API (own API key).
    case claude
    /// Copy a prompt into any AI app, paste its answer back.
    case clipboard
    var id: String { rawValue }

    var label: String {
        switch self {
        case .apple: return "Apple Intelligence (auf dem Mac)"
        case .claude: return "Claude (eigener API-Schlüssel)"
        case .clipboard: return "Beliebige KI-App (Prompt kopieren)"
        }
    }
}

enum AISettings {
    static var provider: AIProvider {
        get { AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? .apple }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "aiProvider") }
    }

    static let claudeModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]

    static var claudeModel: String {
        get { UserDefaults.standard.string(forKey: "claudeModel").flatMap { claudeModels.contains($0) ? $0 : nil } ?? "claude-opus-5-5" }
        set { UserDefaults.standard.set(newValue, forKey: "claudeModel") }
    }

    // The API key lives in the keychain, never in the project or the defaults.
    private static let service = "Erklaerbaer.ClaudeAPI"

    static var claudeKey: String? {
        get {
            var item: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Why Apple's model can't be used right now (nil: ready).
    static var appleProblem: String? {
        guard #available(macOS 26.0, *) else { return "Apple Intelligence braucht macOS 26 oder neuer." }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "Dieser Mac unterstützt Apple Intelligence nicht."
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence ist ausgeschaltet (Systemeinstellungen › Apple Intelligence & Siri)."
        case .unavailable(.modelNotReady): return "Das Sprachmodell wird noch geladen – bitte später erneut versuchen."
        default: return "Apple Intelligence ist nicht verfügbar."
        }
    }
}

// MARK: - Suggestions

/// What the AI suggests for a video. Times are seconds in the finished video.
struct AISuggestions: Codable, Equatable {
    struct Chapter: Codable, Equatable { var time: Double; var title: String }
    struct Clip: Codable, Equatable, Identifiable {
        var start: Double
        var end: Double
        var title: String
        var reason: String?
        var id: String { "\(start)-\(end)" }
    }
    var chapters: [Chapter] = []
    var titles: [String] = []
    var description: String = ""
    var tags: [String] = []
    var clips: [Clip] = []
}

enum AIError: LocalizedError {
    case noTranscript, noKey, http(Int, String), refused, unreadable(String), apple(String)
    var errorDescription: String? {
        switch self {
        case .noTranscript: return "Es gibt noch kein Transkript – bitte zuerst Untertitel erzeugen."
        case .noKey: return "Bitte zuerst einen Claude-API-Schlüssel eintragen (Einstellungen › KI)."
        case .http(let code, let message): return "Claude antwortete mit Fehler \(code): \(message)"
        case .refused: return "Die KI hat die Anfrage abgelehnt."
        case .unreadable(let text): return "Die Antwort ließ sich nicht lesen. Anfang: \(text.prefix(160))"
        case .apple(let message): return message
        }
    }
}

enum AIAssistant {
    /// The task, written so that any model answers with JSON only.
    static func prompt(transcript: String, duration: Double, language: String) -> String {
        """
        Du hilfst beim Veröffentlichen eines Erklärvideos (Bildschirmaufnahme). Unten steht das Transkript mit Zeitmarken in Sekunden \
        im fertigen Video (Gesamtlänge \(Int(duration)) s, Sprache \(language)).

        Antworte AUSSCHLIESSLICH mit einem JSON-Objekt, ohne Erklärungen davor oder danach, in diesem Format:
        {"chapters":[{"time":0,"title":"…"}],"titles":["…","…","…"],"description":"…","tags":["…"],\
        "clips":[{"start":0,"end":30,"title":"…","reason":"…"}]}

        Regeln:
        - chapters: 3–8 Kapitel in der Sprache des Videos, das erste bei time 0, jedes mindestens 10 s lang, kurze Titel (max. 6 Wörter).
        - titles: 3 Titelvorschläge für YouTube (max. 70 Zeichen), klar und neugierig machend, ohne Clickbait.
        - description: 2–4 Sätze Beschreibung, was man im Video lernt.
        - tags: 5–10 Schlagwörter.
        - clips: 1–3 Abschnitte (15–60 s) mit einer abgeschlossenen, interessanten Aussage, geeignet als Kurzvideo (Reels, Shorts); \
        start und end auf Satzgrenzen; reason: ein Satz, warum.

        Transkript:
        \(transcript)
        """
    }

    /// Reads the JSON object from a model's answer (tolerates code fences and text around it).
    static func parse(_ text: String) throws -> AISuggestions {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last,
              let data = String(text[first...last]).data(using: .utf8) else { throw AIError.unreadable(text) }
        do {
            return try JSONDecoder().decode(AISuggestions.self, from: data)
        } catch {
            // Be lenient: missing parts become empty.
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.unreadable(text) }
            var s = AISuggestions()
            func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
            s.chapters = (object["chapters"] as? [[String: Any]] ?? []).compactMap { c in
                guard let t = number(c["time"]), let title = c["title"] as? String else { return nil }
                return .init(time: t, title: title)
            }
            s.titles = object["titles"] as? [String] ?? []
            s.description = object["description"] as? String ?? ""
            s.tags = object["tags"] as? [String] ?? []
            s.clips = (object["clips"] as? [[String: Any]] ?? []).compactMap { c in
                guard let a = number(c["start"]), let b = number(c["end"]), b > a else { return nil }
                return .init(start: a, end: b, title: c["title"] as? String ?? "Clip", reason: c["reason"] as? String)
            }
            return s
        }
    }

    /// Asks the chosen provider (not the clipboard: that one goes through the UI).
    static func run(prompt: String, provider: AIProvider) async throws -> String {
        switch provider {
        case .apple: return try await apple(prompt)
        case .claude: return try await claude(prompt)
        case .clipboard: throw AIError.unreadable("")
        }
    }

    /// Apple's on-device model (its context is small: about 4,000 tokens).
    static func apple(_ prompt: String) async throws -> String {
        if let problem = AISettings.appleProblem { throw AIError.apple(problem) }
        guard #available(macOS 26.0, *) else { throw AIError.apple("Apple Intelligence braucht macOS 26 oder neuer.") }
        let session = LanguageModelSession(instructions: "Du bist ein hilfreicher Assistent für Videoschnitt. Antworte nur mit gültigem JSON, wenn danach gefragt wird.")
        let response = try await session.respond(to: prompt)
        return response.content
    }

    /// Claude via the Messages API (raw HTTP: Swift has no official Anthropic SDK).
    static func claude(_ prompt: String) async throws -> String {
        guard let key = AISettings.claudeKey, !key.isEmpty else { throw AIError.noKey }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // A declined request is re-run on Anthropic's recommended fallback model.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let model = AISettings.claudeModel
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "output_config": ["effort": "medium"],
            "messages": [["role": "user", "content": prompt]],
        ]
        // Haiku has no server-side fallback.
        if model.contains("haiku") {
            request.setValue(nil, forHTTPHeaderField: "anthropic-beta")
        } else {
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            throw AIError.http(status, message)
        }
        if json["stop_reason"] as? String == "refusal" { throw AIError.refused }
        let text = (json["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined()
        return text
    }
}
