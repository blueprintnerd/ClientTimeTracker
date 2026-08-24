import AppKit

final class StatusBarController: NSObject, NSMenuDelegate {

    private let idleThreshold: Double = 45

    private let bank = TimeBank()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private let statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let remainingLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lifetimeLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var addHourItem: NSMenuItem!
    private var clearTotalItem: NSMenuItem!
    private var taskTimerLineItem: NSMenuItem!
    private var taskTimerToggleItem: NSMenuItem!
    private var diagnosticsItem: NSMenuItem!

    private var tickTimer: Timer?
    private var lastTickWasCounting = false
    private var lastTeamViewerState: TeamViewerDetector.SessionState = .unknown

    // Manual "lap timer" task session. While active, automatic
    // TeamViewer/idle-based counting is paused.
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
        remainingLineItem.isEnabled = false
        lifetimeLineItem.isEnabled = false

        addHourItem = NSMenuItem(
            title: "Add 1 Hour ($1)",
            action: #selector(addHourTapped),
            keyEquivalent: ""
        )
        addHourItem.target = self

        clearTotalItem = NSMenuItem(
            title: "Clear Lifetime Total…",
            action: #selector(clearTotalTapped),
            keyEquivalent: ""
        )
        clearTotalItem.target = self

        taskTimerLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        taskTimerLineItem.isEnabled = false
        taskTimerLineItem.isHidden = true

        taskTimerToggleItem = NSMenuItem(
            title: "Start Task Timer…",
            action: #selector(taskTimerToggleTapped),
            keyEquivalent: ""
        )
        taskTimerToggleItem.target = self

