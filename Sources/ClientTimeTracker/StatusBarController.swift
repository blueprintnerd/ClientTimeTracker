import AppKit

final class StatusBarController: NSObject, NSMenuDelegate {

    private let idleThreshold: Double = 45
    /// TeamViewer detection is comparatively expensive (spawns `ps`, reads a
    /// log); refresh it only every N seconds rather than every tick.
    private let detectionInterval: TimeInterval = 15
    /// Batch per-second consumption into occasional UserDefaults writes.
    private let flushInterval: TimeInterval = 15

    private let bank = TimeBank()
    private let recorder = ScreenshotRecorder()
    private let sessionLog = SessionLog()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private let defaults = UserDefaults.standard
    private let consentKey = "screenshotConsentGranted"
    private var screenshotConsentGranted: Bool {
        get { defaults.bool(forKey: consentKey) }
        set { defaults.set(newValue, forKey: consentKey) }
    }

    private let statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let baseLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let overageLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var approveOverageItem: NSMenuItem!
    private var taskTimerLineItem: NSMenuItem!
    private var taskTimerToggleItem: NSMenuItem!
    private var diagnosticsItem: NSMenuItem!
    private var recordingLineItem: NSMenuItem!
    private var consentItem: NSMenuItem!
    private var openShotsItem: NSMenuItem!
    private var exportLogItem: NSMenuItem!
    private var newPeriodItem: NSMenuItem!

    private var tickTimer: Timer?
    private var lastTickWasCounting = false
    private var lastTeamViewerState: TeamViewerDetector.SessionState = .unknown
    private var lastDetectionAt: Date = .distantPast
    private var lastFlushAt: Date = Date()

    private var taskTimerEstimateSeconds: TimeInterval?
    private var taskTimerStartDate: Date?

    override init() {
        super.init()
        buildMenu()
        statusItem.menu = menu
        menu.delegate = self
        refreshDisplay()
        startTicking()
    }

