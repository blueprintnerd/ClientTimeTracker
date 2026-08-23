import Foundation
import CoreGraphics

/// Detects local user/input activity and whether TeamViewer currently has
/// an active remote-control session (not just the app open).
enum ActivityMonitor {

    /// Seconds since the last keyboard/mouse/trackpad event, system-wide.
    /// This also picks up synthetic input injected by TeamViewer while
    /// controlling the machine, so a remote session counts as "active".
    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0)!
        )
    }

    /// True while TeamViewer has a live remote-control session running.
    /// TeamViewer on macOS spawns a distinct "TeamViewer_Desktop" helper
    /// process only for the duration of an active session (incoming or
    /// outgoing); the main TeamViewer app/service process persists
    /// regardless of whether a session is connected, so we key off the
    /// helper process specifically rather than "TeamViewer is running".
    static func isTeamViewerSessionActive() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "TeamViewer_Desktop"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
