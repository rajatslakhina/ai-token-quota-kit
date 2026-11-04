# TokenQuotaKit

**Your usage dashboard is a day late. Your rate limiter can't be.**

On 29 Oct Anthropic shipped the Usage and Cost Analytics API (beta): usage and cost grouped by model, workspace, API key and actor. Its own docs say the data "typically refreshes within 4 hours of the underlying usage and can take up to 24 hours", and that values can be revised "until about 7 days after the end of the calendar month". That makes it the right tool for *billing* and the wrong one for *enforcement*. If it is the only thing watching your AI features, you find the looping agent or the runaway user a day after they spent the money.

TokenQuotaKit is the other half: a **real-time, per-user token-quota system** for an iOS app's Claude features. It has a metering core for the backend-for-frontend (BFF), a client that knows when *not* to call, and a reconciler that holds the two numbers against each other.

```
 iPhone                              BFF (Linux, Swift)                          Provider
┌─────────────────────┐ authorize ┌─────────────────────────────────────┐ call  ┌──────────┐
│ QuotaClient (actor) │──────────▶│ QuotaGateway (actor) → QuotaLedger  │──────▶│ Messages │
│ • one ID per action │◀─ 429 ────│  reserve → claim (once) → settle    │◀usage─│   API    │
│ • Retry-After gate  │           │ • burst bucket  • daily budget      │       └────┬─────┘
│ • budget pre-check  │           │ • org admission + spend breaker     │            │ ≤24 h
│ • on-device fallback│           │ • outage journal                    │            ▼
└─────────────────────┘           └─────────────────┬───────────────────┘  ┌───────────────────┐
                                                    │ attribution          │ Usage & Cost      │
                                                    └─────────────────────▶│ Analytics API     │
                                                       Reconciler: ledger  │ (late, revisable) │
                                                       vs. report, nightly └───────────────────┘
```

Demo app: (link added when the companion repo is published)

## Why this matters

When an iOS team ships its first Claude feature, someone eventually asks "what stops one user from costing us $400 tonight?" The usual answers each fail in a specific way:

* **A per-request `max_tokens`** bounds one call, not a loop of ten thousand.
* **A client-side counter** is bypassed by anyone with a proxy, and resets when the app is reinstalled.
* **The provider's org-level limits** protect the provider. Once one user is abusive, they throttle *every* user.
* **The analytics dashboard** is authoritative but late, so it can only tell you what already happened.

