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

    private var tickTimer: Timer?
    private var lastTickWasCounting = false

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

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitTapped), keyEquivalent: "q")
        quitItem.target = self

        menu.addItem(statusLineItem)
        menu.addItem(remainingLineItem)
        menu.addItem(lifetimeLineItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(addHourItem)
        menu.addItem(clearTotalItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)
    }

    private func startTicking() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(tickTimer!, forMode: .common)
    }

    private func tick() {
        if bank.applyWeeklyResetIfNeeded() {
            // Week rolled over; hour bank is back to 10h, dollar total untouched.
        }

        let isUserActive = ActivityMonitor.idleSeconds() < idleThreshold
        let hasSession = ActivityMonitor.isTeamViewerSessionActive()
        let shouldCount = isUserActive && hasSession && bank.remainingSeconds > 0

        if shouldCount {
            bank.consumeSecond()
        }
        lastTickWasCounting = shouldCount

        refreshDisplay()
    }

    private func refreshDisplay() {
        let remaining = bank.remainingSeconds
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let timeString = String(format: "%dh %02dm", hours, minutes)

        statusItem.button?.title = (lastTickWasCounting ? "⏱ " : "⏸ ") + timeString

        let statusText: String
        if bank.remainingSeconds <= 0 {
            statusText = "Status: Out of time"
        } else if lastTickWasCounting {
            statusText = "Status: Counting"
        } else if !ActivityMonitor.isTeamViewerSessionActive() {
            statusText = "Status: Paused (no TeamViewer session)"
        } else {
            statusText = "Status: Paused (idle)"
        }
        statusLineItem.title = statusText

        remainingLineItem.title = "Remaining this week: \(timeString)"
        if bank.extraHoursThisWeek > 0 {
            remainingLineItem.title += "  (+\(bank.extraHoursThisWeek)h purchased)"
        }

        lifetimeLineItem.title = String(format: "Lifetime total: $%.2f", bank.lifetimeDollars)
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

    @objc private func quitTapped() {
        NSApp.terminate(nil)
    }
}
