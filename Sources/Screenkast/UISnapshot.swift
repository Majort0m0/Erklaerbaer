import ScreenCaptureKit
import AppKit
import SwiftUI

/// `Screenkast --uisnapshot <project> <png>`: renders the editor (without its window chrome)
/// off-screen into an image, to check the layout without clicking through the app.
enum UISnapshot {
    @MainActor
    static func run(projectPath: String, outputPath: String) -> Int32 {
        _ = NSApplication.shared
        // Parts of the inspector as on a new Mac (SCREENKAST_FOLDS=all: all open), not saved.
        InspectorFolds.shared.keepInMemory(open: ProcessInfo.processInfo.environment["SCREENKAST_FOLDS"] == "all"
            ? Set(InspectorFold.allCases) : Set(InspectorFold.allCases.filter(\.defaultOpen)))
        if projectPath == "home" { return home(outputPath: outputPath) }
        // "Neues Projekt aus dem Internet"; urlproject-login shows the advice after a login error.
        if projectPath == "urlproject" || projectPath == "urlproject-login" {
            AppModel.snapshotMode = true
            let app = AppModel()
            let m = URLImportModel()
            if projectPath == "urlproject-login" {
                m.address = "https://www.instagram.com/reel/DeUxSy_NSim/"
                m.phase = .failed(DownloadError.tool("Requested content is not available, rate-limit reached or login required").localizedDescription)
                m.advice = .login
            }
            let sheet = URLImportSheet(target: .newProject(app), isPresented: .constant(true), model: m)
                .background(Theme.panel).tint(Theme.brand)
            return (try? write(sheet, width: 500, height: projectPath == "urlproject" ? 380 : 560, to: outputPath, settle: Date().addingTimeInterval(2))) ?? 1
        }
        if projectPath == "live" {
            AppModel.snapshotMode = true
            let app = AppModel()
            let live = LiveModel(app: app)
            live.source = nil
            // SCREENKAST_SNAPSHOT_LOST=1: the capture was ended with "Stop sharing" in the macOS menu.
            if ProcessInfo.processInfo.environment["SCREENKAST_SNAPSHOT_LOST"] == "1" {
                live.lostSource(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue))
            }
            #if DEBUG
            // SCREENKAST_SNAPSHOT_MEETING=ready|new: camera and microphone set up or not.
            if let meeting = ProcessInfo.processInfo.environment["SCREENKAST_SNAPSHOT_MEETING"] {
                VirtualCamera.shared.pretend(meeting == "ready" ? .ready : .notInstalled)
                VirtualMicrophone.shared.pretend(meeting == "ready" ? .ready : .notInstalled)
            }
            #endif
            // SCREENKAST_SNAPSHOT_ACTIVE=1: the first logo and banner are shown.
            if ProcessInfo.processInfo.environment["SCREENKAST_SNAPSHOT_ACTIVE"] == "1" {
                if let logo = live.overlays.logos.first, live.shownLogoID != logo.id { live.toggle(logo: logo) }
                if let banner = live.overlays.banners.first, live.shownBannerID != banner.id { live.toggle(banner: banner) }
            }
            let height = Double(ProcessInfo.processInfo.environment["SCREENKAST_SNAPSHOT_HEIGHT"] ?? "") ?? 860
            return (try? write(LiveControlView(live: live, app: app).background(Theme.panel), width: 400, height: height, to: outputPath)) == nil ? 1 : 0
        }
        if projectPath == "livemixer" {
            AppModel.snapshotMode = true
            let live = LiveModel(app: AppModel())
            #if DEBUG
            VirtualMicrophone.shared.pretend(.ready)
            let headphones = ProcessInfo.processInfo.environment["SCREENKAST_SNAPSHOT_SPEAKERS"] != "1"
            live.audio.pretend(ear: LiveAudio.Ear(uid: "test", name: headphones ? "AirPods Pro" : "MacBook Air-Lautsprecher", headphones: headphones),
                               apps: [AudioApps.App(id: "com.brave.Browser", name: "Brave Browser", processes: [], playing: true),
                                      AudioApps.App(id: "com.apple.Keynote", name: "Keynote", processes: [], playing: false),
                                      AudioApps.App(id: "com.apple.Music", name: "Musik", processes: [], playing: true)],
                               meetingApp: "com.brave.Browser", meeting: .running)
            #endif
            let mixer = LiveMixerView(live: live, audio: live.audio).background(Theme.panel)
            return (try? write(mixer, width: 640, height: Double(ProcessInfo.processInfo.environment["SCREENKAST_SNAPSHOT_HEIGHT"] ?? "") ?? 520,
                               to: outputPath)) == nil ? 1 : 0
        }
        if projectPath == "livebanner" {
            AppModel.snapshotMode = true
            let live = LiveModel(app: AppModel())
            guard let banner = live.overlays.banners.first else { print("Kein Banner"); return 1 }
            return (try? write(LiveBannerEditor(live: live, library: live.overlays, bannerID: banner.id).background(Theme.panel),
                               width: 556, height: 560, to: outputPath)) == nil ? 1 : 0
        }
        if projectPath.hasPrefix("help") {
            HelpModel.shared.selection = projectPath.split(separator: ":").dropFirst().first.map(String.init) ?? "start"
            return (try? write(HelpView().frame(width: 1000, height: 740), width: 1000, height: 740, to: outputPath)) ?? 1
        }
        do {
            let project = try Project.load(from: URL(fileURLWithPath: projectPath))
            let editor = EditorModel(project: project)
            // Let the composition, echo state and waveforms load.
            let until = Date().addingTimeInterval(4)
            while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            if let first = editor.settings.texts.first(where: { $0.kind == .lowerThird }) {
                editor.selectedTextID = first.id
                editor.seek(to: first.start + 0.5)
            }
            // SCREENKAST_SNAPSHOT="zoomSpan scrollStart playhead": check zoomed timelines.
            let env = (ProcessInfo.processInfo.environment["SCREENKAST_SNAPSHOT"] ?? "").split(separator: " ").compactMap { Double($0) }
            if env.count >= 3 {
                editor.timelineWidth = 1400 - 310 - 24 - EditorTimeline.headerWidth   // default size
                editor.zoomSpan = env[0]
                editor.scrollStart = env[1]
                editor.seek(to: env[2])
            }
            if editor.selection == nil, let cut = editor.settings.cuts.first { editor.selectedCutID = cut.id }
            // SCREENKAST_SELECT = none | segment | tab:<style|camera|cursor|zoom|audio|text>
            switch ProcessInfo.processInfo.environment["SCREENKAST_SELECT"] ?? "" {
            case "none": editor.selection = nil
            case "segment": editor.selection = editor.videoSegments.dropFirst().first.map { .segment($0.lowerBound) }
            case let value where value.hasPrefix("tab:"):
                editor.selection = nil
                editor.inspectorTab = InspectorTab(rawValue: String(value.dropFirst(4))) ?? .style
            default: break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            // SCREENKAST_YOUTUBE=<video.mp4>: the YouTube upload helper ("-": without an exported video).
            if let video = ProcessInfo.processInfo.environment["SCREENKAST_YOUTUBE"] {
                let sheet = YouTubeUploadView(editor: editor, videoOverride: video == "-" ? nil : URL(fileURLWithPath: video)) {}
                    .tint(Theme.brand)
                    .background(Color(nsColor: .windowBackgroundColor))
                return try write(sheet, width: 620, height: 720, to: outputPath)
            }
            // SCREENKAST_SNAPSHOT_SIZE="1000x700" (default 1400x900)
            let sizeParts = (ProcessInfo.processInfo.environment["SCREENKAST_SNAPSHOT_SIZE"] ?? "1400x900")
                .split(separator: "x").compactMap { Double($0) }
            let width = sizeParts.count == 2 ? sizeParts[0] : 1400, height = sizeParts.count == 2 ? sizeParts[1] : 900
            let view = EditorWorkspace(editor: editor)
                .tint(Theme.brand)
                .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: width, height: height)
            return try write(view, width: width, height: height, to: outputPath)
        } catch {
            print("snapshot failed: \(error)")
            return 1
        }
    }

    /// The start page with the projects of the library.
    @MainActor
    private static func home(outputPath: String) -> Int32 {
        AppModel.snapshotMode = true
        let model = AppModel()
        let view = HomeView().environmentObject(model).tint(Theme.brand).frame(width: 1280, height: 820)
        let until = Date().addingTimeInterval(3)
        return (try? write(view, width: 1280, height: 820, to: outputPath, settle: until)) ?? 1
    }

    @MainActor
    private static func write<V: View>(_ view: V, width: Double, height: Double, to outputPath: String, settle: Date? = nil) throws -> Int32 {
        do {
            let host = NSHostingView(rootView: view)
            // The system appearance (dark/light) as in the app; SCREENKAST_APPEARANCE=light|dark overrides it.
            let dark = ProcessInfo.processInfo.environment["SCREENKAST_APPEARANCE"].map { $0 == "dark" }
                ?? (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            if let settle { while Date() < settle { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outputPath))
            print("snapshot → \(outputPath)")
            return 0
        } catch {
            print("snapshot failed: \(error)")
            return 1
        }
    }
}
