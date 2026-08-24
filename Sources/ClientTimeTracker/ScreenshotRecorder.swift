import AppKit
import CoreGraphics

/// Periodically captures full-screen screenshots as secondary proof-of-work
/// evidence. Per contract Section 8, the written time log is the authoritative
/// record; screenshots only corroborate it, and installing this on the
/// client's machine requires their separate written consent (recorded via the
/// consent gate in the app). Capture is disclosed by a visible 🔴 indicator.
///
/// Safety brakes (so a stale "session active" reading can't capture forever):
///   • only while a TeamViewer session is active AND the user is not idle,
///   • a per-session age ceiling,
///   • stop after N consecutive idle intervals,
///   • a hard daily shot cap,
///   • a retention limit that prunes the oldest shots.
final class ScreenshotRecorder {

    let interval: TimeInterval = 120
    /// No single continuous session should record longer than this.
    let sessionAgeCeiling: TimeInterval = 10 * 3600
    /// Stop capturing after this many consecutive idle capture-intervals.
    let maxConsecutiveIdleIntervals = 3
    /// Never save more than this many shots per calendar day.
    let dailyShotCap = 300
    /// Keep at most this many shot files; prune oldest beyond it.
    let retentionLimit = 1500

    private(set) var lastCaptureDate: Date?
    private(set) var captureCountThisRun = 0
    private(set) var lastError: String?
    private(set) var storedCount: Int = 0

    private var captureInProgress = false
    private var currentSessionStart: Date?
    private var consecutiveIdleIntervals = 0
    private var shotsToday = 0
    private var shotsTodayKey = ""

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

    var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Call when a TeamViewer session becomes inactive (or the app decides to
    /// stop recording), so the next active session starts a fresh age clock.
    func sessionEnded() {
        currentSessionStart = nil
        consecutiveIdleIntervals = 0
    }

    /// Call every tick while a session is active.
    /// - Parameter userIsIdle: whether the user has been idle past the app's
    ///   idle threshold. Idle intervals are tolerated up to a limit, then
    ///   capture stops until activity resumes.
    /// - Returns true if a capture was launched this call.
    @discardableResult
    func captureIfDue(now: Date = Date(), userIsIdle: Bool, consentGranted: Bool) -> Bool {
        guard consentGranted else {
            lastError = "Screenshot consent not recorded. Capture is disabled until the client consents in the app."
            return false
        }
        if captureInProgress { return false }
        if let last = lastCaptureDate, now.timeIntervalSince(last) < interval {
            return false
        }

        if currentSessionStart == nil { currentSessionStart = now }

        // Brake: session age ceiling.
        if let start = currentSessionStart, now.timeIntervalSince(start) > sessionAgeCeiling {
            lastError = "Session exceeded \(Int(sessionAgeCeiling / 3600))h; screenshot capture stopped (likely a stale session marker). Reconnect to resume."
            return false
        }

        // Brake: consecutive idle intervals.
        if userIsIdle {
            consecutiveIdleIntervals += 1
        } else {
            consecutiveIdleIntervals = 0
        }
        if consecutiveIdleIntervals > maxConsecutiveIdleIntervals {
            lastError = "No activity for several intervals; screenshot capture paused until you resume working."
            return false
        }

        // Brake: daily shot cap.
        rolloverDayIfNeeded(now: now)
        if shotsToday >= dailyShotCap {
            lastError = "Daily screenshot cap (\(dailyShotCap)) reached; capture paused until tomorrow."
            return false
        }

        guard hasScreenRecordingPermission else {
            lastError = "Screen Recording permission not granted. Grant it in System Settings → Privacy & Security → Screen Recording, then reopen the app."
            return false
        }

        capture(now: now)
        return true
    }

    private func rolloverDayIfNeeded(now: Date) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let key = f.string(from: now)
        if key != shotsTodayKey {
            shotsTodayKey = key
            shotsToday = 0
        }
    }

    private func capture(now: Date) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "shot_\(formatter.string(from: now)).jpg"
        let outURL = storageDirectory.appendingPathComponent(filename)

        captureInProgress = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
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
                    self.shotsToday += 1
                    self.lastError = nil
                    self.pruneIfNeeded()
                } else {
                    self.lastError = resultError
                }
            }
        }
    }

    /// Prune the oldest shots beyond the retention limit.
    private func pruneIfNeeded() {
        guard storedCount > retentionLimit else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: storageDirectory.path) else { return }
        let shots = names.filter { $0.hasPrefix("shot_") }.sorted() // timestamped names sort chronologically
        let excess = shots.count - retentionLimit
        guard excess > 0 else { return }
        for name in shots.prefix(excess) {
            try? fm.removeItem(at: storageDirectory.appendingPathComponent(name))
        }
        storedCount = countStoredOnDisk()
    }

    private func countStoredOnDisk() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: storageDirectory.path))?
            .filter { $0.hasPrefix("shot_") }.count ?? 0
    }
}