        let diagnosticsItem = NSMenuItem(
            title: "TeamViewer Diagnostics…",
            action: #selector(diagnosticsTapped),
            keyEquivalent: ""
        )
        diagnosticsItem.target = self
        self.diagnosticsItem = diagnosticsItem

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitTapped), keyEquivalent: "q")
        quitItem.target = self

        menu.addItem(statusLineItem)
        menu.addItem(remainingLineItem)
        menu.addItem(lifetimeLineItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(addHourItem)
        menu.addItem(clearTotalItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(taskTimerLineItem)
        menu.addItem(taskTimerToggleItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(diagnosticsItem)
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
        if bank.applyWeeklyResetIfNeeded() {
            // Week rolled over; hour bank is back to 10h, dollar total untouched.
        }

        if isTaskTimerRunning {
            // Manual task session in progress: automatic tracking is paused.
            lastTickWasCounting = false
        } else {
            let isUserActive = ActivityMonitor.idleSeconds() < idleThreshold
            lastTeamViewerState = ActivityMonitor.teamViewerState()
            // Only `.active` bills. `.unknown` deliberately does not —
            // see TeamViewerDetector for why we fail closed.
            let shouldCount = isUserActive
                && lastTeamViewerState == .active
                && bank.remainingSeconds > 0

            if shouldCount {
                bank.consumeSecond()
            }
            lastTickWasCounting = shouldCount
        }

        refreshDisplay()
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        return String(format: "%dh %02dm", hours, minutes)
    }

    private func refreshDisplay() {
        let timeString = formatDuration(bank.remainingSeconds)

        statusItem.button?.title = (isTaskTimerRunning ? "🧭 " : (lastTickWasCounting ? "⏱ " : "⏸ ")) + timeString

        let statusText: String
        if isTaskTimerRunning {
            statusText = "Status: Task timer running"
        } else if bank.remainingSeconds <= 0 {
            statusText = "Status: Out of time"
        } else if lastTickWasCounting {
            statusText = "Status: Counting"
        } else {
            switch lastTeamViewerState {
            case .inactive:
                statusText = "Status: Paused (no TeamViewer session)"
            case .unknown:
                statusText = "Status: Paused (can't confirm session — not billing)"
            case .active:
                statusText = "Status: Paused (idle)"
            }
        }
        statusLineItem.title = statusText

        remainingLineItem.title = "Remaining this week: \(timeString)"
        if bank.extraHoursThisWeek > 0 {
            remainingLineItem.title += "  (+\(bank.extraHoursThisWeek)h purchased)"
        }

        lifetimeLineItem.title = String(format: "Lifetime total: $%.2f", bank.lifetimeDollars)

        if let start = taskTimerStartDate, let estimate = taskTimerEstimateSeconds {
            let elapsed = Date().timeIntervalSince(start)
            let estimateHours = estimate / 3600
            taskTimerLineItem.title = "Task timer: \(formatDuration(elapsed)) elapsed (est. \(formatHours(estimateHours)))"
            taskTimerLineItem.isHidden = false
            taskTimerToggleItem.title = "Stop Task Timer"
        } else {
            taskTimerLineItem.isHidden = true
            taskTimerToggleItem.title = "Start Task Timer…"
        }
    }

    private func formatHours(_ hours: Double) -> String {
        hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshDisplay()
    }

    @objc private func addHourTapped() {
        let confirm = NSAlert()
        confirm.messageText = "Add 1 Hour for $1?"
        confirm.informativeText = "This adds 1 hour to this week's remaining time and $1.00 to the lifetime total."
        confirm.addButton(withTitle: "Add Hour")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        bank.addPurchasedHour()
        refreshDisplay()
    }

    @objc private func clearTotalTapped() {
        let prompt = NSAlert()
        prompt.messageText = "Clear Lifetime Total"
        prompt.informativeText = "Enter the password to reset the lifetime dollar total to $0.00. This week's remaining hours are not affected."
        prompt.addButton(withTitle: "Clear")
        prompt.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        prompt.accessoryView = field
        prompt.window.initialFirstResponder = field

        guard prompt.runModal() == .alertFirstButtonReturn else { return }

        if bank.clearLifetimeTotal(password: field.stringValue) {
            refreshDisplay()
        } else {
            let failure = NSAlert()
            failure.messageText = "Incorrect Password"
            failure.alertStyle = .warning
            failure.runModal()
        }
    }

    @objc private func taskTimerToggleTapped() {
        if isTaskTimerRunning {
            stopTaskTimer()
        } else {
            startTaskTimer()
        }
    }

    private func startTaskTimer() {
        let prompt = NSAlert()
        prompt.messageText = "Start Task Timer"
        prompt.informativeText = "Enter the estimated hours for this task. Automatic tracking pauses while this runs. If you go over the estimate, half of the overage (rounded to the nearest hour) is forgiven and the rest counts against the weekly cap; otherwise the full elapsed time counts."
        prompt.addButton(withTitle: "Start")
        prompt.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Hours, e.g. 2 or 1.5"
        prompt.accessoryView = field
        prompt.window.initialFirstResponder = field

        guard prompt.runModal() == .alertFirstButtonReturn else { return }

        guard let hours = Double(field.stringValue.trimmingCharacters(in: .whitespaces)), hours > 0 else {
            let failure = NSAlert()
            failure.messageText = "Invalid Estimate"
            failure.informativeText = "Enter a positive number of hours, e.g. 2 or 1.5."
            failure.alertStyle = .warning
            failure.runModal()
            return
        }

        taskTimerEstimateSeconds = hours * 3600
        taskTimerStartDate = Date()
        refreshDisplay()
    }

    private func stopTaskTimer() {
        guard let start = taskTimerStartDate, let estimate = taskTimerEstimateSeconds else { return }
        let elapsed = Date().timeIntervalSince(start)

        let result = bank.applyManualSession(elapsedSeconds: elapsed, estimateSeconds: estimate)

        taskTimerStartDate = nil
        taskTimerEstimateSeconds = nil
        refreshDisplay()

        let summary = NSAlert()
        summary.messageText = result.wentOverEstimate ? "Task Went Over Estimate" : "Task Timer Stopped"
        if result.wentOverEstimate {
            summary.informativeText = "Elapsed: \(formatDuration(result.elapsedSeconds)) (over your \(formatHours(estimate / 3600)) estimate). \(formatDuration(result.forgivenSeconds)) forgiven; \(formatDuration(result.chargedSeconds)) deducted from this week's cap."
        } else {
            summary.informativeText = "Elapsed: \(formatDuration(result.elapsedSeconds)), within your \(formatHours(estimate / 3600)) estimate. \(formatDuration(result.chargedSeconds)) deducted from this week's cap."
        }
        summary.runModal()
    }

    @objc private func diagnosticsTapped() {
        let report = TeamViewerDetector.report()

        let alert = NSAlert()
        alert.messageText = "TeamViewer Detection Diagnostics"
        alert.informativeText = "This shows exactly what the app can observe right now. Run it once with a TeamViewer session connected and once without, and compare — that confirms whether detection is working before you rely on it for billing."
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

    @objc private func quitTapped() {
        NSApp.terminate(nil)
    }
}
