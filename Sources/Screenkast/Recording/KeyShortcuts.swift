import AppKit
import ApplicationServices

/// A keyboard shortcut pressed during the recording (only combinations with ⌘, ⌃ or ⌥ —
/// plain typing is never recorded).
struct KeyEvent: Codable, Equatable {
    var t: Double
    var label: String
}

enum KeyShortcuts {
    /// Accessibility permission is required to observe keys in other apps.
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// "⌃⌥⇧⌘K"-style label, or nil if the event is not a shortcut (no ⌘/⌃/⌥).
    static func label(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags) -> String? {
        let mods = flags.intersection(.deviceIndependentFlagsMask)
        guard !mods.intersection([.command, .control, .option]).isEmpty else { return nil }
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        let special: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = special[keyCode] {
            s += name
        } else if let c = characters?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            s += c.uppercased()
        } else {
            return nil
        }
        return s
    }
}
