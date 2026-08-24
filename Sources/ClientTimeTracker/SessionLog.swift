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

    // MARK: - Automatic session boundaries

    /// Marks that automatic counting has begun (or resumed after a gap).
    func beginAutomaticSessionIfNeeded(now: Date = Date()) {
        if openStart == nil {
            openStart = now
            openBaseSeconds = 0
            openOverageSeconds = 0
        }
    }

    /// Records one counted second against the open session.
    func recordCountedSecond(kind: TimeBank.ConsumeOutcome) {
        switch kind {
        case .base: openBaseSeconds += 1
        case .overage: openOverageSeconds += 1
        case .blocked: break
        }
    }

    /// Closes the open automatic session (if any) and writes it to the log.
    func endAutomaticSessionIfNeeded(now: Date = Date()) {
        guard let start = openStart else { return }
        // Only log sessions that actually accrued counted time.
        if openBaseSeconds + openOverageSeconds > 0 {
            append(type: "auto", start: start, end: now,
                   base: openBaseSeconds, overage: openOverageSeconds,
                   note: "TeamViewer session")
        }
        openStart = nil
        openBaseSeconds = 0
        openOverageSeconds = 0
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
