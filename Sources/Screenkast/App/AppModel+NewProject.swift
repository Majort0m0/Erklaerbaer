import AppKit
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
                reloadLibrary()
                open(project: project)
            } catch {
                errorMessage = "Das leere Projekt ließ sich nicht anlegen: \(error.localizedDescription)"
            }
        }
    }
}
