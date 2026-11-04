/// Organisation-level spend control: an admission cap plus a breaker with its own behaviour.
///
/// * **Admission** (`canAdmit`): refuse a reservation if `spent + held + estimate` would pass the
///   window's cap (default: one hour). With honest estimates this alone keeps spend under the cap.
/// * **Velocity trip:** spend over the last `velocityWindowMs` (default: 5 minutes) reaching a
///   threshold opens the breaker *below* the cap. A cap stops the bleeding at the cap; a velocity trip
///   stops it at the incident, while most of the hour's budget is still unspent. The rate is a
///   sliding-window estimate (current window + the previous one, weighted by overlap), so a spike
///   straddling a window boundary is not hidden by the split.
/// * **Overspend trip:** actual spend passing the cap means the estimates lied, so admission can no
///   longer be trusted. It trips **once per spend window and cap** — the overspend is recorded even
///   if the breaker was already open — so after an on-call reset, calls that were already in flight
///   settling over the cap don't reopen it. (Raising the cap with an override re-arms it.)
/// * After a reset the velocity trip stays quiet for one velocity window, for the same reason.
/// * A trip lasts `cooldownMs`, **independent of the spend window**: a trip at 10:58 still refuses at
///   11:01, when admission alone would have started again on a fresh hour. Only `reset` (an on-call
///   decision) closes it early, optionally adding override headroom to this window's cap.
public struct OrgSpendBreaker: Sendable {
    public enum TripReason: String, Sendable, Equatable { case velocity, overspend }

    public let limitMicroUSD: Int64
    public let windowMs: Millis
    public let velocityWindowMs: Millis
    /// `nil` disables the velocity trip.
    public let velocityTripMicroUSD: Int64?
    public let cooldownMs: Millis

    public private(set) var windowIndex: Int64 = 0
    public private(set) var spentMicroUSD: Int64 = 0
    /// Operator headroom for the current window, granted by `reset(overrideMicroUSD:)`.
    public private(set) var overrideMicroUSD: Int64 = 0
    /// Estimated cost of outstanding holds. Not reset with the window: a hold outlives it.
    public private(set) var heldMicroUSD: Int64 = 0
    public private(set) var velocityIndex: Int64 = 0
    public private(set) var velocitySpentMicroUSD: Int64 = 0
    public private(set) var previousVelocitySpentMicroUSD: Int64 = 0
    public private(set) var openUntil: Millis?
    public private(set) var lastTrip: TripReason?
    public private(set) var trips: Int64 = 0
    /// The window and cap of the last overspend trip.
    private var overspendTripped: (window: Int64, limit: Int64)?
    private var velocityQuietUntil: Millis?

    public init(limitMicroUSD: Int64, windowMs: Millis = Time.hour,
                velocityTripMicroUSD: Int64? = nil, velocityWindowMs: Millis = 5 * Time.minute,
                cooldownMs: Millis = 15 * Time.minute) {
        self.limitMicroUSD = max(0, limitMicroUSD)
        self.windowMs = max(1, windowMs)
        self.velocityTripMicroUSD = velocityTripMicroUSD.map { max(0, $0) }
        self.velocityWindowMs = max(1, velocityWindowMs)
        self.cooldownMs = max(0, cooldownMs)
    }

    public var effectiveLimitMicroUSD: Int64 { Sat.add(limitMicroUSD, overrideMicroUSD) }
    public var windowEnd: Millis { Sat.mul(Sat.add(windowIndex, 1), windowMs) }

    public mutating func roll(now: Millis) {
        // A clock stepping back never reopens a window. Note what is *not* reset here: `openUntil`.
        let window = Sat.div(max(0, now), windowMs)
        if window > windowIndex {
            windowIndex = window
            spentMicroUSD = 0
            overrideMicroUSD = 0
        }
        let velocity = Sat.div(max(0, now), velocityWindowMs)
        if velocity > velocityIndex {
            previousVelocitySpentMicroUSD = velocity == Sat.add(velocityIndex, 1) ? velocitySpentMicroUSD : 0
            velocityIndex = velocity
            velocitySpentMicroUSD = 0
        }
    }

