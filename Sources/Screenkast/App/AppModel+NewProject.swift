import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Projects without a recording: an own video, or an empty canvas.
extension AppModel {
    /// Asks for a video file and opens it as a new project.
    func newProjectFromVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.message = "Video wählen – es wird zur Hauptspur eines neuen Projekts"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        newProject(fromVideo: url)
    }

    func newProject(fromVideo url: URL) {
        Task {
            creatingProject = true
            defer { creatingProject = false }
            do {
                let project = try await ProjectFactory.importVideo(url)
                ProjectLocations.remember(project.url)
                reloadLibrary()
                open(project: project)
            } catch {
                errorMessage = "Das Video ließ sich nicht übernehmen: \(error.localizedDescription)"
            }
        }
    }

    func newEmptyProject(aspect: OutputAspect) {
        Task {
            creatingProject = true
            defer { creatingProject = false }
            do {
                let project = try await ProjectFactory.empty(length: 10, aspect: aspect)
                ProjectLocations.remember(project.url)
                reloadLibrary()
                open(project: project)
            } catch {
                errorMessage = "Das leere Projekt ließ sich nicht anlegen: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Where projects are saved

    /// Asks for a folder (also drives and shares). `prompt` is the button title.
    func chooseFolder(prompt: String, message: String, startingAt: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        panel.directoryURL = startingAt ?? ProjectLocations.current
        return panel.runModal() == .OK ? panel.url : nil
    }

    func setProjectFolder(_ folder: URL?) {
        ProjectLocations.use(folder)
        projectFolderChanged &+= 1
        reloadLibrary()
    }

    func chooseProjectFolder() {
        guard let folder = chooseFolder(prompt: "Hier speichern", message: "Neue Aufnahmen und Projekte werden in diesem Ordner gespeichert – auch auf Laufwerken und Freigaben.") else { return }
        setProjectFolder(folder)
    }

    /// Moves a project to another folder, drive or share (it keeps working from there).
    func moveProject(_ url: URL) {
        guard let folder = chooseFolder(prompt: "Hierher verschieben", message: "Wohin soll „\(url.deletingPathExtension().lastPathComponent)“ verschoben werden?",
                                        startingAt: url.deletingLastPathComponent()) else { return }
        moveProject(url, to: folder)
    }

    func moveProject(_ url: URL, to folder: URL, then done: ((URL) -> Void)? = nil) {
        guard folder.standardizedFileURL != url.deletingLastPathComponent().standardizedFileURL else { return }
        movingProjects.insert(url)
        Task {
            defer { movingProjects.remove(url) }
            do {
                let target = try await Task.detached(priority: .userInitiated) { try ProjectLocations.move(url, to: folder) }.value
                reloadLibrary()
                done?(target)
            } catch {
                errorMessage = "„\(url.deletingPathExtension().lastPathComponent)“ ließ sich nicht verschieben: \(error.localizedDescription) Das Projekt liegt unverändert am alten Ort."
                reloadLibrary()
            }
        }
    }
}

/// Where new recordings and projects are saved (start page).
struct ProjectFolderMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let _ = model.projectFolderChanged
        Menu {
            let current = ProjectLocations.chosen?.standardizedFileURL ?? Project.libraryURL.standardizedFileURL
            Button {
                model.setProjectFolder(nil)
            } label: {
                choice("Standard (Filme › Erklärbär)", selected: current == Project.libraryURL.standardizedFileURL)
            }
            let others = ProjectLocations.recents.filter { $0.standardizedFileURL != Project.libraryURL.standardizedFileURL }
            if !others.isEmpty { Divider() }
            ForEach(others, id: \.self) { folder in
                let reachable = ProjectLocations.isReachable(folder)
                Button {
                    model.setProjectFolder(folder)
                } label: {
                    choice(ProjectLocations.displayName(folder) + (reachable ? "" : " (nicht verbunden)"), selected: current == folder.standardizedFileURL)
                }
                .disabled(!reachable)
            }
            Divider()
            Button("Anderer Ort …") { model.chooseProjectFolder() }
        } label: {
            Label(title, systemImage: ProjectLocations.chosenIsMissing ? "exclamationmark.triangle"
                  : ProjectLocations.volumeName(ProjectLocations.current) != nil ? "externaldrive" : "folder")
        }
        .fixedSize()
        .help(help)
    }

    private var title: String {
        if ProjectLocations.chosenIsMissing, let chosen = ProjectLocations.chosen {
            return ProjectLocations.displayName(chosen) + " – nicht verbunden"
        }
        return ProjectLocations.displayName(ProjectLocations.current)
    }

    private var help: String {
        if ProjectLocations.chosenIsMissing {
            return "Das gewählte Laufwerk ist nicht verbunden – neue Projekte landen so lange im Standardordner."
        }
        if !ProjectLocations.isLocal(ProjectLocations.current) {
            return "Freigabe im Netzwerk: Aufnahmen werden erst auf dem Mac gespeichert und nach dem Stoppen hierher verschoben."
        }
        return "Hier werden neue Aufnahmen und Projekte gespeichert: \(ProjectLocations.current.path)"
    }

    @ViewBuilder
    private func choice(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
