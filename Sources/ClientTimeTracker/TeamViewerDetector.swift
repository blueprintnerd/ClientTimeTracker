import Foundation

/// Detects whether a TeamViewer remote-control session is currently active.
///
/// There is no public TeamViewer API for this, so we combine several
/// independent signals and deliberately **fail closed**: when the signals
/// disagree or none is conclusive, we report `.unknown`, and the caller
/// does not bill time. Under-counting is recoverable by hand; billing a
/// client for hours nobody worked is not.
enum TeamViewerDetector {

    enum SessionState {
        case active
        case inactive
        /// Signals were missing or contradictory. Caller must not bill.
        case unknown
    }

    /// Everything we can observe, captured for the diagnostics panel so the
    /// heuristics can be validated on a real machine without guesswork.
    struct Diagnostics {
        var runningProcesses: [String] = []
        var mainLogPath: String?
        var mainLogLastStartMarker: Date?
        var mainLogLastEndMarker: Date?
        var mainLogLatestMarkerWasStart: Bool?
        var connectionsIncomingPath: String?
        var connectionsIncomingRowCount: Int?
        var connectionsIncomingLastRow: String?
        var resolvedState: SessionState = .unknown
        var explanation: String = ""
    }

    // MARK: - Candidate locations

    private static var logDirectoryCandidates: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/Library/Logs/TeamViewer",
            "/Library/Logs/TeamViewer",
        ]
    }

    /// `Connections_incoming.txt` records one row per *completed* incoming
    /// session (start and end timestamps, UTC). It is written when a session
    /// ends, so it cannot drive a live counter — but it is the best
    /// auditable record for reconciling an invoice.
    static func connectionsIncomingURL() -> URL? {
        for dir in logDirectoryCandidates {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("Connections_incoming.txt")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// The rolling main logfile (e.g. TeamViewer15_Logfile.log), which does
    /// carry real-time session markers.
    static func mainLogURL() -> URL? {
        let fm = FileManager.default
        for dir in logDirectoryCandidates {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let candidates = names.filter {
                $0.hasPrefix("TeamViewer") && $0.hasSuffix(".log") && !$0.contains("_old")
            }
            // Prefer the most recently modified logfile.
            let urls = candidates.map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
            let newest = urls.max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da < db
            }
            if let newest { return newest }
        }
        return nil
    }

    // MARK: - Signals

    /// Names of TeamViewer-related processes currently running.
    /// NOTE: it is NOT established that any of these are session-scoped.
    /// This is recorded for diagnostics and used only as corroboration,
    /// never as the sole trigger for billing.
    static func runningTeamViewerProcesses() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axco", "command"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            return text
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.lowercased().contains("teamviewer") }
                .reduce(into: [String]()) { acc, name in
                    if !acc.contains(name) { acc.append(name) }
                }
        } catch {
            return []
        }
    }

    private static let sessionStartMarker = "AddParticipant"
    private static let sessionEndMarker = "SessionTerminate"

    /// Scans the tail of the main logfile for the most recent session
    /// start/end marker. Returns nil when the log is unreadable or shows
    /// no markers at all.
    private static func latestMarkerIsStart(in log: URL, diagnostics: inout Diagnostics) -> Bool? {
        guard let data = try? Data(contentsOf: log) else { return nil }
        // The logfile defaults to ~1MB; cap the read anyway.
        let tail = data.suffix(1_500_000)
        let text = String(decoding: tail, as: UTF8.self)

        var lastStartLine: String?
        var lastEndLine: String?
        for line in text.split(separator: "\n") {
            if line.contains(sessionStartMarker) { lastStartLine = String(line) }
            if line.contains(sessionEndMarker) { lastEndLine = String(line) }
        }

        diagnostics.mainLogLastStartMarker = lastStartLine.flatMap(parseLogTimestamp)
        diagnostics.mainLogLastEndMarker = lastEndLine.flatMap(parseLogTimestamp)

        switch (lastStartLine, lastEndLine) {
        case (nil, nil):
            return nil
        case (_, nil):
            return true
        case (nil, _):
            return false
        case (let s?, let e?):
            // Prefer parsed timestamps; fall back to file order.
            if let ds = parseLogTimestamp(s), let de = parseLogTimestamp(e) {
                return ds > de
            }
            guard let si = text.range(of: s)?.lowerBound,
                  let ei = text.range(of: e)?.lowerBound else { return nil }
            return si > ei
        }
    }

    /// TeamViewer log lines begin with a timestamp like
    /// `2026/08/23 14:03:22.512`. Returns nil if the format doesn't match,
    /// which callers treat as "unknown" rather than guessing.
    private static func parseLogTimestamp(_ line: String) -> Date? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let stamp = "\(parts[0]) \(parts[1])"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy/MM/dd HH:mm:ss.SSS", "yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: stamp) { return date }
        }
        return nil
    }

    // MARK: - Combined state

    static func currentState() -> SessionState {
        collectDiagnostics().resolvedState
    }

    /// Gathers every signal and resolves them into a state, recording the
    /// reasoning so it can be displayed verbatim in the diagnostics panel.
    static func collectDiagnostics() -> Diagnostics {
        var d = Diagnostics()
        d.runningProcesses = runningTeamViewerProcesses()

        if let incoming = connectionsIncomingURL() {
            d.connectionsIncomingPath = incoming.path
            if let text = try? String(contentsOf: incoming, encoding: .utf8) {
                let rows = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                d.connectionsIncomingRowCount = rows.count
                d.connectionsIncomingLastRow = rows.last.map(String.init)
            }
        }

        if let log = mainLogURL() {
            d.mainLogPath = log.path
            d.mainLogLatestMarkerWasStart = latestMarkerIsStart(in: log, diagnostics: &d)
        }

        // Resolution, in order of trustworthiness.
        if d.runningProcesses.isEmpty {
            // TeamViewer isn't running at all; a session cannot be active.
            d.resolvedState = .inactive
            d.explanation = "No TeamViewer processes are running, so no session can be active. Not billing."
        } else if let latestIsStart = d.mainLogLatestMarkerWasStart {
            d.resolvedState = latestIsStart ? .active : .inactive
            d.explanation = latestIsStart
                ? "The most recent session marker in TeamViewer's log is a session START, so a session appears to be active. Billing."
                : "The most recent session marker in TeamViewer's log is a session END, so no session is active. Not billing."
        } else if d.mainLogPath == nil {
            d.resolvedState = .unknown
            d.explanation = "TeamViewer is running, but its logfile could not be found, so session state cannot be confirmed. Failing closed — NOT billing. Use the Task Timer to record this work manually."
        } else {
            d.resolvedState = .unknown
            d.explanation = "TeamViewer is running and its logfile was found, but it contains no recognisable session markers (the log may have rotated, or this TeamViewer version uses different wording). Failing closed — NOT billing. Use the Task Timer to record this work manually."
        }

        return d
    }

    /// Human-readable diagnostics report for the menu panel.
    static func report() -> String {
        let d = collectDiagnostics()
        var lines: [String] = []

        lines.append("RESOLVED STATE: \(String(describing: d.resolvedState).uppercased())")
        lines.append(d.explanation)
        lines.append("")

        lines.append("TeamViewer processes running:")
        lines.append(d.runningProcesses.isEmpty ? "  (none)" : d.runningProcesses.map { "  • \($0)" }.joined(separator: "\n"))
        lines.append("")

        lines.append("Main logfile:")
        lines.append("  \(d.mainLogPath ?? "(not found)")")
        if let isStart = d.mainLogLatestMarkerWasStart {
            lines.append("  Latest marker: \(isStart ? "SESSION START" : "SESSION END")")
        } else if d.mainLogPath != nil {
            lines.append("  Latest marker: (no recognisable session markers found)")
        }
        if let s = d.mainLogLastStartMarker { lines.append("  Last start marker at: \(s)") }
        if let e = d.mainLogLastEndMarker { lines.append("  Last end marker at: \(e)") }
        lines.append("")

        lines.append("Connections_incoming.txt (completed sessions, for invoice reconciliation):")
        lines.append("  \(d.connectionsIncomingPath ?? "(not found — note: this file only exists for INCOMING connections)")")
        if let count = d.connectionsIncomingRowCount { lines.append("  Rows: \(count)") }
        if let last = d.connectionsIncomingLastRow { lines.append("  Last row: \(last)") }

        return lines.joined(separator: "\n")
    }
}
