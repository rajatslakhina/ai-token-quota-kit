import Foundation

/// Milliseconds since the Unix epoch (wall clock). Daily budgets need a wall clock (UTC days);
/// token buckets treat a backwards jump as "no time passed" instead of needing a monotonic one.
public typealias Millis = Int64

public enum Time {
    public static let second: Millis = 1_000
    public static let minute: Millis = 60_000
    public static let hour: Millis = 3_600_000
    public static let day: Millis = 86_400_000

    /// UTC day index of an instant. Instants before the epoch clamp to day 0.
    public static func dayIndex(_ instant: Millis) -> Int64 { Sat.div(max(0, instant), day) }

    /// First millisecond of a UTC day index.
    public static func startOfDay(_ index: Int64) -> Millis { Sat.mul(max(0, index), day) }

    /// The largest day index the calendar helpers accept (~2.7 million years): clamping to it
    /// keeps every intermediate step of the civil-date arithmetic far from overflow.
    public static let maxCalendarDay: Int64 = 1_000_000_000

    /// Proleptic-Gregorian (year, month, day) of a UTC day index — Howard Hinnant's
    /// `civil_from_days`. Out-of-range indices are clamped to `0...maxCalendarDay`.
    public static func civil(dayIndex: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let z = Sat.clamp(dayIndex, 0, maxCalendarDay) + 719_468
        let era = z / 146_097                     // z ≥ 0, so no negative-division correction
        let dayOfEra = z - era * 146_097          // 0...146_096
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153   // 0...11, March-based
        let dayOfMonth = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, dayOfMonth)
    }

    public static func daysInMonth(year: Int64, month: Int64) -> Int64 {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    /// Day index of the first day of the month after the one containing `dayIndex`.
    public static func firstDayOfNextMonth(after dayIndex: Int64) -> Int64 {
        let clamped = Sat.clamp(dayIndex, 0, maxCalendarDay)
        let date = civil(dayIndex: clamped)
        return clamped - (date.day - 1) + daysInMonth(year: date.year, month: date.month)
    }
}

public protocol QuotaClock: Sendable {
    func nowMillis() -> Millis
}

public struct SystemClock: QuotaClock {
    public init() {}
    public func nowMillis() -> Millis { Sat.int64(Date().timeIntervalSince1970 * 1_000) }
}

/// A clock tests and the demo's scenarios drive by hand, so every number they show is reproducible.
public final class ManualClock: QuotaClock, @unchecked Sendable {
    // @unchecked Sendable: the only mutable state, `now`, is read and written under `lock`.
    private let lock = NSLock()
    private var now: Millis

    public init(startingAt start: Millis = 0) { now = start }

    public func nowMillis() -> Millis {
        lock.lock(); defer { lock.unlock() }
        return now
    }

    /// Moves forward. Negative amounts are ignored; use `set(_:)` to model a clock stepping back.
    public func advance(by milliseconds: Millis) {
        lock.lock(); defer { lock.unlock() }
        now = Sat.add(now, max(0, milliseconds))
    }

    public func set(_ instant: Millis) {
        lock.lock(); defer { lock.unlock() }
        now = instant
    }
}