    private func buildMenu() {
        statusLineItem.isEnabled = false
        baseLineItem.isEnabled = false
        overageLineItem.isEnabled = false

        approveOverageItem = NSMenuItem(
            title: "Approve Overage This Week…",
            action: #selector(approveOverageTapped),
            keyEquivalent: ""
        )
        approveOverageItem.target = self

        taskTimerLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        taskTimerLineItem.isEnabled = false
        taskTimerLineItem.isHidden = true

        taskTimerToggleItem = NSMenuItem(
            title: "Start Task Timer…",
            action: #selector(taskTimerToggleTapped),
            keyEquivalent: ""
        )
        taskTimerToggleItem.target = self

        recordingLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        recordingLineItem.isEnabled = false

        consentItem = NSMenuItem(
            title: "Screenshot Consent…",
            action: #selector(consentTapped),
            keyEquivalent: ""
        )
        consentItem.target = self

        openShotsItem = NSMenuItem(
            title: "Open Screenshots Folder",
            action: #selector(openShotsTapped),
            keyEquivalent: ""
        )
        openShotsItem.target = self

        exportLogItem = NSMenuItem(
            title: "Export Time Log (CSV)…",
            action: #selector(exportLogTapped),
            keyEquivalent: ""
        )
        exportLogItem.target = self

        let diagnosticsItem = NSMenuItem(
            title: "TeamViewer Diagnostics…",
            action: #selector(diagnosticsTapped),
            keyEquivalent: ""
        )
        diagnosticsItem.target = self
        self.diagnosticsItem = diagnosticsItem

        newPeriodItem = NSMenuItem(
            title: "Start New 30-Day Period…",
            action: #selector(newPeriodTapped),
            keyEquivalent: ""
        )
        newPeriodItem.target = self

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitTapped), keyEquivalent: "q")
        quitItem.target = self

        menu.addItem(statusLineItem)
        menu.addItem(baseLineItem)
        menu.addItem(overageLineItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(approveOverageItem)
        menu.addItem(taskTimerLineItem)
        menu.addItem(taskTimerToggleItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(recordingLineItem)
        menu.addItem(consentItem)
        menu.addItem(openShotsItem)
        menu.addItem(exportLogItem)
        menu.addItem(diagnosticsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(newPeriodItem)
        menu.addItem(quitItem)
    }

    private func startTicking() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(tickTimer!, forMode: .common)
    }

    private var isTaskTimerRunning: Bool { taskTimerStartDate != nil }

    private func tick() {
        let now = Date()
        bank.applyWeeklyResetIfNeeded(now: now)

        // Cached, throttled TeamViewer detection.
        if now.timeIntervalSince(lastDetectionAt) >= detectionInterval {
            lastTeamViewerState = ActivityMonitor.teamViewerState()
            lastDetectionAt = now
        }
        let tvActive = (lastTeamViewerState == .active)
        let idleSeconds = ActivityMonitor.idleSeconds()
        let userIsIdle = idleSeconds >= idleThreshold

        if isTaskTimerRunning {
            lastTickWasCounting = false
            sessionLog.endAutomaticSessionIfNeeded(now: now)
        } else {
            let shouldCount = !userIsIdle && tvActive && bank.availableSeconds > 0
            if shouldCount {
                sessionLog.beginAutomaticSessionIfNeeded(now: now)
                let outcome = bank.consumeSecond()
                sessionLog.recordCountedSecond(kind: outcome)
                if outcome == .blocked {
                    lastTickWasCounting = false
                    sessionLog.endAutomaticSessionIfNeeded(now: now)
                } else {
                    lastTickWasCounting = true
                }
            } else {
                lastTickWasCounting = false
                sessionLog.endAutomaticSessionIfNeeded(now: now)
            }
        }

        // Proof-of-work screenshots: only while a session is active, gated by
        // consent, with the recorder's own safety brakes handling idle/age/cap.
        if tvActive {
            recorder.captureIfDue(now: now, userIsIdle: userIsIdle, consentGranted: screenshotConsentGranted)
        } else {
            recorder.sessionEnded()
        }

        if now.timeIntervalSince(lastFlushAt) >= flushInterval {
            bank.flushIfDirty()
            lastFlushAt = now
        }

        refreshDisplay()
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        return String(format: "%dh %02dm", totalSeconds / 3600, (totalSeconds % 3600) / 60)
    }

    private func formatHours(_ hours: Double) -> String {
        hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
    }

    private func refreshDisplay() {
        let tvActive = (lastTeamViewerState == .active)
        let recordingLive = tvActive && screenshotConsentGranted && recorder.lastError == nil
        let recPrefix = recordingLive ? "🔴 " : ""
        let baseString = formatDuration(bank.baseRemainingSeconds)
        statusItem.button?.title = recPrefix + (isTaskTimerRunning ? "🧭 " : (lastTickWasCounting ? "⏱ " : "⏸ ")) + baseString

        let statusText: String
        if isTaskTimerRunning {
            statusText = "Status: Task timer running"
        } else if lastTickWasCounting {
            statusText = bank.baseRemainingSeconds > 0 ? "Status: Counting (base)" : "Status: Counting (overage)"
        } else if bank.availableSeconds <= 0 {
            statusText = "Status: Out of hours this week"
        } else {
            switch lastTeamViewerState {
            case .inactive: statusText = "Status: Paused (no TeamViewer session)"
            case .unknown:  statusText = "Status: Paused (can't confirm session — not billing)"
            case .active:   statusText = "Status: Paused (idle)"
            }
        }
        statusLineItem.title = statusText

        let baseUsed = TimeBank.weeklyBaseSeconds - bank.baseRemainingSeconds
        baseLineItem.title = "Base: \(formatDuration(baseUsed)) used / \(formatDuration(bank.baseRemainingSeconds)) left of 10h this week"

        let owed = bank.periodOverageDollars
        let wk = formatDuration(bank.overageSecondsThisWeek)
        let pd = formatDuration(bank.overageSecondsThisPeriod)
        let approval = bank.overageApprovedThisWeek ? "approved" : "not approved"
        overageLineItem.title = String(
            format: "Overage: %@ this wk / %@ period (%@) — $%.2f owed",
            wk, pd, approval, owed
        )

        approveOverageItem.title = bank.overageApprovedThisWeek
            ? "Revoke Overage Approval This Week"
            : "Approve Overage This Week…"

        // Recording status line.
        let shots = recorder.storedCount
        if !screenshotConsentGranted {
            recordingLineItem.title = "Screenshots OFF — client consent not recorded (\(shots) saved)"
        } else if recordingLive {
            recordingLineItem.title = "🔴 Recording (session active) — \(shots) shots"
        } else if tvActive {
            recordingLineItem.title = "Screenshots paused — \(shots) shots"
        } else {
            recordingLineItem.title = "Screenshots idle (no session) — \(shots) shots"
        }
        if let err = recorder.lastError, screenshotConsentGranted {
            recordingLineItem.title += "  ⚠︎ " + err
        }
        consentItem.title = screenshotConsentGranted ? "Screenshot Consent (granted)…" : "Screenshot Consent (not granted)…"

        if let start = taskTimerStartDate, let estimate = taskTimerEstimateSeconds {
            let elapsed = Date().timeIntervalSince(start)
            taskTimerLineItem.title = "Task timer: \(formatDuration(elapsed)) elapsed (est. \(formatHours(estimate / 3600)))"
            taskTimerLineItem.isHidden = false
            taskTimerToggleItem.title = "Stop Task Timer"
        } else {
            taskTimerLineItem.isHidden = true
            taskTimerToggleItem.title = "Start Task Timer…"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshDisplay()
    }

    // MARK: - Overage approval

    @objc private func approveOverageTapped() {
        if bank.overageApprovedThisWeek {
            bank.setOverageApprovedThisWeek(false)
            refreshDisplay()
            return
        }
        let a = NSAlert()
        a.messageText = "Approve Overage This Week?"
        a.informativeText = """
        This records that the client has pre-approved overage for the current week, per Section 5.
        Rates: first 2 hrs $3/hr, then $6/hr. Caps: 4 hrs/week, 12 hrs/period, $54 max.
        Overage counts only after the 10-hour base cap is used up, and is billed with the Day 30 payment.
        """
        a.addButton(withTitle: "Approve")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        bank.setOverageApprovedThisWeek(true)
        refreshDisplay()
    }

    // MARK: - Task timer

    @objc private func taskTimerToggleTapped() {
        isTaskTimerRunning ? stopTaskTimer() : startTaskTimer()
    }

    private func startTaskTimer() {
        let prompt = NSAlert()
        prompt.messageText = "Start Task Timer"
        prompt.informativeText = "Enter the estimated hours for this task. Automatic tracking pauses while this runs. If you go over the estimate, half of the overage (rounded to the nearest hour) is forgiven and the rest is charged; otherwise the full elapsed time is charged (base first, then approved overage)."
        prompt.addButton(withTitle: "Start")
        prompt.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Hours, e.g. 2 or 1.5"
        prompt.accessoryView = field
        prompt.window.initialFirstResponder = field

        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        guard let hours = Double(field.stringValue.trimmingCharacters(in: .whitespaces)), hours > 0 else {
            let f = NSAlert()
            f.messageText = "Invalid Estimate"
            f.informativeText = "Enter a positive number of hours, e.g. 2 or 1.5."
            f.alertStyle = .warning
            f.runModal()
            return
        }
        taskTimerEstimateSeconds = hours * 3600
        taskTimerStartDate = Date()
        refreshDisplay()
    }

    private func stopTaskTimer() {
        guard let start = taskTimerStartDate, let estimate = taskTimerEstimateSeconds else { return }
        let end = Date()
        let elapsed = end.timeIntervalSince(start)
        let result = bank.applyManualSession(elapsedSeconds: elapsed, estimateSeconds: estimate)
        sessionLog.recordManualSession(start: start, end: end,
                                       charged: result.chargedSeconds,
                                       forgiven: result.forgivenSeconds,
                                       estimate: estimate)

        taskTimerStartDate = nil
        taskTimerEstimateSeconds = nil
        refreshDisplay()

        let summary = NSAlert()
        summary.messageText = result.wentOverEstimate ? "Task Went Over Estimate" : "Task Timer Stopped"
        if result.wentOverEstimate {
            summary.informativeText = "Elapsed: \(formatDuration(result.elapsedSeconds)) (over your \(formatHours(estimate / 3600)) estimate). \(formatDuration(result.forgivenSeconds)) forgiven; \(formatDuration(result.chargedSeconds)) charged."
        } else {
            summary.informativeText = "Elapsed: \(formatDuration(result.elapsedSeconds)), within your \(formatHours(estimate / 3600)) estimate. \(formatDuration(result.chargedSeconds)) charged."
        }
        summary.runModal()
    }

    // MARK: - Screenshot consent

    @objc private func consentTapped() {
        if screenshotConsentGranted {
            let a = NSAlert()
            a.messageText = "Screenshot Recording Consent"
            a.informativeText = consentDisclosureText() + "\n\nConsent is currently GRANTED. You may withdraw it at any time."
            a.addButton(withTitle: "Keep Enabled")
            a.addButton(withTitle: "Withdraw Consent")
            if a.runModal() == .alertSecondButtonReturn {
                screenshotConsentGranted = false
                recorder.sessionEnded()
                refreshDisplay()
            }
            return
        }

        let a = NSAlert()
        a.messageText = "Screenshot Recording Consent (Section 8)"
        a.informativeText = consentDisclosureText() + "\n\nBy clicking \"I Consent\", the client agrees to this recording. Nothing is captured until consent is given."
        a.addButton(withTitle: "I Consent")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        screenshotConsentGranted = true
        // Now that consent exists, trigger the OS Screen Recording prompt.
        recorder.requestPermission()
        refreshDisplay()
    }

    private func consentDisclosureText() -> String {
        """
        What it records: a full-screen screenshot roughly every 2 minutes, only while a TeamViewer session is active and you are not idle.
        Where it is stored: locally on this Mac, at
        \(recorder.storageDirectory.path)
        It is never uploaded anywhere.
        How to stop/remove it: withdraw consent here (stops immediately), quit the app, and delete the folder above.
        Safety limits: capture stops after long idle, after \(Int(recorder.sessionAgeCeiling / 3600))h continuous, and at a daily cap; old shots are pruned automatically.
        """
    }

    @objc private func openShotsTapped() {
        NSWorkspace.shared.open(recorder.storageDirectory)
    }

    // MARK: - Export

    @objc private func exportLogTapped() {
        bank.flushIfDirty()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "time_log.csv"
        panel.message = "Export the authoritative time log (Section 8)."
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: sessionLog.fileURL, to: dest)
        } catch {
            let f = NSAlert()
            f.messageText = "Export Failed"
            f.informativeText = error.localizedDescription
            f.alertStyle = .warning
            f.runModal()
        }
    }

    // MARK: - Diagnostics

    @objc private func diagnosticsTapped() {
        let report = TeamViewerDetector.report()
        let alert = NSAlert()
        alert.messageText = "TeamViewer Detection Diagnostics"
        alert.informativeText = "This shows exactly what the app can observe right now. Run it once with a session connected and once without, and compare — that confirms whether detection works before you rely on it for billing."
        alert.addButton(withTitle: "Copy to Clipboard")
        alert.addButton(withTitle: "Close")

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
        textView.string = report
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll

        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }

    // MARK: - Period reset

    @objc private func newPeriodTapped() {
        let prompt = NSAlert()
        prompt.messageText = "Start New 30-Day Period"
        prompt.informativeText = "Enter the password to start a fresh period. This resets the base cap and clears all overage tracking (hours and dollars owed) for the new period. The exported time log is not affected."
        prompt.addButton(withTitle: "Start New Period")
        prompt.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        prompt.accessoryView = field
        prompt.window.initialFirstResponder = field
        guard prompt.runModal() == .alertFirstButtonReturn else { return }

        if bank.startNewPeriod(password: field.stringValue) {
            refreshDisplay()
        } else {
            let f = NSAlert()
            f.messageText = "Incorrect Password"
            f.alertStyle = .warning
            f.runModal()
        }
    }

    @objc private func quitTapped() {
        bank.flushIfDirty()
        sessionLog.endAutomaticSessionIfNeeded()
        NSApp.terminate(nil)
    }
}
