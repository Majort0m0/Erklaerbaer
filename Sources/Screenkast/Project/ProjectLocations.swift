import Foundation

/// Where projects live. New recordings and projects go to the folder chosen on the start page; the
/// start page shows that folder, the standard folder, earlier folders and single projects
/// elsewhere. A project on a drive that isn't connected stays in the list.
enum ProjectLocations {
    private static let currentKey = "projectFolder"
    private static let recentKey = "projectFoldersRecent"
    private static let knownKey = "knownProjects"
    private static var defaults: UserDefaults { .standard }

    /// The chosen folder as far as it is known (it may be on a drive that isn't connected).
    static var chosen: URL? { defaults.string(forKey: currentKey).map { URL(fileURLWithPath: $0, isDirectory: true) } }

    /// The folder for new projects: the chosen one if it can be reached, else the standard folder.
    static var current: URL {
        guard let folder = chosen, isReachable(folder) else { return Project.libraryURL }
        return folder
    }

    /// True if the chosen folder is gone (drive or share not connected).
    static var chosenIsMissing: Bool { chosen.map { !isReachable($0) } ?? false }

    /// Recordings are written to this folder: a network share could drop frames or lose the
    /// recording, so they are written locally first and moved there afterwards.
    static var recordingFolder: URL { isLocal(current) ? current : Project.libraryURL }

    static func use(_ folder: URL?) {
        guard let folder, folder.standardizedFileURL != Project.libraryURL.standardizedFileURL else {
            defaults.removeObject(forKey: currentKey)
            return
        }
        defaults.set(folder.path, forKey: currentKey)
        addRecent(folder)
    }

    /// Earlier folders, newest first.
    static var recents: [URL] {
        (defaults.stringArray(forKey: recentKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func addRecent(_ folder: URL) {
        var list = defaults.stringArray(forKey: recentKey) ?? []
        list.removeAll { $0 == folder.path }
        list.insert(folder.path, at: 0)
        defaults.set(Array(list.prefix(8)), forKey: recentKey)
    }

    static func forgetRecent(_ folder: URL) {
        defaults.set((defaults.stringArray(forKey: recentKey) ?? []).filter { $0 != folder.path }, forKey: recentKey)
    }

    static func isReachable(_ folder: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// False for network shares.
    static func isLocal(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true
    }

    /// The name shown for a folder ("Filme › Erklärbär", the name of a drive …).
    static func displayName(_ folder: URL) -> String {
        if folder.standardizedFileURL == Project.libraryURL.standardizedFileURL { return "Standard (Filme › Erklärbär)" }
        if let volume = volumeName(folder), folder.pathComponents.count > 2, folder.path.hasPrefix("/Volumes/") {
            let inner = folder.pathComponents.dropFirst(3)
            return inner.isEmpty ? volume : volume + " › " + inner.joined(separator: " › ")
        }
        return folder.lastPathComponent
    }

    /// Name of the external drive or share a path lies on (nil: the startup disk).
    static func volumeName(_ url: URL) -> String? {
        let parts = url.pathComponents
        return parts.count > 2 && parts[1] == "Volumes" ? parts[2] : nil
    }

    // MARK: Projects elsewhere

    static var known: [URL] {
        (defaults.stringArray(forKey: knownKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Remembers a project outside the standard folder, so it stays in the list.
    static func remember(_ project: URL) {
        guard project.deletingLastPathComponent().standardizedFileURL != Project.libraryURL.standardizedFileURL else { return }
        var list = defaults.stringArray(forKey: knownKey) ?? []
        if !list.contains(project.path) { list.append(project.path) }
        defaults.set(list, forKey: knownKey)
    }

    static func forget(_ project: URL) {
        defaults.set((defaults.stringArray(forKey: knownKey) ?? []).filter { $0 != project.path }, forKey: knownKey)
    }

    /// True if the project's drive or share isn't connected right now (the project is not deleted).
    static func isOffline(_ project: URL) -> Bool {
        guard !FileManager.default.fileExists(atPath: project.path), let volume = volumeName(project) else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/" + volume)
    }

    /// All projects to show, newest first.
    static func allProjects() -> [URL] {
        let fm = FileManager.default
        var folders = [Project.libraryURL]
        if let chosen, isReachable(chosen) { folders.append(chosen) }
        folders += recents.filter(isReachable)
        var seen = Set<String>()
        var found: [URL] = []
        func add(_ url: URL) { if seen.insert(url.standardizedFileURL.path).inserted { found.append(url) } }
        for folder in folders {
            for url in Project.listProjects(in: folder) { add(url) }
        }
        for url in known {
            if fm.fileExists(atPath: url.appendingPathComponent("recording.json").path) || isOffline(url) {
                add(url)
            } else {
                forget(url)   // deleted or moved in the Finder
            }
        }
        func date(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return found.sorted { date($0) > date($1) }
    }

    // MARK: Moving

    /// Free path for a project folder called `name` in `folder` (numbered if it exists).
    static func destination(for project: URL, in folder: URL) -> URL {
        let fm = FileManager.default
        let base = project.deletingPathExtension().lastPathComponent
        var url = folder.appendingPathComponent(project.lastPathComponent, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).\(Project.fileExtension)", isDirectory: true)
            n += 1
        }
        return url
    }

    /// Moves a project to `folder`. On another drive it is copied first and the original is
    /// removed only after the copy is complete, so an interrupted move loses nothing.
    static func move(_ project: URL, to folder: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = destination(for: project, in: folder)
        let sameVolume: Bool = {
            let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
            guard let a = try? project.resourceValues(forKeys: keys).volumeIdentifier as? NSObject,
                  let b = try? folder.resourceValues(forKeys: keys).volumeIdentifier as? NSObject else { return false }
            return a.isEqual(b)
        }()
        if sameVolume {
            try fm.moveItem(at: project, to: target)
        } else {
            let partial = target.deletingPathExtension().appendingPathExtension("kopiert")
            try? fm.removeItem(at: partial)
            do {
                try fm.copyItem(at: project, to: partial)
                try fm.moveItem(at: partial, to: target)
            } catch {
                try? fm.removeItem(at: partial)
                throw error
            }
            try fm.removeItem(at: project)
        }
        forget(project)
        remember(target)
        return target
    }
}
