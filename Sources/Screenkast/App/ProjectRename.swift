import AppKit

enum ProjectRenameError: LocalizedError {
    case invalid, exists(String), busy
    var errorDescription: String? {
        switch self {
        case .invalid: return "Bitte einen Namen eingeben (er darf nicht mit einem Punkt beginnen)."
        case .exists(let name): return "Es gibt dort schon ein Projekt „\(name)“."
        case .busy: return "Das Projekt wird gerade exportiert – bitte danach umbenennen."
        }
    }
}

extension AppModel {
    /// Asks for a new name and renames the project folder. An open project is closed and opened
    /// again under its new name.
    func renameProject(_ url: URL) {
        if let editor, editor.project.url.standardizedFileURL == url.standardizedFileURL, editor.isExporting {
            errorMessage = ProjectRenameError.busy.localizedDescription
            return
        }
        guard let name = Self.askProjectName(current: url.deletingPathExtension().lastPathComponent) else { return }
        let isOpen = editor?.project.url.standardizedFileURL == url.standardizedFileURL
        if isOpen { closeEditor() }
        do {
            let renamed = try Self.rename(project: url, to: name)
            if ProjectLocations.known.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                ProjectLocations.forget(url)
                ProjectLocations.remember(renamed)
            }
            reloadLibrary()
            if isOpen { open(url: renamed) }
        } catch {
            errorMessage = "Umbenennen ging nicht: \(error.localizedDescription)"
            if isOpen { open(url: url) }
        }
    }

    private static func askProjectName(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Projekt umbenennen"
        alert.informativeText = "Der Name des Projekts ist auch der Name seines Ordners."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: "Umbenennen")
        alert.addButton(withTitle: "Abbrechen")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Renames the project folder; "/" and ":" become "-". Only a change of upper and lower case
    /// goes over a temporary name (the disk does not tell them apart).
    nonisolated static func rename(project url: URL, to name: String) throws -> URL {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !clean.isEmpty, !clean.hasPrefix(".") else { throw ProjectRenameError.invalid }
        let target = url.deletingLastPathComponent().appendingPathComponent(clean + "." + Project.fileExtension)
        guard target.lastPathComponent != url.lastPathComponent else { return url }
        let fm = FileManager.default
        if target.lastPathComponent.lowercased() == url.lastPathComponent.lowercased() {
            let temp = url.deletingLastPathComponent().appendingPathComponent(".umbenennen-\(UUID().uuidString)")
            try fm.moveItem(at: url, to: temp)
            try fm.moveItem(at: temp, to: target)
            return target
        }
        guard !fm.fileExists(atPath: target.path) else { throw ProjectRenameError.exists(clean) }
        try fm.moveItem(at: url, to: target)
        return target
    }
}
