import Foundation
import CoreGraphics

enum ActivityMonitor {
    /// Track teamviewer time open
    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0)!
        )
    }

    static func teamViewerState() -> TeamViewerDetector.SessionState {
        TeamViewerDetector.currentState()
    }
}
