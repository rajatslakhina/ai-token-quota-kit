/// One row of the provider's usage report, projected onto what the ledger meters.
///
/// For Anthropic's Usage and Cost Analytics API (`GET /v1/organizations/analytics/usage`, grouped by
/// `api_key_id`, `time_bucket_width=1d`), build it with `init(apiKey:dayIndex:uncachedInputTokens:outputTokens:)`
/// from `uncached_input_tokens` and `output_tokens`. **Do not use `total_tokens`**: it also counts cache
/// reads and cache creation, which the ledger deliberately doesn't meter, so every key that uses prompt
/// caching would look under-metered. Rows for the same key and day (one per model, say) are summed.
public struct AnalyticsRow: Sendable, Equatable {
    public let apiKey: String
    public let dayIndex: Int64
    public let tokens: Int64

    public init(apiKey: String, dayIndex: Int64, tokens: Int64) {
        self.apiKey = apiKey
        self.dayIndex = dayIndex
        self.tokens = tokens
    }

    public init(apiKey: String, dayIndex: Int64, uncachedInputTokens: Int64, outputTokens: Int64) {
        self.init(apiKey: apiKey, dayIndex: dayIndex,
                  tokens: Sat.add(max(0, uncachedInputTokens), max(0, outputTokens)))
    }
}

public struct ReconciliationPolicy: Sendable, Equatable {
    /// Relative tolerance, in basis points of the larger side (200 = 2%).
    public var toleranceBasisPoints: Int64
    /// Used only when the report carries no `data_refreshed_at` watermark: how long after a day ends
    /// its data may still be incomplete ("typically within 4 hours … can take up to 24 hours").
    public var dataLatencyMs: Millis
    /// The provider revises values "until about 7 days after the end of the calendar month".
    public var revisionDaysAfterMonthEnd: Int64

    public init(toleranceBasisPoints: Int64 = 200,
                dataLatencyMs: Millis = 24 * Time.hour,
                revisionDaysAfterMonthEnd: Int64 = 7) {
        self.toleranceBasisPoints = toleranceBasisPoints
        self.dataLatencyMs = dataLatencyMs
        self.revisionDaysAfterMonthEnd = revisionDaysAfterMonthEnd
    }

    /// The instant after which the provider no longer revises `dayIndex`.
    public func finality(of dayIndex: Int64) -> Millis {
        let monthEnd = Time.startOfDay(Time.firstDayOfNextMonth(after: dayIndex))
        return Sat.add(monthEnd, Sat.mul(max(0, revisionDaysAfterMonthEnd), Time.day))
    }
}

public enum DriftStatus: Sendable, Equatable {
    case matched
    /// The report is missing or short, but that day's data is not complete yet.
    case awaitingData
    /// The ledger counted more than the provider billed (e.g. a counted call that never reached it).
    case ledgerOver(Int64)
    /// The provider billed more than the ledger counted: something reached the model without being
    /// metered. Lag can only make a report *smaller*, so this is flagged even while data is incomplete.
    case ledgerUnder(Int64)
    /// Usage on a key/day the ledger has never seen at all — a code path that bypasses the backend.
    case unknownKey(Int64)

    public var needsAttention: Bool {
        switch self {
        case .matched, .awaitingData: return false
        default: return true
        }
    }
}

public struct DriftFinding: Sendable, Equatable {
    public let apiKey: String
    public let dayIndex: Int64
    public let ledgerTokens: Int64
    public let reportedTokens: Int64?
    public let status: DriftStatus
    /// The provider will no longer revise this day, so the finding is settled.
    public let isFinal: Bool
}

/// Compares the enforcement ledger with the provider's billing report.
///
/// They are *deliberately different systems*: the ledger is real-time and approximate (it
/// enforces), the report is late and authoritative (it bills). Reconciliation is how each keeps the
/// other honest — and the only place a metering bypass becomes visible.
public enum Reconciler {
    /// - Parameter dataRefreshedAt: the report's `data_refreshed_at` ("usage after that time is
    ///   missing or partial"). When given, it decides which days are complete; otherwise
    ///   `policy.dataLatencyMs` is used as a conservative stand-in.
    public static func reconcile(ledger: [AttributionKey: Int64],
                                 report: [AnalyticsRow],
                                 dataRefreshedAt: Millis? = nil,
                                 now: Millis,
                                 policy: ReconciliationPolicy = ReconciliationPolicy()) -> [DriftFinding] {
        var reported: [AttributionKey: Int64] = [:]
        for row in report where row.tokens >= 0 {
            let key = AttributionKey(apiKey: row.apiKey, dayIndex: row.dayIndex)
            reported[key] = Sat.add(reported[key] ?? 0, row.tokens)
        }

        let keys = Set(ledger.keys).union(reported.keys).sorted()
        return keys.map { key in
            let ledgerValue = ledger[key].map { max(0, $0) }
            let reportedValue = reported[key]
            let dayEnd = Time.startOfDay(Sat.add(key.dayIndex, 1))
            let incomplete = isIncomplete(dayEnd: dayEnd, dataRefreshedAt: dataRefreshedAt, now: now, policy: policy)
            let status = classify(ledger: ledgerValue, reported: reportedValue, incomplete: incomplete, policy: policy)
            return DriftFinding(apiKey: key.apiKey, dayIndex: key.dayIndex,
                                ledgerTokens: ledgerValue ?? 0, reportedTokens: reportedValue,
                                status: status, isFinal: now >= policy.finality(of: key.dayIndex))
        }
    }

    static func isIncomplete(dayEnd: Millis, dataRefreshedAt: Millis?, now: Millis,
                             policy: ReconciliationPolicy) -> Bool {
        if let dataRefreshedAt { return dataRefreshedAt < dayEnd }
        return now < Sat.add(dayEnd, max(0, policy.dataLatencyMs))
    }

    static func classify(ledger: Int64?, reported: Int64?, incomplete: Bool,
                         policy: ReconciliationPolicy) -> DriftStatus {
        guard let reported else {
            let counted = ledger ?? 0
            if counted == 0 { return .matched }
            return incomplete ? .awaitingData : .ledgerOver(counted)
        }
        guard let ledger else {
            return reported > 0 ? .unknownKey(reported) : .matched
        }
        let diff = Sat.sub(ledger, reported)
        let tolerance = Sat.div(Sat.mul(max(ledger, reported), max(0, policy.toleranceBasisPoints)), 10_000)
        if diff >= Sat.neg(tolerance), diff <= tolerance { return .matched }
        if diff > 0 { return incomplete ? .awaitingData : .ledgerOver(diff) }
        return .ledgerUnder(Sat.neg(diff))
    }
}
