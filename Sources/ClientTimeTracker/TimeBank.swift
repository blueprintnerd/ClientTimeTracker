import Foundation
import CryptoKit

/// Tracks worked time against the rev5 contract model:
/// - A 10-hour weekly base cap (Section 5).
/// - Pre-approved overage beyond the cap, billed on a two-tier weekly scale
///   (first 2 hrs $3/hr, every hour after $6/hr), rounded up to 30-minute
///   increments, capped at 4 hrs/week and 12 hrs across the 30-day period
///   (max $54).
/// - Estimate-overrun forgiveness for manual task sessions (Section 6).
///
/// The app is a tracking aid; per Section 8 the developer's written log is
/// the authoritative billing record. See `SessionLog` for the exportable log.
final class TimeBank {

    static let weeklyBaseSeconds: TimeInterval = 10 * 3600
    static let maxOverageSecondsPerWeek: TimeInterval = 4 * 3600
    static let maxOveragePeriodSeconds: TimeInterval = 12 * 3600
    static let maxTotalCountedSecondsPerWeek: TimeInterval = 16 * 3600

    static let overageTier1Hours: Double = 2      // first 2 overage hrs/week
    static let overageTier1Rate: Double = 3.0     // $/hr
    static let overageTier2Rate: Double = 6.0     // $/hr thereafter
    static let billingIncrementSeconds: TimeInterval = 1800 // 30 min, rounded up

    // SHA-256 of the reset password. The plaintext is never stored anywhere
    // in the project. Gates the sensitive period reset only; note that the
    // underlying values live in UserDefaults and a determined machine owner
    // can edit them directly — the authoritative record is the written log
    // (Section 8), not this counter.
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

    /// Remaining overage headroom this week, honoring the weekly 4h cap, the
    /// period 12h cap, and the 16h total-counted-hours weekly ceiling.
    var overageHeadroomSeconds: TimeInterval {
        let weekly = Self.maxOverageSecondsPerWeek - overageSecondsThisWeek
        let period = Self.maxOveragePeriodSeconds - overageSecondsThisPeriod
        let baseUsed = Self.weeklyBaseSeconds - baseRemainingSeconds
        let totalCeiling = Self.maxTotalCountedSecondsPerWeek - baseUsed - overageSecondsThisWeek
        return max(0, min(weekly, min(period, totalCeiling)))
    }

    // MARK: - Weekly reset

    /// If a new week (Sunday) has started, bank this week's overage dollars,
    /// refresh the 10-hour base cap, reset the weekly overage counter and its
    /// tier, and clear the per-week overage approval. Period-level overage
    /// (seconds and banked dollars) is preserved.
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

    /// Total seconds still available to work this week (base + approved
    /// overage headroom).
    var availableSeconds: TimeInterval {
        baseRemainingSeconds + (overageApprovedThisWeek ? overageHeadroomSeconds : 0)
    }

    func setOverageApprovedThisWeek(_ approved: Bool) {
        overageApprovedThisWeek = approved
        forcePersist()
    }

    // MARK: - Manual task session (Section 6 forgiveness)

    struct ManualSessionResult {
        let elapsedSeconds: TimeInterval
        let estimateSeconds: TimeInterval
        let wentOverEstimate: Bool
        let forgivenSeconds: TimeInterval
        let chargedSeconds: TimeInterval
    }

    /// Applies a manually-timed task session, per the Section 6 rule:
    /// within estimate, the full elapsed time is charged; over estimate,
    /// half the overage (rounded to the nearest hour) is forgiven and the
    /// rest is charged. Charged time draws base first, then approved overage.
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

    // MARK: - Period reset (password-gated)

    /// Starts a new 30-day period: clears all overage tracking (seconds and
    /// dollars) and refreshes the base cap. Gated by the reset password so
    /// the client can't zero out overage owed at the machine.
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
