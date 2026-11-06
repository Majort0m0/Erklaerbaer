import AppKit
import QuartzCore

/// Notices when the main thread stops handling events and saves a stack sample
/// (`/usr/bin/sample`) to ~/Library/Logs/Screenkast, so a freeze can be diagnosed afterwards.
/// Active only while recording.
final class HangWatchdog: @unchecked Sendable {
    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Screenkast", isDirectory: true)

    let directory: URL
    let threshold: Double
    private let lock = NSLock()
    private var lastBeat = CACurrentMediaTime()
    private var active = false
    private var watcherStarted = false
    private var heartbeat: Timer?
    /// Reports written so far (for tests).
    private(set) var reports: [URL] = []

    init(directory: URL = HangWatchdog.defaultDirectory, threshold: Double = 4) {
        self.directory = directory
        self.threshold = threshold
    }

    @MainActor
    func start() {
        lock.withLock {
            lastBeat = CACurrentMediaTime()
            active = true
        }
        if heartbeat == nil {
            // Default run-loop mode on purpose: the beat also stops when the main thread is stuck
            // in a nested tracking loop (e.g. a window drag that never ends), not only when blocked.
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.beat() }
            RunLoop.main.add(t, forMode: .default)
            heartbeat = t
        }
        let startWatcher = lock.withLock { () -> Bool in
            defer { watcherStarted = true }
            return !watcherStarted
        }
        if startWatcher {
            let thread = Thread { [weak self] in self?.watch() }
            thread.name = "screenkast.hang-watchdog"
            thread.start()
        }
    }

    @MainActor
    func stop() {
        lock.withLock { active = false }
        heartbeat?.invalidate()
        heartbeat = nil
    }

    private func beat() {
        lock.withLock { lastBeat = CACurrentMediaTime() }
    }

    private func watch() {
        var reported = false
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            let (isActive, stall) = lock.withLock { (active, CACurrentMediaTime() - lastBeat) }
            guard isActive, stall >= threshold else {
                reported = false
                continue
            }
            if !reported {
                reported = true
                writeReport(stall: stall)
            }
        }
    }

    private func writeReport(stall: Double) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime])
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("Haenger-\(stamp).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        // -mayDie: read symbols right away, the app may get force-quit while sampling.
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "2", "-mayDie", "-file", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? "Haupt-Thread hing \(Int(stall)) s; sample ließ sich nicht starten: \(error)\n"
                .write(to: url, atomically: true, encoding: .utf8)
        }
        lock.withLock { reports.append(url) }
        NSLog("Screenkast: Haupt-Thread hing %.1f s – Bericht: %@", stall, url.path)
    }

    // MARK: Self-test (`Screenkast --hangtest <dir>`)

    /// Blocks the main thread for a few seconds and checks that a report with a stack sample appears.
    @MainActor
    static func selfTest(directory: URL) -> Int32 {
        _ = NSApplication.shared
        try? FileManager.default.removeItem(at: directory)
        let dog = HangWatchdog(directory: directory, threshold: 1.5)
        dog.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        print("blocking the main thread for 4 s …")
        Thread.sleep(forTimeInterval: 4)
        let deadline = Date().addingTimeInterval(30)
        while dog.lock.withLock({ dog.reports.isEmpty }) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        dog.stop()
        // The watchdog must not report again once the main thread runs normally.
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        let reports = dog.lock.withLock { dog.reports }
        guard reports.count == 1, let text = try? String(contentsOf: reports[0], encoding: .utf8) else {
            print("HANGTEST FAILED: \(reports.count) reports")
            return 1
        }
        guard text.contains("Call graph"), text.contains("selfTest") else {
            print("HANGTEST FAILED: report has no stack of the blocked main thread:\n\(text.prefix(800))")
            return 1
        }
        print("✓ hang report written: \(reports[0].path)")
        return 0
    }
}
