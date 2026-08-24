import AppKit
import CoreGraphics

/// Periodically captures full-screen screenshots as proof-of-work evidence.
///
/// This is disclosed recording: the client is aware it runs. The menu bar
/// shows a visible "recording" indicator whenever it is active, and capture
/// only happens while a TeamViewer session is active.
///
/// macOS requires the Screen Recording privacy permission. We check it
/// explicitly with `CGPreflightScreenCaptureAccess()` rather than trusting
/// `screencapture`'s exit code — without permission, `screencapture` still
/// exits 0 and writes a desktop-only image, so its status is not a reliable
/// signal. When permission is missing we skip the capture and surface it.
final class ScreenshotRecorder {

    /// How often to capture while active.
    let interval: TimeInterval = 120

    private(set) var lastCaptureDate: Date?
    private(set) var captureCountThisRun = 0
    private(set) var lastError: String?

    /// Cached count of stored shots, seeded once from disk and then kept in
    /// sync as we write, so `refreshDisplay()` never relists the directory.
    private(set) var storedCount: Int = 0

    /// True while an async capture is in flight, so we don't launch a second
    /// `screencapture` before the first returns.
    private var captureInProgress = false

    let storageDirectory: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        storageDirectory = base
            .appendingPathComponent("ClientTimeTracker", isDirectory: true)
            .appendingPathComponent("Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        storedCount = countStoredOnDisk()
    }

    /// Whether the app currently holds Screen Recording permission.
    /// Non-prompting; safe to call every tick.
    var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the one-time system permission prompt if not yet granted.
    @discardableResult
    func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Call every tick. Captures only if the interval has elapsed since the
    /// last shot and no capture is already running. Returns true if a
    /// capture was launched this call.
    @discardableResult
    func captureIfDue(now: Date = Date()) -> Bool {
        if captureInProgress { return false }
        if let last = lastCaptureDate, now.timeIntervalSince(last) < interval {
            return false
        }
        guard hasScreenRecordingPermission else {
            lastError = "Screen Recording permission not granted. Grant it in System Settings → Privacy & Security → Screen Recording, then reopen the app."
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

        captureInProgress = true

        // Run screencapture off the main thread so the ~1s capture never
        // freezes the menu-bar UI. State is mutated back on the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -x: silent (no shutter sound). -t jpg: compact format.
            // No -C so the cursor isn't captured; captures all displays.
            process.arguments = ["-x", "-t", "jpg", outURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            var resultError: String?
            var succeeded = false
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0,
                   FileManager.default.fileExists(atPath: outURL.path) {
                    succeeded = true
                } else {
                    resultError = "screencapture exited with status \(process.terminationStatus)."
                }
            } catch {
                resultError = "Could not run screencapture: \(error.localizedDescription)"
            }

            DispatchQueue.main.async {
                self.captureInProgress = false
                if succeeded {
                    self.lastCaptureDate = now
                    self.captureCountThisRun += 1
                    self.storedCount += 1
                    self.lastError = nil
                } else {
                    self.lastError = resultError
                }
            }
        }
    }

    private func countStoredOnDisk() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: storageDirectory.path))?
            .filter { $0.hasPrefix("shot_") }.count ?? 0
    }
}
