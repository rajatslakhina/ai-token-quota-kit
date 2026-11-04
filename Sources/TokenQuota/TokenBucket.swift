/// A token bucket kept in **milli-tokens**, so refill is exact integer arithmetic:
/// `elapsed ms × tokens/s = milli-tokens`. There is no `Double` and no per-refill rounding,
/// so a bucket refilled every millisecond gains exactly what one refilled once a minute gains.
public struct TokenBucket: Sendable, Equatable {
    public let limit: BucketLimit
    public private(set) var levelMilli: Int64
    /// High-water mark of the clock. Never moves backwards, so a clock that steps back and then
    /// forward again cannot refill the same interval twice.
    public private(set) var lastRefillMs: Millis

    public init(limit: BucketLimit, now: Millis) {
        self.limit = limit
        self.levelMilli = Sat.mul(max(0, limit.capacity), 1_000)
        self.lastRefillMs = now
    }

    public var capacityMilli: Int64 { Sat.mul(max(0, limit.capacity), 1_000) }

    /// Settling an overage can push the level negative ("debt"), but never below minus one full
    /// bucket: one bad estimate can lock a user out for at most one refill period of capacity.
    public var floorMilli: Int64 { Sat.neg(capacityMilli) }

    /// Whole tokens available now (truncates toward zero; negative while in debt).
    public var availableTokens: Int64 { Sat.div(levelMilli, 1_000) }

    public var isFull: Bool { levelMilli >= capacityMilli }

    public mutating func refill(now: Millis) {
        let elapsed = Sat.sub(now, lastRefillMs)
        guard elapsed > 0 else { return }   // clock stood still or stepped back: nothing accrues
        let gained = Sat.mul(elapsed, max(0, limit.refillPerSecond))
        levelMilli = min(Sat.add(levelMilli, gained), capacityMilli)
        lastRefillMs = now
    }

    /// Call `refill(now:)` first.
    public func canTake(_ tokens: Int64) -> Bool {
        tokens >= 0 && levelMilli >= Sat.mul(tokens, 1_000)
    }

    public mutating func take(_ tokens: Int64) {
        levelMilli = max(Sat.sub(levelMilli, Sat.mul(max(0, tokens), 1_000)), floorMilli)
    }

    public mutating func give(_ tokens: Int64) {
        levelMilli = min(Sat.add(levelMilli, Sat.mul(max(0, tokens), 1_000)), capacityMilli)
    }

    /// Milliseconds until `tokens` will be available (rounded up), or `nil` if they never will be.
    public func millisUntilAvailable(_ tokens: Int64) -> Millis? {
        let needed = Sat.mul(max(0, tokens), 1_000)
        let deficit = Sat.sub(needed, levelMilli)
        guard deficit > 0 else { return 0 }
        guard limit.refillPerSecond > 0, needed <= capacityMilli else { return nil }
        return Sat.div(Sat.add(deficit, limit.refillPerSecond - 1), limit.refillPerSecond)
    }
}

/// Fixed UTC-day window for the sustained (daily) limit.
public struct DailyUsage: Sendable, Equatable {
    public private(set) var dayIndex: Int64
    public var used: Int64

    public init(dayIndex: Int64, used: Int64 = 0) {
        self.dayIndex = dayIndex
        self.used = used
    }

    /// Starts a new window when the day changes forwards. A clock stepping back never reopens a closed day.
    public mutating func roll(now: Millis) {
        let today = Time.dayIndex(now)
        if today > dayIndex {
            dayIndex = today
            used = 0
        }
    }
}
