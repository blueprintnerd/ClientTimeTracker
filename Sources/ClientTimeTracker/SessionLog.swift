import Foundation

/// The written time log (contract Section 8, "the authoritative record for
/// any question about hours or billing"). Appends one CSV row per completed
/// work session — automatic TeamViewer-tracked sessions and manual task
/// timer sessions alike — to a plain file the developer can export and send.
final class SessionLog {

    let fileURL: URL

    /// Currently-open automatic session, if counting is in progress.
    private var openStart: Date?
    private var openBaseSeconds: TimeInterval = 0
    private var openOverageSeconds: TimeInterval = 0
    /// Timestamp of the most recent counted second, used as the end time if
    /// the machine is powered off mid-session and the row must be recovered.
    private var openLastCounted: Date?

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let pendingStart = "sessionlog.pendingStart"
        static let pendingBase = "sessionlog.pendingBase"
        static let pendingOverage = "sessionlog.pendingOverage"
        static let pendingLastCounted = "sessionlog.pendingLastCounted"
    }

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("ClientTimeTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("time_log.csv")
        ensureHeader()
    }

    private func ensureHeader() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let header = "type,start_iso,end_iso,duration_seconds,duration_hm,base_seconds,overage_seconds,note\n"
        try? header.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func hm(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%dh%02dm", s / 3600, (s % 3600) / 60)
    }

    private func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    private func append(type: String, start: Date, end: Date, base: TimeInterval, overage: TimeInterval, note: String) {
        let duration = end.timeIntervalSince(start)
        let row = [
            type,
            Self.iso.string(from: start),
            Self.iso.string(from: end),
            String(Int(duration.rounded())),
            hm(duration),
            String(Int(base.rounded())),
            String(Int(overage.rounded())),
            escape(note),
        ].joined(separator: ",") + "\n"

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = row.data(using: .utf8) { handle.write(data) }
        }
    }

    // MARK: - Crash/shutdown recovery

    /// If the previous run left an open session unclosed (e.g. the client
    /// powered off the Mac mid-session), write it to the log now using the
    /// last counted second as the end time. Call once at startup, before any
    /// new session begins.
    func recoverPendingSession() {
        guard let startEpoch = defaults.object(forKey: Keys.pendingStart) as? Double else { return }
        let start = Date(timeIntervalSince1970: startEpoch)
        let base = defaults.double(forKey: Keys.pendingBase)
        let overage = defaults.double(forKey: Keys.pendingOverage)
        let lastEpoch = defaults.object(forKey: Keys.pendingLastCounted) as? Double ?? startEpoch
        let end = Date(timeIntervalSince1970: lastEpoch)
        if base + overage > 0 {
            append(type: "auto", start: start, end: end,
                   base: base, overage: overage,
                   note: "recovered (Mac shut down mid-session)")
        }
        clearPending()
    }

    private func persistPending() {
        guard let start = openStart else { clearPending(); return }
        defaults.set(start.timeIntervalSince1970, forKey: Keys.pendingStart)
        defaults.set(openBaseSeconds, forKey: Keys.pendingBase)
        defaults.set(openOverageSeconds, forKey: Keys.pendingOverage)
        defaults.set((openLastCounted ?? start).timeIntervalSince1970, forKey: Keys.pendingLastCounted)
    }

    private func clearPending() {
        defaults.removeObject(forKey: Keys.pendingStart)
        defaults.removeObject(forKey: Keys.pendingBase)
        defaults.removeObject(forKey: Keys.pendingOverage)
        defaults.removeObject(forKey: Keys.pendingLastCounted)
    }

    // MARK: - Automatic session boundaries

    /// Marks that automatic counting has begun (or resumed after a gap).
    func beginAutomaticSessionIfNeeded(now: Date = Date()) {
        if openStart == nil {
            openStart = now
            openBaseSeconds = 0
            openOverageSeconds = 0
            openLastCounted = now
            persistPending()
        }
    }

    /// Records one counted second against the open session.
    func recordCountedSecond(kind: TimeBank.ConsumeOutcome, now: Date = Date()) {
        switch kind {
        case .base: openBaseSeconds += 1
        case .overage: openOverageSeconds += 1
        case .blocked: return
        }
        openLastCounted = now
    }

    /// Flush the open session's running state to disk so a hard power-off
    /// loses at most the time since the last flush. Call on a timer.
    func persistOpenState() {
        if openStart != nil { persistPending() }
    }

    /// Closes the open automatic session (if any) and writes it to the log.
    func endAutomaticSessionIfNeeded(now: Date = Date()) {
        guard let start = openStart else { return }
        // Only log sessions that actually accrued counted time.
        if openBaseSeconds + openOverageSeconds > 0 {
            append(type: "auto", start: start, end: openLastCounted ?? now,
                   base: openBaseSeconds, overage: openOverageSeconds,
                   note: "TeamViewer session")
        }
        openStart = nil
        openBaseSeconds = 0
        openOverageSeconds = 0
        openLastCounted = nil
        clearPending()
    }

    // MARK: - Manual task session

    func recordManualSession(start: Date, end: Date, charged: TimeInterval, forgiven: TimeInterval, estimate: TimeInterval) {
        let note = "task timer; est \(hm(estimate)); forgiven \(hm(forgiven))"
        append(type: "task", start: start, end: end,
               base: charged, overage: 0, note: note)
    }

    /// Number of logged rows (excluding the header).
    func rowCount() -> Int {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
        return max(0, text.split(separator: "\n").count - 1)
    }
}
