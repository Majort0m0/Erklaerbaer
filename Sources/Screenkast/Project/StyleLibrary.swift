import Foundation

/// A saved look: background, frame, cursor, camera, captions, fades and logo.
struct StylePreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var settings: EditSettings
    /// Logo file in the library folder (copied into a project when applied).
    var logoFile: String?
    var builtIn = false
}

extension EditSettings {
    /// Takes over the look of `s`; content (cuts, texts, zooms …) stays.
    mutating func applyStyle(from s: EditSettings) {
        background = s.background; backgroundBlur = s.backgroundBlur; aspect = s.aspect
        padding = s.padding; cornerRadius = s.cornerRadius; shadow = s.shadow
        showCursor = s.showCursor; cursorScale = s.cursorScale; cursorSmoothing = s.cursorSmoothing
        clickEffect = s.clickEffect; hideIdleCursor = s.hideIdleCursor; clickSound = s.clickSound; clickVolume = s.clickVolume
        defaultZoom = s.defaultZoom; motionBlur = s.motionBlur
        cameraVisible = s.cameraVisible; cameraShape = s.cameraShape; cameraSize = s.cameraSize
        cameraCorner = s.cameraCorner; cameraX = s.cameraX; cameraY = s.cameraY
        cameraMirror = s.cameraMirror; cameraShadow = s.cameraShadow
        showCaptions = s.showCaptions; captionSize = s.captionSize; showShortcuts = s.showShortcuts
        fadeIn = s.fadeIn; fadeOut = s.fadeOut
        exportShortSide = s.exportShortSide; exportFPS = s.exportFPS; exportHEVC = s.exportHEVC
    }
}

/// Style presets in ~/Library/Application Support/Screenkast (plus a few built-in ones).
enum StyleLibrary {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Screenkast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var fileURL: URL { folder.appendingPathComponent("styles.json") }

    static var builtIn: [StylePreset] {
        // Fixed ids, so a built-in default survives a restart.
        func make(_ index: Int, _ name: String, _ change: (inout EditSettings) -> Void) -> StylePreset {
            var s = EditSettings()
            change(&s)
            return StylePreset(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!, name: name,
                               settings: s, builtIn: true)
        }
        return [
            make(1, "Standard") { _ in },
            make(2, "Dunkel & schlicht") { $0.background = .color(red: 0.08, green: 0.08, blue: 0.1); $0.shadow = 0.8; $0.padding = 0.06 },
            make(3, "Hell & freundlich") { $0.background = .gradient(5); $0.shadow = 0.4; $0.cornerRadius = 22; $0.padding = 0.08 },
            make(4, "Randlos") { $0.padding = 0; $0.cornerRadius = 0; $0.shadow = 0 },
            make(5, "Präsentation") { $0.background = .gradient(3); $0.cursorScale = 2.2; $0.defaultZoom = 2.2; $0.cameraSize = 0.3 },
        ]
    }

    static func load() -> [StylePreset] {
        guard let data = try? Data(contentsOf: fileURL), let list = try? JSONDecoder().decode([StylePreset].self, from: data) else { return [] }
        return list
    }

    static func save(_ presets: [StylePreset]) {
        try? JSONEncoder().encode(presets.filter { !$0.builtIn }).write(to: fileURL, options: .atomic)
    }

    static var all: [StylePreset] { builtIn + load() }

    /// Preset applied to new recordings (nil: the built-in defaults).
    static var defaultID: UUID? {
        get { UserDefaults.standard.string(forKey: "defaultStyleID").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "defaultStyleID") }
    }

    static var defaultPreset: StylePreset? { defaultID.flatMap { id in all.first { $0.id == id } } }

    /// Settings for a new project: the default style, its logo copied into the project.
    static func newProjectSettings(projectURL: URL) -> EditSettings {
        var s = EditSettings()
        if let preset = defaultPreset { apply(preset, to: &s, projectURL: projectURL) }
        return s
    }

    static func apply(_ preset: StylePreset, to s: inout EditSettings, projectURL: URL) {
        s.applyStyle(from: preset.settings)
        if let logo = preset.logoFile, var w = preset.settings.watermark {
            let name = "media/\(logo)"
            let target = projectURL.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.copyItem(at: folder.appendingPathComponent(logo), to: target)
            }
            w.file = name
            s.watermark = w
        } else if preset.builtIn {
            s.watermark = nil
        }
    }

    /// Saves the look of a project under a name (its logo is copied into the library).
    static func add(name: String, settings: EditSettings, projectURL: URL) -> StylePreset {
        var preset = StylePreset(name: name, settings: settings)
        if let w = settings.watermark {
            let logo = "logo-\(preset.id.uuidString.prefix(8)).\(URL(fileURLWithPath: w.file).pathExtension)"
            if (try? FileManager.default.copyItem(at: projectURL.appendingPathComponent(w.file), to: folder.appendingPathComponent(logo))) != nil {
                preset.logoFile = logo
            }
        }
        save(load() + [preset])
        return preset
    }

    static func remove(_ id: UUID) {
        save(load().filter { $0.id != id })
        if defaultID == id { defaultID = nil }
    }
}
