import Foundation
import CryptoKit
final class TimeBank {

    static let weeklyBaseSeconds: TimeInterval = 10 * 3600
    static let maxOverageSecondsPerWeek: TimeInterval = 4 * 3600
    static let maxOveragePeriodSeconds: TimeInterval = 12 * 3600
    static let maxTotalCountedSecondsPerWeek: TimeInterval = 16 * 3600

    static let overageTier1Hours: Double = 2      
    static let overageTier1Rate: Double = 3.0   
    static let overageTier2Rate: Double = 6.0     
    static let billingIncrementSeconds: TimeInterval = 1800 
    private static let resetPasswordHash =
        "3c852a6e70d1e927d673d47ddd10993e7376c947eebfeda8fdd523a5ee92c692"

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let baseRemainingSeconds = "baseRemainingSeconds"
        static let overageSecondsThisWeek = "overageSecondsThisWeek"
        static let overageSecondsThisPeriod = "overageSecondsThisPeriod"
        static let completedWeeksOverageDollars = "completedWeeksOverageDollars"
        static let overageApprovedThisWeek = "overageApprovedThisWeek"
        static let lastResetWeekStart = "lastResetWeekStart"
        static let periodStart = "periodStart"
    }

    private(set) var baseRemainingSeconds: TimeInterval
    private(set) var overageSecondsThisWeek: TimeInterval
    private(set) var overageSecondsThisPeriod: TimeInterval
    /// Overage dollars locked in from earlier weeks this period (each week's
    /// tiered total is banked at the weekly reset).
    private(set) var completedWeeksOverageDollars: Double
    /// Whether the client has pre-approved overage for the current week.
    private(set) var overageApprovedThisWeek: Bool
    private var lastResetWeekStart: Date
    private(set) var periodStart: Date

    /// Set true by consume paths that mutate state, so a batched persist can
    /// flush on an interval rather than writing UserDefaults every second.
    private var dirty = false

    init() {
        if defaults.object(forKey: Keys.baseRemainingSeconds) == nil {
            baseRemainingSeconds = Self.weeklyBaseSeconds
            overageSecondsThisWeek = 0
            overageSecondsThisPeriod = 0
            completedWeeksOverageDollars = 0
            overageApprovedThisWeek = false
            lastResetWeekStart = Self.mostRecentSunday()
            periodStart = Date()
            forcePersist()
        } else {
            baseRemainingSeconds = defaults.double(forKey: Keys.baseRemainingSeconds)
            overageSecondsThisWeek = defaults.double(forKey: Keys.overageSecondsThisWeek)
            overageSecondsThisPeriod = defaults.double(forKey: Keys.overageSecondsThisPeriod)
            completedWeeksOverageDollars = defaults.double(forKey: Keys.completedWeeksOverageDollars)
            overageApprovedThisWeek = defaults.bool(forKey: Keys.overageApprovedThisWeek)
            let storedWeek = defaults.double(forKey: Keys.lastResetWeekStart)
            lastResetWeekStart = storedWeek > 0 ? Date(timeIntervalSince1970: storedWeek) : Self.mostRecentSunday()
            let storedPeriod = defaults.double(forKey: Keys.periodStart)
            periodStart = storedPeriod > 0 ? Date(timeIntervalSince1970: storedPeriod) : Date()
        }
        applyWeeklyResetIfNeeded()
    }

    // MARK: - Time math

    /// The most recent Sunday at 00:00 local time, relative to `date`.
    static func mostRecentSunday(from date: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1 // Sunday
        calendar.timeZone = .current
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    /// Two-tier weekly overage cost, rounded up to 30-minute increments.
    static func overageDollars(forWeekSeconds seconds: TimeInterval) -> Double {
        guard seconds > 0 else { return 0 }
        let increments = (seconds / billingIncrementSeconds).rounded(.up)
        let hours = increments * (billingIncrementSeconds / 3600) // 0.5-hr steps
        let tier1 = min(hours, overageTier1Hours)
        let tier2 = max(0, hours - overageTier1Hours)
        return tier1 * overageTier1Rate + tier2 * overageTier2Rate
    }

    /// Total overage owed this period: banked weeks plus the current week.
    var periodOverageDollars: Double {
        completedWeeksOverageDollars + Self.overageDollars(forWeekSeconds: overageSecondsThisWeek)
    }

    var currentWeekOverageDollars: Double {
        Self.overageDollars(forWeekSeconds: overageSecondsThisWeek)
    }

    var overageHeadroomSeconds: TimeInterval {
        let weekly = Self.maxOverageSecondsPerWeek - overageSecondsThisWeek
        let period = Self.maxOveragePeriodSeconds - overageSecondsThisPeriod
        let baseUsed = Self.weeklyBaseSeconds - baseRemainingSeconds
        let totalCeiling = Self.maxTotalCountedSecondsPerWeek - baseUsed - overageSecondsThisWeek
        return max(0, min(weekly, min(period, totalCeiling)))
    }

    @discardableResult
    func applyWeeklyResetIfNeeded(now: Date = Date()) -> Bool {
        let currentWeekStart = Self.mostRecentSunday(from: now)
        guard currentWeekStart > lastResetWeekStart else { return false }
        completedWeeksOverageDollars += Self.overageDollars(forWeekSeconds: overageSecondsThisWeek)
        baseRemainingSeconds = Self.weeklyBaseSeconds
        overageSecondsThisWeek = 0
        overageApprovedThisWeek = false
        lastResetWeekStart = currentWeekStart
        forcePersist()
        return true
    }

    // MARK: - Consumption

    enum ConsumeOutcome { case base, overage, blocked }

    /// Consume one second of worked time. Draws from the base cap first;
    /// once base is exhausted, draws from overage only if the client has
    /// approved overage this week and headroom remains under all ceilings.
    @discardableResult
    func consumeSecond() -> ConsumeOutcome {
        if baseRemainingSeconds > 0 {
            baseRemainingSeconds = max(0, baseRemainingSeconds - 1)
            dirty = true
            return .base
        }
        if overageApprovedThisWeek && overageHeadroomSeconds >= 1 {
            overageSecondsThisWeek += 1
            overageSecondsThisPeriod += 1
            dirty = true
            return .overage
        }
        return .blocked
    }


    var availableSeconds: TimeInterval {
        baseRemainingSeconds + (overageApprovedThisWeek ? overageHeadroomSeconds : 0)
    }

    func setOverageApprovedThisWeek(_ approved: Bool) {
        overageApprovedThisWeek = approved
        forcePersist()
    }

    struct ManualSessionResult {
        let elapsedSeconds: TimeInterval
        let estimateSeconds: TimeInterval
        let wentOverEstimate: Bool
        let forgivenSeconds: TimeInterval
        let chargedSeconds: TimeInterval
    }

    @discardableResult
    func applyManualSession(elapsedSeconds: TimeInterval, estimateSeconds: TimeInterval) -> ManualSessionResult {
        let wentOver = elapsedSeconds > estimateSeconds
        let forgivenSeconds: TimeInterval
        let chargedSeconds: TimeInterval

        if wentOver {
            let overageSeconds = elapsedSeconds - estimateSeconds
            let halfOverageHours = (overageSeconds / 2) / 3600
            let forgivenHours = halfOverageHours.rounded() // 30+ min rounds up
            forgivenSeconds = min(TimeInterval(forgivenHours) * 3600, overageSeconds)
            chargedSeconds = elapsedSeconds - forgivenSeconds
        } else {
            forgivenSeconds = 0
            chargedSeconds = elapsedSeconds
        }

        var remaining = chargedSeconds
        let fromBase = min(remaining, baseRemainingSeconds)
        baseRemainingSeconds -= fromBase
        remaining -= fromBase
        if remaining > 0 && overageApprovedThisWeek {
            let fromOverage = min(remaining, overageHeadroomSeconds)
            overageSecondsThisWeek += fromOverage
            overageSecondsThisPeriod += fromOverage
        }
        forcePersist()

        return ManualSessionResult(
            elapsedSeconds: elapsedSeconds,
            estimateSeconds: estimateSeconds,
            wentOverEstimate: wentOver,
            forgivenSeconds: forgivenSeconds,
            chargedSeconds: chargedSeconds
        )
    }


    @discardableResult
    func startNewPeriod(password: String) -> Bool {
        guard passwordMatches(password) else { return false }
        baseRemainingSeconds = Self.weeklyBaseSeconds
        overageSecondsThisWeek = 0
        overageSecondsThisPeriod = 0
        completedWeeksOverageDollars = 0
        overageApprovedThisWeek = false
        lastResetWeekStart = Self.mostRecentSunday()
        periodStart = Date()
        forcePersist()
        return true
    }

    /// Verify the reset/control password (used to gate manual stop/start).
    func verifyPassword(_ password: String) -> Bool {
        passwordMatches(password)
    }

    private func passwordMatches(_ password: String) -> Bool {
        let hash = SHA256.hash(data: Data(password.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return hex == Self.resetPasswordHash
    }

    // MARK: - Persistence

    /// Flush pending changes if any; call on a timer to batch per-second
    /// consumption into occasional writes.
    func flushIfDirty() {
        if dirty { forcePersist() }
    }

    private func forcePersist() {
        defaults.set(baseRemainingSeconds, forKey: Keys.baseRemainingSeconds)
        defaults.set(overageSecondsThisWeek, forKey: Keys.overageSecondsThisWeek)
        defaults.set(overageSecondsThisPeriod, forKey: Keys.overageSecondsThisPeriod)
        defaults.set(completedWeeksOverageDollars, forKey: Keys.completedWeeksOverageDollars)
        defaults.set(overageApprovedThisWeek, forKey: Keys.overageApprovedThisWeek)
        defaults.set(lastResetWeekStart.timeIntervalSince1970, forKey: Keys.lastResetWeekStart)
        defaults.set(periodStart.timeIntervalSince1970, forKey: Keys.periodStart)
        dirty = false
    }
}
