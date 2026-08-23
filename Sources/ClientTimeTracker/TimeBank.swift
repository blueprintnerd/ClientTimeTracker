import Foundation
import CryptoKit

/// Tracks the weekly time allotment, purchased extra hours, and the
/// lifetime dollar total accrued from purchases.
final class TimeBank {

    static let weeklyBaseSeconds: TimeInterval = 10 * 3600
    static let extraHourSeconds: TimeInterval = 3600
    static let extraHourPriceDollars: Double = 1.0

    // SHA-256 of the clear-total password. The plaintext password is never
    // stored in this file or anywhere else in the project.
    private static let clearPasswordHash =
        "3c852a6e70d1e927d673d47ddd10993e7376c947eebfeda8fdd523a5ee92c692"

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let remainingSeconds = "remainingSeconds"
        static let extraHoursThisWeek = "extraHoursThisWeek"
        static let lifetimeDollars = "lifetimeDollars"
        static let lastResetWeekStart = "lastResetWeekStart"
    }

    private(set) var remainingSeconds: TimeInterval
    private(set) var extraHoursThisWeek: Int
    private(set) var lifetimeDollars: Double
    private var lastResetWeekStart: Date

    init() {
        if defaults.object(forKey: Keys.remainingSeconds) == nil {
            // First launch: seed a fresh week.
            remainingSeconds = Self.weeklyBaseSeconds
            extraHoursThisWeek = 0
            lifetimeDollars = 0
            lastResetWeekStart = Self.mostRecentSunday()
            persist()
        } else {
            remainingSeconds = defaults.double(forKey: Keys.remainingSeconds)
            extraHoursThisWeek = defaults.integer(forKey: Keys.extraHoursThisWeek)
            lifetimeDollars = defaults.double(forKey: Keys.lifetimeDollars)
            let stored = defaults.double(forKey: Keys.lastResetWeekStart)
            lastResetWeekStart = stored > 0 ? Date(timeIntervalSince1970: stored) : Self.mostRecentSunday()
        }
        applyWeeklyResetIfNeeded()
    }

    /// The most recent Sunday at 00:00 local time, relative to `date`.
    static func mostRecentSunday(from date: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1 // Sunday
        calendar.timeZone = .current
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    /// Call periodically (e.g. every tick). If a new week (Sunday) has
    /// started since the last reset, the hour bank refreshes back to the
    /// base 10 hours and this week's purchased-hour counter clears.
    /// The lifetime dollar total is untouched — it only clears via
    /// `clearLifetimeTotal(password:)`.
    @discardableResult
    func applyWeeklyResetIfNeeded(now: Date = Date()) -> Bool {
        let currentWeekStart = Self.mostRecentSunday(from: now)
        guard currentWeekStart > lastResetWeekStart else { return false }
        remainingSeconds = Self.weeklyBaseSeconds
        extraHoursThisWeek = 0
        lastResetWeekStart = currentWeekStart
        persist()
        return true
    }

    /// Consume one second from the bank. No-op once the bank hits zero.
    func consumeSecond() {
        guard remainingSeconds > 0 else { return }
        remainingSeconds = max(0, remainingSeconds - 1)
        persist()
    }

    func addPurchasedHour() {
        remainingSeconds += Self.extraHourSeconds
        extraHoursThisWeek += 1
        lifetimeDollars += Self.extraHourPriceDollars
        persist()
    }

    /// Clears the lifetime dollar total only if the password matches.
    /// Returns true on success.
    @discardableResult
    func clearLifetimeTotal(password: String) -> Bool {
        let hash = SHA256.hash(data: Data(password.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        guard hex == Self.clearPasswordHash else { return false }
        lifetimeDollars = 0
        persist()
        return true
    }

    private func persist() {
        defaults.set(remainingSeconds, forKey: Keys.remainingSeconds)
        defaults.set(extraHoursThisWeek, forKey: Keys.extraHoursThisWeek)
        defaults.set(lifetimeDollars, forKey: Keys.lifetimeDollars)
        defaults.set(lastResetWeekStart.timeIntervalSince1970, forKey: Keys.lastResetWeekStart)
    }
}