This is a staff-level system-design problem because the right answer is **two systems on purpose**. One is fast, approximate and enforcing (the ledger). The other is slow, authoritative and billing (the provider's report). A third component is the only place either one gets checked.

## What's in it

| Type | Role |
|---|---|
| `QuotaLedger` | Value-type metering core: **reserve → claim → settle** over a `TokenBucket` (burst), a `DailyUsage` window (sustained) and an `OrgSpendBreaker`. It covers request fingerprints, a single-use claim bound to the request's owner and content, two hold lifetimes with provisional charges, per-key and global in-flight caps, an outage journal with parked refunds, a time-based idempotency window and per-API-key attribution. No I/O, no `await`. |
| `QuotaGateway` | The BFF's actor around the ledger. No method suspends, so each call is one indivisible step. |
| `TokenBucket` | Kept in **milli-tokens**, so refill is exact integer arithmetic (`ms × tokens/s`). A backwards clock step accrues nothing; debt is floored at one bucket; refunds never overfill. |
| `OrgSpendBreaker` | Hourly admission cap, plus a breaker with its own trips (sliding-window velocity, overspend once per window), a cooldown that outlives the hour, and an on-call reset with override headroom. |
| `Reconciler` | Ledger vs. `AnalyticsRow`s, using the report's `data_refreshed_at` watermark. Statuses are `matched`, `awaitingData`, `ledgerOver`, `ledgerUnder` and `unknownKey`, and each finding says whether it is final (month end + 7 days). |
| `QuotaClient` | The app side. One `RequestID` per action across retries (at most 10 attempts), a `Retry-After` gate re-checked after every suspension, jittered backoff, cancellation honoured at every step, a pre-check against the last budget snapshot, and routing to `.cloud`, `.onDevice`, `.tryLater`, `.unavailable` or `.cancelled`. The prompt rides along as an opaque `payload` the library never reads. |
| `Decision`, `Grant`, `Denial`, `ClaimResult`, `AuthorizeRequest` | Public and `Codable`, so an HTTPS `QuotaTransport` is a JSON encode/decode. `DenialReason.httpStatus` maps each reason to 429 / 503 / 409 / 413 / 422. |
| `FaultInjectingTransport` | Scripted `unreachable` / `responseLost` faults, for proving idempotency end to end. |
| `BoundedMap` | Recency-ordered map behind the idempotency window: rewriting a key moves it to the newest end, so time-based purging never stalls and capacity never evicts the freshest entry. |
| `Sat` | Saturating `Int64` arithmetic. No arithmetic reachable through the public API can trap. |
| `TokenQuotaUI` | A portable `ScenarioRunner` (five scripted runs of the real gateway and client on a manual clock) and a SwiftUI `QuotaConsole`. |

## Design decisions (and what I rejected)

**1. Reserve the worst case, settle the actual.** `authorize` debits `count_tokens` input plus `max_tokens` output. `settle` replaces that with the response's `usage`, refunding the difference or charging the overage. When the provider call fails before billing anything, the backend settles `Usage.zero`: the whole reservation is refunded and the request ID is spent.
*Rejected: charge after the call.* A burst of concurrent requests would all pass the check before any of them was charged.

**2. Check everything, then commit.** The daily, burst and org checks all run on copies. Counters and held org spend move only if every check passes, so a denial changes nothing. Tests pin both denial paths, and scripted mutations that leak on denial each fail the suite.
*Rejected: debit as you go and roll back.* Every early return becomes a leak.

**3. A request ID buys at most one reservation, one model call and one charge.**
* The client mints one ID per action and reuses it across retries.
* While the hold is open, a retried `authorize` replays the same grant without a second reservation, but only for the same user, API key, estimate and prompt digest. Anything else is `requestIDReused`.
* Denials are re-evaluated rather than replayed, because a retry after `Retry-After` should succeed.
* The completion handler calls **`claim`** right before calling the model, with the same user, API key and prompt digest it authorised. A claim succeeds at most once per ID. A claim from another session, or for a different prompt, returns `.mismatch`. A settled ID is spent (`alreadySettled`), and a call that outlives its hold keeps its ID spent (`alreadyClaimed`).
* In the `lostResponse` scenario, a lost response, a dead retry, a raced completion and a duplicate settlement end up as **one reservation, one model call and one charge**.

*Rejected: dedupe on the payload.* It would merge a user's two genuine identical requests (`testDedupeIsByRequestIDOnlyNotByPayload`).

**4. Two hold lifetimes, and calls that outlive theirs keep their charge.**
* An **unclaimed** hold means the client never followed through. It is refunded after `holdTTLMs` (2 min).
* A **claimed** hold means a model call is running, possibly streaming. It lives `claimedHoldTTLMs` (15 min) past its claim.
* If it still hasn't settled by then, its reservation becomes a **provisional charge**. For an outage grant, which never touched the counters, the charge is written at that moment. The ID stays spent.
* These expiries live in their own map, with a 24 h retention, so a late settlement trues the provisional charge up (refunding if the call used less) instead of being charged on top of it.

**5. Fail toward counting.**
* Late and unknown settlements are charged, never dropped.
* While the counter store is down, settlements go to a journal that is replayed in order on recovery.
* Refunds are writes too. Instead of entering the journal, they are **parked**, and the abandoned hold's slots are freed immediately, so stale pre-outage holds can't lock a fail-open tier out of its own outage allowance. Parked refunds can't overflow: only holds created while the store was up debit it, so there are never more than the holds open when the outage began.
* The journal's one loss path is overflow. The settle returns `persistence: .dropped`, the tokens are counted in `LedgerStats.journalDroppedTokens`, and reconciliation shows them as `ledgerUnder`. A dropped *provisional* charge isn't usage, so reconciliation can't see it; it has its own counter, `journalDroppedChargeTokens`.

**6. Fail-open vs. fail-closed is a per-tier product decision.**
* Free tiers fail **closed**, because an outage must not become free inference.
* Paid tiers fail **open, bounded**: each key gets an allowance per outage. The grant is marked `degraded` and never feeds the client's budget pre-check. An unused degraded hold returns its allowance only to the outage it came from. A request bigger than the whole allowance is refused permanently (`exceedsOutageAllowance`), so clients don't retry it for the length of the outage.
* The allowance is independent of the daily counter, which can't be read. A user who was already at their limit gets at most one allowance more **per outage, per backend replica**. A flapping store grants one per flap.

*Rejected: one global policy.* Fail-closed everywhere turns a Redis failover into a paid-customer incident. Fail-open everywhere turns it into a spend incident.

**7. Admission keeps spend under the cap; the breaker responds to the incident.**
* **Admission:** `spent + held + estimate ≤ cap` keeps spend under the hourly cap, as long as estimates are honest. When only in-flight holds block a request, the `Retry-After` is 5 s, not "next hour".
* **Velocity trip:** a sliding-window estimate of spend over the last 5 minutes crossing a threshold opens the breaker *below* the cap. A spike can't hide by straddling a window boundary.
* **Overspend trip:** actual spend passing the cap means the estimates lied. It trips once per window and cap, and the overspend is recorded even if the breaker is already open. Raising the cap with an override re-arms it.
* **Reset:** after an on-call `resetBreaker(overrideMicroUSD:)`, the velocity trip stays quiet for one velocity window. Together with the once-per-window overspend rule, this means calls that were already in flight can't reopen the breaker.
* **Duration:** a trip lasts its cooldown even across the hour boundary.
* **Measured in the `orgBreaker` scenario:** with input undercounted by half, the velocity trip fires at **$2.16** after 4 minutes. The hour ends at **$2.70**, because on-call resets the breaker at seat 28. The same traffic against admission alone reaches **$5.04**, past the $5.00 cap.

**8. Fairness before capacity.** Each tier has a per-key in-flight cap (`maxInFlight`, default 8), so one user can't fill the global hold table with 1-token reservations. A key at its cap expires its own stale holds lazily, at O(cap) cost. When the global table is full, `authorize` expires stale holds itself instead of waiting for the next `sweep`, at most once a second because that scan touches every hold.

**9. Overage becomes bounded debt.** A response that used more than it reserved has already happened, so it is charged. The burst bucket can go negative, but never below minus one bucket. Recovering from the floor takes at most `(capacity + request) ÷ rate`: 150 s for a 1,500-token request on the demo's free tier. The daily counter keeps the full overage, because that is the user's real usage.

**10. Integers, not `Double`.** Every token, money and time quantity is a saturating `Int64` (milli-tokens, micro-dollars, milliseconds). A bucket refilled every millisecond gains exactly what one refilled once a minute gains (`testRefillIsExactAtMillisecondGranularity`). A counter pinned at `.max` denies; it never wraps to a negative value and grants. Simple attempt counters are `Int`.

**11. Lag is not drift, but excess always is.**
* **Completeness:** the report's `data_refreshed_at` ("usage after that time is missing or partial") decides which days are complete; 24 h is only the fallback. A *short* report on an incomplete day is `awaitingData`.
* **Excess:** a report *above* the ledger is `ledgerUnder` even on an incomplete day, because lag can only make a report smaller. That asymmetry is how the reconciler finds a share-extension path calling the model directly, the day after it ships.
* **Mapping:** rows map `uncached_input_tokens + output_tokens`. `total_tokens` also counts cache reads and writes, which the ledger doesn't meter.
* **Finality:** a finding becomes final at month end + 7 days, as the docs say.
* **Attribution day:** the docs don't say whether a request counts at its start or its end, so `attributeUsageTo` is a setting (`.callStart` by default).

**12. The idempotency window is time first, capacity second.**
* Finished IDs are remembered for `idempotencyRetentionMs` (1 h), which is longer than any retry or redelivery.
* `idempotencyCapacity` is the memory safety valve. Records past retention are purged before every insert, so capacity only ever evicts IDs that are still inside their window, and each such eviction is counted in `LedgerStats.idempotencyEvictions`.
* Rewriting a record (an expired ID re-authorised and settled) moves it to the newest end.
* Size the capacity at peak finished requests per second × retention.

**Rejected: a sliding-log limiter.** It is exact, but it stores one entry per request per user. A token bucket plus a fixed daily window is O(1) per key.
**Rejected: enforcing on the client.** The client's job is to *avoid wasted calls* (cooldown, pre-check, on-device fallback). Enforcement lives where the API key lives.

## Trust boundary

The backend builds every field of `AuthorizeRequest` except the request ID:

* **`key.userID`** comes from the session.
* **`key.tier`** comes from your entitlement service.
* **`key.feature`** comes from a fixed allowlist (`LedgerConfiguration.features`). Otherwise users multiply their limits by inventing feature names, and the ledger grows without bound.
* **`apiKey`** is the provider's key **ID** (`api_key_id`, e.g. `apikey_…`), so attribution joins the usage report. It is never the secret, which would end up in logs and findings. Per the docs, `api_key_id` grouping applies only to Claude Console organizations; elsewhere, attribute to a dimension your report does have, such as `workspace_id`.
* **`estimate`** comes from the backend's own `count_tokens` call plus the `max_tokens` it will send.
* **`promptDigest`** is the backend's hash of that exact request. `/complete` presents the same digest to `claim`, so a completion can't run a larger prompt than the one that was admitted.

On the device, `QuotaClient` builds the same shape for its local decisions; an HTTPS transport sends only the request ID, the feature and the `payload` (the prompt). `TokenQuotaPublicAPITests` has a transport written exactly that way, with the "backend" deriving everything else.

## Failure modes covered (each one has a test)

| Failure | Behaviour |
|---|---|
| Agent loop hammers one feature | `burstExhausted` + exact `Retry-After`; the client answers the rest of the loop locally with **0 network calls** |
| Response lost after the ledger applied it | Retry with the same ID → replayed grant, no second hold |
| Someone else presents a live or finished request ID | `requestIDReused`; their settlement can't move the owner's charge elsewhere |
| Completion retried, raced, or run by another session or with another prompt | `claim` is single-use and bound to owner + digest: `alreadyClaimed` / `mismatch`, so there is one model call |
| Provider call fails before billing | Settle `Usage.zero`: everything refunded, ID spent |
| Call still running past its claimed TTL | Reservation kept as a provisional charge (written now for an outage grant); the ID stays spent; a late settle up to 24 h later trues it up |
| Client never called the model | The unclaimed hold is refunded after 2 min, by `sweep` or lazily at a cap |
| Settlement delivered twice | `.duplicate`, charged once |
| One user opens hundreds of tiny holds | Per-key in-flight cap; other tenants unaffected |
| Counter store down | Per-tier fail-closed / bounded fail-open per outage; settlements journaled and replayed; refunds parked; abandoned holds release their slots |
| Request bigger than the outage allowance | `exceedsOutageAllowance` (permanent), not a retry loop |
| Journal full | Settlement reported `.dropped`; lost tokens counted; reconciliation shows `ledgerUnder` |
| Estimates far too low | Overspend trip; the velocity trip catches the spike earlier, including across a window boundary |
| On-call reset while calls are in flight | Those calls settling over the cap, or adding up to a velocity spike, don't reopen the breaker |
| Clock steps backwards | No refill, no reopened day, spend window or velocity window, no double refill later |
| Request bigger than the bucket or the day | `requestTooLarge` (413), not a `Retry-After` that can never come true |
| Overflow anywhere (`Int64.max` estimates, `Retry-After: ∞`) | Saturates: denies or caps, never traps |
| A code path bypassing the backend | Reconciliation: `ledgerUnder` / `unknownKey` |
| A retry in flight while another call gets a 429 | The retry re-checks the cooldown after its `await` and stays on the phone |
| Backend unreachable | Jittered exponential backoff, then a feature cooldown, so a loop doesn't hammer a dead backend |
| Task cancelled (before, during the backoff, or as `URLError.cancelled`) | `.cancelled`, with no further attempt |

## Use it

```swift
.package(url: "https://github.com/rajatslakhina/ai-token-quota-kit.git", from: "1.0.0")
```

```swift
// POST /authorize — answer with the Decision as JSON (it's Codable) and the matching status.
let digest = sha256(model, messages, maxTokens)                 // the exact request you counted
let decision = await gateway.authorize(AuthorizeRequest(requestID: id, key: keyFromSession, apiKey: "apikey_01…",
                                                        estimate: Estimate(inputTokens: counted, maxOutputTokens: maxTokens),
                                                        promptDigest: digest))
return .json(decision, status: decision.denial?.reason.httpStatus ?? 200)

// POST /complete — same request ID, same user, same request.
switch await gateway.claim(id, key: keyFromSession, apiKey: "apikey_01…", promptDigest: sha256(model, messages, maxTokens)) {
case .claimed:
    do {
        let response = try await callClaude(model, messages, maxTokens)
        _ = await gateway.settle(id, key: keyFromSession, apiKey: "apikey_01…", usage: response.usage)
        return .ok(response)                                    // and cache it under `id` for retries
    } catch {
        // Settle what was billed: partial usage for a broken stream, .zero for a 5xx/529.
        _ = await gateway.settle(id, key: keyFromSession, apiKey: "apikey_01…", usage: error.partialUsage ?? .zero)
        throw error
    }
case .alreadyClaimed:  return .conflict("in progress")         // 409: poll for the first call's result
case .alreadySettled:  return .ok(cachedResponse(for: id))
case .mismatch:        return .conflict("not your request")
case .noHold:          return .conflict("authorize first")
}

// Every few seconds
await gateway.sweep()

// Nightly: GET /v1/organizations/analytics/usage?group_by[]=api_key_id&time_bucket_width=1d
//          &starting_at=…&ending_at=…   (ending_at is required with a bucket width; at most 31 days per query)
let findings = await gateway.reconcile(report: rows, dataRefreshedAt: refreshedAt)
```

```swift
// App
let client = QuotaClient(transport: MyHTTPSQuotaTransport(), clock: SystemClock())
switch await client.route(key: key, estimate: localEstimate, payload: try JSONEncoder().encode(messages)) {
case .cloud(let grant):        // POST /complete with grant.requestID
case .onDevice:                // Foundation Models
case .tryLater(let until, _):  // "Try again at …"
case .unavailable(let reason): // this request can't be served as is; don't auto-retry
case .cancelled:               break
}
```

## Run the tests

```bash
swift test                    # core, public-API and scenario suites
scripts/mutation-check.sh     # reapplies each deliberate breakage; every one must fail the suite
```

## Verification

* **Linux, Swift 6.0.3** (clean build, `-warnings-as-errors`): build succeeds, **137/137 tests pass** (124 core + 5 public-API + 8 scenario). The scenario engine is portable, so the demo's five scenarios also run on Linux.
* **macOS, Xcode 27.2 / Swift 6.4.2:** 137/137 tests pass, and the package builds for the iOS Simulator as part of the demo app.
* **Public API:** `TokenQuotaPublicAPITests` imports the module *without* `@testable` and implements two `QuotaTransport`s over a JSON wire, the way an app would; one sends only the request ID, the feature and the prompt.
* **Simulator:** see the demo repo. The app was installed and launched on an iPhone 18 Pro Simulator (iOS 27.2) in all five scenarios.
* **CI** ([Actions](../../actions)): (filled in after the first run). The workflow has three jobs: Linux `swift:6.0` (build + tests, warnings as errors), macOS (tests + generic iOS Simulator build), and macOS running the mutation check.

## Mutation results

`scripts/mutation-check.sh` on this tree: **98/98 mutations caught**, on Linux (Swift 6.0.3) and on macOS (Xcode 27.2), exit 0 on both. Each one reapplies a single deliberate breakage that a README claim depends on, and the suite must fail. Every pattern has to occur exactly once, so a mutation can't silently hit the wrong function. They cover:

* **Check-all-then-commit:** denial leaks to the bucket, the daily window and held org spend, plus the daily boundary.
* **Idempotency:** replay, fingerprints for open, finished and mid-call IDs, settled and expired IDs, claim single-use, claim identity on open, finished and mid-call IDs, the duplicate settle, and capacity vs. retention.
* **Lifetimes and provisional charges:** the two hold TTLs, provisional charges for normal and outage grants, refunds below the provisional charge, purge and eviction of mid-call expiries.
* **Outages:** journal replay, parked refunds, slots freed during an outage, allowance per outage, oversized outage requests, and the dropped-entry and dropped-charge counters.
* **Breaker:** velocity (sliding window, quiet period after a reset, history cleared by a reset), overspend once per window and cap even while open, override re-arming, windows that never reopen on a backwards clock, and the cooldown outliving the hour.
* **Bucket and map:** exact refill, the backwards-clock high-water mark, the debt floor, `give` overfill, move-to-newest on rewrite, both compactions, and the capacity clamp.
* **Client:** one ID per action, the cooldown max, the short-circuit, the re-check after `await`, backoff, the cooldown after total failure, every cancellation path, the attempt cap, permanent vs. transient denials, the pre-check freshness and ordering, and degraded grants.
* **Reconciler:** lag vs. drift, excess flagged while data is incomplete, row summing, tolerance side, the `data_refreshed_at` watermark, month-end finality and attribution day.

## Scope and honesty notes

* Prices in the demo ($3 / $15 per million tokens) and all tier limits are illustrative.
* **The ledger is in-process.** In production its counters live in Redis. Per-key state (bucket, daily, holds) maps cleanly to one Lua script per call on one hash slot, but `authorize` also touches org-global state (breaker spend, held cost, the global hold count). In Redis Cluster that means either one hot slot for the org counters, or splitting atomicity into a per-key script plus a separate org reservation that can be rolled back. I have not written that port; the value-type design keeps each transition explicit so it can be ported one at a time.
* **Outage state lives in the backend instance's memory:** the outage allowance, the journal and the parked refunds. With N replicas the effective allowance is up to N times larger, so divide it by the replica count. A journal is lost if its instance restarts mid-outage, so persist it (local disk or a durable queue) in production.
* The velocity estimate is the standard sliding-window-counter approximation: it assumes spend was spread evenly across the previous 5-minute window. In the 5 minutes after an on-call reset the velocity trip is quiet, so a genuinely new spike in that window is caught by admission and the overspend trip, not by velocity.
* Cache read and write tokens are priced separately by the provider and are out of scope, on both the ledger side and the reconciliation side.
* `AnalyticsRow` is the reconciliation-shaped projection of the Usage and Cost Analytics API (key × day × tokens). The HTTP client for that API (beta header `anthropic-beta: analytics-usage-cost-2026-08-24`) is not included.

MIT licensed.