    /// Sliding-window estimate of spend over the last `velocityWindowMs`: this window's spend plus
    /// the previous window's, weighted by how much of it still overlaps the trailing window.
    public func velocityEstimate(now: Millis) -> Int64 {
        let windowStart = Sat.mul(velocityIndex, velocityWindowMs)
        let elapsed = Sat.clamp(Sat.sub(now, windowStart), 0, velocityWindowMs)
        let overlap = Sat.sub(velocityWindowMs, elapsed)
        let carried = Sat.div(Sat.mul(previousVelocitySpentMicroUSD, overlap), velocityWindowMs)
        return Sat.add(velocitySpentMicroUSD, carried)
    }

    public func isOpen(now: Millis) -> Bool {
        guard let openUntil else { return false }
        return openUntil > now
    }

    public func canAdmit(_ costMicroUSD: Int64) -> Bool {
        Sat.add(Sat.add(spentMicroUSD, heldMicroUSD), max(0, costMicroUSD)) <= effectiveLimitMicroUSD
    }

    /// True when the request would fit if the in-flight holds weren't there. Holds settle within
    /// seconds, so that denial deserves a short `Retry-After`, not "come back next hour".
    public func blockedOnlyByHolds(_ costMicroUSD: Int64) -> Bool {
        Sat.add(spentMicroUSD, max(0, costMicroUSD)) <= effectiveLimitMicroUSD
    }

    public mutating func hold(_ costMicroUSD: Int64) {
        heldMicroUSD = Sat.add(heldMicroUSD, max(0, costMicroUSD))
    }

    public mutating func release(_ costMicroUSD: Int64) {
        heldMicroUSD = max(0, Sat.sub(heldMicroUSD, max(0, costMicroUSD)))
    }

    public mutating func spend(_ costMicroUSD: Int64, now: Millis) {
        roll(now: now)
        let cost = max(0, costMicroUSD)
        guard cost > 0 else { return }
        spentMicroUSD = Sat.add(spentMicroUSD, cost)
        velocitySpentMicroUSD = Sat.add(velocitySpentMicroUSD, cost)
        // Record an overspend even while the breaker is already open, so the calls still in flight
        // when on-call resets it can't trip it again for the same window and cap.
        let freshOverspend = spentMicroUSD > effectiveLimitMicroUSD && !alreadyTripped(atLimit: effectiveLimitMicroUSD)
        if freshOverspend { overspendTripped = (windowIndex, effectiveLimitMicroUSD) }
        guard !isOpen(now: now) else { return }
        if freshOverspend {
            trip(.overspend, now: now)
        } else if let threshold = velocityTripMicroUSD, !inQuietPeriod(now: now), velocityEstimate(now: now) >= threshold {
            trip(.velocity, now: now)
        }
    }

    private func alreadyTripped(atLimit limit: Int64) -> Bool {
        guard let overspendTripped else { return false }
        return overspendTripped.window == windowIndex && overspendTripped.limit >= limit
    }

    private func inQuietPeriod(now: Millis) -> Bool {
        guard let velocityQuietUntil else { return false }
        return now < velocityQuietUntil
    }

    private mutating func trip(_ reason: TripReason, now: Millis) {
        openUntil = Sat.add(now, cooldownMs)
        lastTrip = reason
        trips = Sat.add(trips, 1)
    }

    /// On-call override: close the breaker, forget the recent velocity, keep the velocity trip quiet
    /// for one velocity window while calls already in flight settle, and optionally add headroom to
    /// this window's cap (for spend a human has decided is legitimate).
    public mutating func reset(overrideMicroUSD extra: Int64 = 0, now: Millis) {
        openUntil = nil
        velocitySpentMicroUSD = 0
        previousVelocitySpentMicroUSD = 0
        velocityQuietUntil = Sat.add(now, velocityWindowMs)
        overrideMicroUSD = Sat.add(overrideMicroUSD, max(0, extra))
    }
}
