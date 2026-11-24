import AppKit
import AVFoundation
import CoreAudio

/// What the app and its audio driver (VirtualCamera/Audio) agree on.
enum VirtualMicrophoneIDs {
    /// The input device meeting programs record from.
    static let micUID = "ErklaerbaerMikrofon"
    /// The hidden output device Erklärbär plays its mix into.
    static let feedUID = "ErklaerbaerZuspielung"
    static let driverName = "ErklaerbaerAudio.driver"
    static let installed = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/ErklaerbaerAudio.driver")
    static let sampleRate = 48_000.0

    static func isOwnMicrophone(_ uniqueID: String) -> Bool { uniqueID == micUID || uniqueID == feedUID }
}

/// The microphone "Erklärbär" for meetings: an audio driver inside the app that is copied to
/// /Library/Audio/Plug-Ins/HAL once (with the administrator password). Then Erklärbär sends the chosen
/// microphone and, if wanted, the sound of the Mac through it.
@MainActor
final class VirtualMicrophone: ObservableObject {
    static let shared = VirtualMicrophone()

    enum Status: Equatable {
        case checking
        case unavailable(String)
        case notInstalled
        /// Installed, but an older driver than the one inside the app.
        case outdated
        case installing
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .checking
    @Published var sending: Bool = UserDefaults.standard.object(forKey: "virtualMicOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sending, forKey: "virtualMicOn") }
    }
    /// Bundle id of the meeting program: its sound (the voices of the others) never goes back into the meeting.
    @Published var meetingApp: String = UserDefaults.standard.string(forKey: "virtualMicMeetingApp") ?? "" {
        didSet { UserDefaults.standard.set(meetingApp, forKey: "virtualMicMeetingApp") }
    }

    static var bundledDriver: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Audio/\(VirtualMicrophoneIDs.driverName)") }

    private static func version(_ driver: URL) -> String? {
        (NSDictionary(contentsOf: driver.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleVersion"] as? String
    }

    var isBundled: Bool { FileManager.default.fileExists(atPath: Self.bundledDriver.path) }

    func refresh() {
        guard status != .installing else { return }
        guard isBundled else {
            status = .unavailable("Diese Ausgabe von Erklärbär enthält kein Mikrofon für Meetings.")
            return
        }
        guard let installed = Self.version(VirtualMicrophoneIDs.installed) else {
            status = .notInstalled
            return
        }
        if installed != Self.version(Self.bundledDriver) {
            status = .outdated
        } else if AudioDevices.device(uid: VirtualMicrophoneIDs.feedUID) == nil {
            status = .failed("Das Mikrofon ist eingerichtet, meldet sich aber nicht. Ein Neustart des Macs hilft meist.")
        } else {
            status = .ready
        }
        if meetingApp.isEmpty { meetingApp = Self.guessMeetingApp() ?? "" }
    }

    private static let shell = "/Library/Audio/Plug-Ins/HAL"
    /// The sound system loads drivers only when it starts.
    private static let restartAudio = "(/bin/launchctl kickstart -k system/com.apple.audio.coreaudiod || /usr/bin/killall coreaudiod)"

    /// Copies the driver (macOS asks for the administrator password) and restarts the sound system.
    func install() {
        guard isBundled else { return refresh() }
        status = .installing
        let source = Self.bundledDriver.path
        let target = VirtualMicrophoneIDs.installed.path
        let command = "/bin/mkdir -p \(Self.shell) && /bin/rm -rf \(target) && /usr/bin/ditto \" & quoted form of \"\(Self.escaped(source))\" & \" \(target) && /usr/sbin/chown -R root:wheel \(target) && \(Self.restartAudio)"
        runAsAdministrator(command, prompt: "Erklärbär möchte das Mikrofon „Erklärbär“ für Meetings einrichten.") { [weak self] error in
            guard let self else { return }
            if let error {
                self.status = .failed(error)
                return
            }
            Task { @MainActor in
                // The sound system needs a moment until the new devices are there.
                for _ in 0..<40 where AudioDevices.device(uid: VirtualMicrophoneIDs.feedUID) == nil {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                self.status = .checking
                self.refresh()
            }
        }
    }

    func remove() {
        let target = VirtualMicrophoneIDs.installed.path
        runAsAdministrator("/bin/rm -rf \(target) && \(Self.restartAudio)",
                           prompt: "Erklärbär möchte das Mikrofon „Erklärbär“ entfernen.") { [weak self] error in
            self?.status = error.map { .failed($0) } ?? .notInstalled
        }
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Runs the shell command with administrator rights (macOS shows its password dialog).
    private func runAsAdministrator(_ command: String, prompt: String, done: @escaping @MainActor (String?) -> Void) {
        let source = "do shell script \"\(command)\" with prompt \"\(Self.escaped(prompt))\" with administrator privileges"
        // Give SwiftUI a moment to show the spinner before the dialog blocks the main thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            var info: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&info)
            guard let info else { return done(nil) }
            let code = info[NSAppleScript.errorNumber] as? Int ?? 0
            done(code == -128 ? "Abgebrochen." : "Das ging nicht: \(info[NSAppleScript.errorMessage] as? String ?? "Fehler \(code)")")
        }
    }

    #if DEBUG
    /// Pictures of the control window in a state (debug builds only).
    func pretend(_ new: Status) { status = new }
    #endif

    // MARK: Meeting program

    /// Programs whose sound must not go back into the meeting, most likely first.
    static let meetingApps = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp",
        "com.apple.FaceTime", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.skype.skype",
        "com.brave.Browser", "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// Meetings in these play from the browser's own sound process: everything from it stays out.
    static let browsers: Set<String> = [
        "com.brave.Browser", "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static func guessMeetingApp() -> String? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return meetingApps.first { running.contains($0) }
    }

    /// Programs to choose from: the running ones with a window.
    static func runningApps() -> [(id: String, name: String)] {
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != own }
            .map { ($0.bundleIdentifier!, $0.localizedName ?? $0.bundleIdentifier!) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
