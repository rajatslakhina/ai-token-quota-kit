/// Saturating `Int64` arithmetic.
///
/// Every counter in this module is an explicit `Int64` (tokens, milli-tokens, micro-dollars,
/// milliseconds), so the numbers are identical on every platform, and every operation that could
/// trap — overflow, division by zero, `Int64.min / -1`, `Int64(Double)` — goes through here.
/// Saturation is the right failure mode for a limiter: a counter pinned at `.max` denies, it
/// never wraps to a negative number that would suddenly grant.
public enum Sat {
    @inlinable
    public static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        if !overflow { return result }
        return b > 0 ? .max : .min
    }

    @inlinable
    public static func sub(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.subtractingReportingOverflow(b)
        if !overflow { return result }
        return b > 0 ? .min : .max
    }

    @inlinable
    public static func mul(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        if !overflow { return result }
        return (a < 0) == (b < 0) ? .max : .min
    }

    /// Division that never traps: by zero returns `fallback`; `Int64.min / -1` saturates to `.max`.
    @inlinable
    public static func div(_ a: Int64, _ b: Int64, orIfZero fallback: Int64 = 0) -> Int64 {
        if b == 0 { return fallback }
        let (result, overflow) = a.dividedReportingOverflow(by: b)
        return overflow ? .max : result
    }

    /// Negation that never traps (`-Int64.min` saturates to `.max`).
    @inlinable
    public static func neg(_ a: Int64) -> Int64 { sub(0, a) }

    @inlinable
    public static func clamp(_ value: Int64, _ low: Int64, _ high: Int64) -> Int64 {
        min(max(value, low), high)
    }

    /// `Int64(Double)` without the trap on NaN, ±infinity or out-of-range values
    /// (for example a `Retry-After` header parsed as fractional seconds).
    public static func int64(_ value: Double) -> Int64 {
        if value.isNaN { return 0 }
        // Double(Int64.max) rounds up to exactly 2^63, which is out of range, so `>=` is the correct bound.
        if value >= Double(Int64.max) { return .max }
        if value <= Double(Int64.min) { return .min }
        return Int64(value)
    }
}
