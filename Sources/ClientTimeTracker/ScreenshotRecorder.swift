import AppKit

/// Periodically captures full-screen screenshots as proof-of-work evidence.
///
/// This is disclosed recording: the client is aware it runs. The menu bar
/// shows a visible "recording" indicator whenever it is active, and capture
/// only happens while a TeamViewer session is active.
///
/// macOS requires the Screen Recording privacy permission for any capture to
/// succeed; the first attempt triggers the system prompt. Without it,
/// `screencapture` produces a blank/desktop-only image, so we surface the
/// permission state in diagnostics rather than silently saving useless files.
final class ScreenshotRecorder {

    /// How often to capture while active.
    let interval: TimeInterval = 120

    private(set) var lastCaptureDate: Date?
    private(set) var captureCountThisRun = 0
    private(set) var lastError: String?

    let storageDirectory: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        storageDirectory = base
            .appendingPathComponent("ClientTimeTracker", isDirectory: true)
            .appendingPathComponent("Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }

    /// Call every tick. Captures only if the interval has elapsed since the
    /// last shot. Returns true if a capture was taken this call.
    @discardableResult
    func captureIfDue(now: Date = Date()) -> Bool {
        if let last = lastCaptureDate, now.timeIntervalSince(last) < interval {
            return false
        }
        capture(now: now)
        return true
    }

    private func capture(now: Date) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "shot_\(formatter.string(from: now)).jpg"
        let outURL = storageDirectory.appendingPathComponent(filename)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x: silent (no shutter sound). -t jpg: compact format.
        // No -C so the cursor isn't captured; captures all displays.
        process.arguments = ["-x", "-t", "jpg", outURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0,
               FileManager.default.fileExists(atPath: outURL.path) {
                lastCaptureDate = now
                captureCountThisRun += 1
                lastError = nil
            } else {
                lastError = "screencapture exited with status \(process.terminationStatus). Screen Recording permission may not be granted."
            }
        } catch {
            lastError = "Could not run screencapture: \(error.localizedDescription)"
        }
    }

    /// Number of screenshot files currently stored.
    func storedCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: storageDirectory.path))?
            .filter { $0.hasPrefix("shot_") }.count ?? 0
    }
}
