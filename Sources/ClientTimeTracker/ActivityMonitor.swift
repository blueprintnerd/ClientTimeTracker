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

    /// Session detection lives in `TeamViewerDetector`, which combines
    /// several signals and fails closed when they are inconclusive.
    static func teamViewerState() -> TeamViewerDetector.SessionState {
        TeamViewerDetector.currentState()
    }
}
