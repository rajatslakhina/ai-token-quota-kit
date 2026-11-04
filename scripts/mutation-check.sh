#!/usr/bin/env bash
# Re-applies deliberate breakages, one at a time, to a scratch copy of the package and asserts the
# test suite FAILS for each. A mutation that survives means a README claim has no test behind it.
#
# Every pattern must occur exactly once in its file, so a mutation can never silently hit the wrong
# function. The scratch copy is built once; each mutation rebuilds incrementally and is then reverted.
#
# Usage: scripts/mutation-check.sh            (needs swift + python3; leaves the working tree untouched)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R "$ROOT/Package.swift" "$ROOT/Sources" "$ROOT/Tests" "$WORK/"
(cd "$WORK" && swift build --build-tests >/dev/null 2>&1) || { echo "baseline does not build"; exit 1; }
(cd "$WORK" && swift test --skip-build >/dev/null 2>&1) || { echo "baseline tests fail"; exit 1; }

status=0; caught=0; total=0
L=Sources/TokenQuota/QuotaLedger.swift
C=Sources/TokenQuota/QuotaClient.swift
R=Sources/TokenQuota/Reconciler.swift
B=Sources/TokenQuota/TokenBucket.swift
O=Sources/TokenQuota/OrgSpendBreaker.swift
M=Sources/TokenQuota/BoundedMap.swift

mutate() { # name file from to
  total=$((total + 1))
  local file="$WORK/$2"
  cp "$file" "$file.orig"
  if ! python3 - "$file" "$3" "$4" <<'PY'
import sys
p, f, t = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
n = s.count(f)
if n != 1:
    sys.exit(f"pattern occurs {n} times in {p} (must be exactly once)")
open(p, "w").write(s.replace(f, t, 1))
PY
  then
    echo "STALE:    $1  (pattern must occur exactly once — update the mutation)"; status=1
  elif ! (cd "$WORK" && swift build --build-tests >/dev/null 2>&1); then
    echo "BROKEN:   $1  (mutation does not compile — fix the mutation, it proves nothing)"; status=1
  elif (cd "$WORK" && swift test --skip-build >/dev/null 2>&1); then
    echo "SURVIVED: $1  (tests still pass with the breakage — coverage gap)"; status=1
  else
    echo "caught:   $1"; caught=$((caught + 1))
  fi
  mv "$file.orig" "$file"
  touch "$file"
}

mutate "burst denial leaks the daily reservation" $L "            return deny(.burstExhausted, retryAfter: bucket.millisUntilAvailable(estimate.total))" "            daily[key] = DailyUsage(dayIndex: day.dayIndex, used: Sat.add(day.used, estimate.total))
            return deny(.burstExhausted, retryAfter: bucket.millisUntilAvailable(estimate.total))"
mutate "daily denial debits the burst" $L "            return deny(.dailyBudgetExhausted," "            buckets[key] = { var b = buckets[key] ?? TokenBucket(limit: policy.burst, now: now); b.refill(now: now); b.take(estimate.total); return b }()
            return deny(.dailyBudgetExhausted,"
mutate "denial holds org spend" $L "        guard storeAvailable else {
            return authorizeDuringOutage" "        breaker.hold(cost)
        guard storeAvailable else {
            return authorizeDuringOutage"
mutate "daily budget boundary off by one" $L "guard Sat.add(day.used, estimate.total) <= policy.dailyBudget else {" "guard Sat.add(day.used, estimate.total) < policy.dailyBudget else {"
mutate "hold replay removed (retry re-reserves)" $L "        if let hold = holds[id] {
            guard hold.matches" "        if false, let hold = holds[id] {
            guard hold.matches"
mutate "replay ignores who is asking" $L "            guard hold.matches(key: key, apiKey: apiKey, estimate: estimate, promptDigest: promptDigest) else {
                return rejectReuse()
            }
            counters.replays" "            counters.replays"
mutate "finished ID ignores who is asking" $L "            guard record.matches(key: key, apiKey: apiKey, estimate: estimate, promptDigest: promptDigest) else {
                return rejectReuse()
            }
            switch record.terminal {" "            switch record.terminal {"
mutate "settled ID re-granted" $L "            case .settled:
                // The ID is spent. Re-granting it could let a retry call the model again for free.
                return deny(.alreadySettled, retryAfter: nil)" "            case .settled:
                break"
mutate "expired ID replayed without a reservation" $L "            case .expiredUnclaimed:
                break   // the hold lapsed unused" "            case .expiredUnclaimed:
                if let grant = record.grant { return .granted(grant) }   // the hold lapsed unused"
mutate "unknown features accepted" $L "if let features = configuration.features, !features.contains(key.feature) {" "if false, let features = configuration.features, !features.contains(key.feature) {"
mutate "no per-key in-flight cap" $L "if inFlight(for: key) >= max(1, policy.maxInFlight) {" "if false, inFlight(for: key) >= max(1, policy.maxInFlight) {"
mutate "per-key cap doesn't expire its own stale holds" $L "            expireHolds(Array(holdIDs[key] ?? []), now: now)   // lazy, and O(maxInFlight)
" ""
mutate "no lazy expiry at the global cap" $L "                lastGlobalExpiryMs = now
                expireHolds(Array(holds.keys), now: now)" "                lastGlobalExpiryMs = now"
mutate "empty in-flight entries never removed" $L "        if holdIDs[hold.key]?.isEmpty == true { holdIDs[hold.key] = nil }
" ""
mutate "hold-driven org denial cools clients for the hour" $L "let retry = breaker.blockedOnlyByHolds(cost) ? 5 * Time.second : max(0, Sat.sub(breaker.windowEnd, now))" "let retry = max(0, Sat.sub(breaker.windowEnd, now))"
mutate "org admission check removed" $L "guard breaker.canAdmit(cost) else {" "guard true else {"
mutate "open breaker ignored" $L "if breaker.isOpen(now: now), let openUntil = breaker.openUntil {" "if false, let openUntil = breaker.openUntil {"
mutate "claim is not single-use" $L "guard hold.claimedAtMs == nil else {" "guard true else {"
mutate "claim ignores who is claiming and what" $L "        if var hold = holds[id] {
            guard hold.matchesClaim(key: key, apiKey: apiKey, promptDigest: promptDigest) else {" "        if var hold = holds[id] {
            guard true else {"
mutate "claimed hold refunded at expiry (second claim possible)" $L "            if hold.claimedAtMs != nil {
                expireMidCall(id, hold, now: now)" "            if false, hold.claimedAtMs != nil {
                expireMidCall(id, hold, now: now)"
mutate "claimed hold uses the idle TTL" $L "if let claimedAtMs { return Sat.add(claimedAtMs, configuration.claimedHoldTTLMs) }" "if claimedAtMs != nil { return Sat.add(createdMs, configuration.holdTTLMs) }"
mutate "outage grant's mid-call charge never written" $L "            if apply(charge, now: now) == .dropped { provisionalTokens = 0 }" "            _ = charge"
mutate "mid-call expiry forgotten with the idempotency window" $L "        let retention = max(0, configuration.provisionalRetentionMs)" "        let retention = max(0, configuration.idempotencyRetentionMs)"
mutate "late settle below the provisional charge never refunds" $L "            let adjust = Sat.sub(actual, parked.provisionalTokens)" "            let adjust = max(0, Sat.sub(actual, parked.provisionalTokens))"
mutate "expired hold keeps its held org spend" $L "            breaker.release(hold.estimatedCost)
            counters.expiredHolds" "            counters.expiredHolds"
mutate "settled hold keeps its held org spend" $L "        if let hold = removeHold(id) {
            breaker.release(hold.estimatedCost)" "        if let hold = removeHold(id) {"
mutate "outage grant holds no org spend" $L "            breaker.hold(cost)
            let grant = Grant(requestID: id, reservedTokens: estimate.total, burstRemaining: 0," "            let grant = Grant(requestID: id, reservedTokens: estimate.total, burstRemaining: 0,"
mutate "duplicate settle charged again" $L "        if let record, record.terminal == .settled {" "        if false, let record, record.terminal == .settled {"
mutate "expired hold not refunded" $L "counterAdjust: Sat.neg(hold.grant.reservedTokens)," "counterAdjust: 0,"
mutate "late/unknown settle not charged" $L "                                      counterAdjust: actual, attributionDay: attributionDay, attributedTokens: actual)" "                                      counterAdjust: 0, attributionDay: attributionDay, attributedTokens: actual)"
mutate "late settle charged to the caller, not the owner" $L "let fullCharge = JournalEntry(key: record?.key ?? key, apiKey: record?.apiKey ?? apiKey, windowDay: today," "let fullCharge = JournalEntry(key: key, apiKey: apiKey, windowDay: today,"
mutate "closed-day adjustment applied to today" $L "if day.dayIndex == entry.windowDay {" "if true {"
mutate "attribution ignores the call-start setting" $L "case .callStart: attributionInstant = hold.startedAtMs" "case .callStart: attributionInstant = now"
mutate "expired-unclaimed late settle attributed to the settle day" $L "case .callStart: attributionDay = Time.dayIndex(record?.startedAtMs ?? now)" "case .callStart: attributionDay = today"
mutate "records never expire by time" $L "        expireHolds(Array(holds.keys), now: now)
        purgeRecords(now: now)
" "        expireHolds(Array(holds.keys), now: now)
"
mutate "capacity evicts records already past retention" $L "        purgeRecords(now: now)
        records.insert(record, for: id)" "        records.insert(record, for: id)"
mutate "journal not replayed on recovery" $L "for entry in pending { commit(entry, now: now) }" ""
mutate "parked refunds never applied" $L "for refund in refunds { commit(refund, now: now) }" ""
mutate "outage path ignored" $L "        guard storeAvailable else {
            return authorizeDuringOutage" "        guard storeAvailable || true else {
            return authorizeDuringOutage"
mutate "outage allowance unchecked" $L "guard after <= allowance else" "guard true else"
mutate "oversized outage request retried forever" $L "            guard estimate.total <= allowance else { return deny(.exceedsOutageAllowance, retryAfter: nil) }
" ""
mutate "dropped entry reported as journaled" $L "                return .dropped" "                return .journaled"
mutate "dropped tokens not counted" $L "                counters.journalDroppedTokens = Sat.add(counters.journalDroppedTokens, max(0, entry.attributedTokens))
" ""
mutate "refunds enter the journal during an outage" $L "            if storeAvailable {
                _ = apply(refund, now: now)
            } else {" "            if true {
                _ = apply(refund, now: now)
            } else {"
mutate "abandoned holds keep their slots during an outage" $L "        for id in due {
            guard let hold = removeHold(id) else { continue }" "        for id in due {
            if !storeAvailable, holds[id]?.debitedCounters == true, holds[id]?.claimedAtMs == nil { continue }
            guard let hold = removeHold(id) else { continue }"
mutate "outage refund crosses outages" $L "if !storeAvailable, hold.outageEpoch == outageEpoch, let used = outageUsed[hold.key] {" "if !storeAvailable, let used = outageUsed[hold.key] {"
mutate "velocity trip never fires" $O "} else if let threshold = velocityTripMicroUSD, !inQuietPeriod(now: now), velocityEstimate(now: now) >= threshold {" "} else if false, let threshold = velocityTripMicroUSD, !inQuietPeriod(now: now), velocityEstimate(now: now) >= threshold {"
mutate "velocity ignores the previous window" $O "        return Sat.add(velocitySpentMicroUSD, carried)" "        return velocitySpentMicroUSD"
mutate "trip cleared by the window rollover" $O "            spentMicroUSD = 0
            overrideMicroUSD = 0" "            spentMicroUSD = 0
            overrideMicroUSD = 0
            openUntil = nil"
mutate "reset grants no override" $O "        overrideMicroUSD = Sat.add(overrideMicroUSD, max(0, extra))
" ""
mutate "spending exactly the cap counts as overspend" $O "let freshOverspend = spentMicroUSD > effectiveLimitMicroUSD &&" "let freshOverspend = spentMicroUSD >= effectiveLimitMicroUSD &&"
mutate "overspend re-trips after an on-call reset" $O " && !alreadyTripped(atLimit: effectiveLimitMicroUSD)" ""
mutate "backwards clock reopens the spend window" $O "if window > windowIndex {" "if window != windowIndex {"
mutate "backwards clock reopens the velocity window" $O "if velocity > velocityIndex {" "if velocity != velocityIndex {"
mutate "refill rounded to whole tokens" $B "let gained = Sat.mul(elapsed, max(0, limit.refillPerSecond))" "let gained = Sat.mul(Sat.div(Sat.mul(elapsed, max(0, limit.refillPerSecond)), 1_000), 1_000)"
mutate "backwards clock moves the high-water mark" $B "guard elapsed > 0 else { return }" "guard elapsed != 0 else { return }"
mutate "debt floor removed" $B "levelMilli = max(Sat.sub(levelMilli, Sat.mul(max(0, tokens), 1_000)), floorMilli)" "levelMilli = Sat.sub(levelMilli, Sat.mul(max(0, tokens), 1_000))"
mutate "give overfills the bucket" $B "levelMilli = min(Sat.add(levelMilli, Sat.mul(max(0, tokens), 1_000)), capacityMilli)" "levelMilli = Sat.add(levelMilli, Sat.mul(max(0, tokens), 1_000))"
mutate "rewritten key keeps its old slot" $M "        storage[key] = Entry(value: value, generation: nextGeneration)
        order.append(Slot(key: key, generation: nextGeneration))" "        if var existing = storage[key] { existing.value = value; storage[key] = existing; return }
        storage[key] = Entry(value: value, generation: nextGeneration)
        order.append(Slot(key: key, generation: nextGeneration))"
mutate "BoundedMap never compacts consumed slots" $M "            order.removeFirst(min(head, order.count))
            head = 0" ""
mutate "BoundedMap never compacts stale slots" $M "            order = order.filter { slot in storage[slot.key]?.generation == slot.generation }
            head = 0" ""
mutate "client mints an ID per attempt" $C "decision = try await transport.authorize(request)" "decision = try await transport.authorize(AuthorizeRequest(requestID: makeRequestID(), key: key, apiKey: apiKey, estimate: estimate))"
mutate "concurrent route clobbers a later cooldown" $C "let deadline = max(cooldownUntil[feature] ?? Millis.min, until)" "let deadline = until"
mutate "cooldown short-circuit removed" $C "        if let until = cooldownUntil[key.feature], until > now {" "        if false, let until = cooldownUntil[key.feature], until > now {"
mutate "retry ignores a cooldown set meanwhile" $C "                if let until = cooldownUntil[key.feature], until > clock.nowMillis() {" "                if false, let until = cooldownUntil[key.feature], until > clock.nowMillis() {"
mutate "no backoff between retries" $C "                await sleep(backoffDelay(forRetry: attempt))
" ""
mutate "total transport failure sets no cooldown" $C "        let failedUntil = extendCooldown(for: key.feature, to: Sat.add(clock.nowMillis(), policy.defaultCooldownMs))" "        let failedUntil = Sat.add(clock.nowMillis(), policy.defaultCooldownMs)"
mutate "cancellation swallowed" $C "            } catch is CancellationError {
                return .cancelled" "            } catch is CancellationError {
                continue"
mutate "cancellation during backoff ignored" $C "                if Task.isCancelled { return .cancelled }
                // Other routes ran" "                // Other routes ran"
mutate "cancellation reported as another error is retried" $C "                if Task.isCancelled { return .cancelled }
                continue" "                continue"
mutate "cancelled task still calls the network" $C "        if Task.isCancelled { return .cancelled }
        let now = clock.nowMillis()" "        let now = clock.nowMillis()"
mutate "permanent denial cools the feature down" $C "guard denial.reason.isTransient else { return .unavailable(denial.reason) }" "guard true else { return .unavailable(denial.reason) }"
mutate "degraded grant feeds the pre-check" $C "guard !grant.degraded else { return }" ""
mutate "snapshot freshness ignored" $C "Sat.sub(now, snapshot.observedAtMs) <= policy.snapshotFreshnessMs," "true,"
mutate "older snapshot overwrites a newer one" $C "if let existing = budget[key], existing.observedAtMs > instant { return }" ""
mutate "lag reported as drift" $R "if diff > 0 { return incomplete ? .awaitingData : .ledgerOver(diff) }" "if diff > 0 { return .ledgerOver(diff) }"
mutate "unmetered usage excused as lag" $R "return .ledgerUnder(Sat.neg(diff))" "return incomplete ? .awaitingData : .ledgerUnder(Sat.neg(diff))"
mutate "per-model rows not summed" $R "reported[key] = Sat.add(reported[key] ?? 0, row.tokens)" "reported[key] = row.tokens"
mutate "tolerance taken from the smaller side" $R "Sat.mul(max(ledger, reported), max(0, policy.toleranceBasisPoints))" "Sat.mul(min(ledger, reported), max(0, policy.toleranceBasisPoints))"
mutate "data_refreshed_at watermark ignored" $R "        if let dataRefreshedAt { return dataRefreshedAt < dayEnd }
" ""
mutate "finality as a fixed 31 days" $R "        let monthEnd = Time.startOfDay(Time.firstDayOfNextMonth(after: dayIndex))" "        let monthEnd = Time.startOfDay(Sat.add(dayIndex, 31))"
mutate "overspend while already open is not recorded" $O "        if freshOverspend { overspendTripped = (windowIndex, effectiveLimitMicroUSD) }
        guard !isOpen(now: now) else { return }" "        guard !isOpen(now: now) else { return }
        if freshOverspend { overspendTripped = (windowIndex, effectiveLimitMicroUSD) }"
mutate "no velocity quiet period after a reset" $O ", !inQuietPeriod(now: now)," ","
mutate "reset keeps the velocity history" $O "        velocitySpentMicroUSD = 0
        previousVelocitySpentMicroUSD = 0
        velocityQuietUntil" "        velocityQuietUntil"
mutate "raising the cap doesn't re-arm the overspend trip" $O "return overspendTripped.window == windowIndex && overspendTripped.limit >= limit" "return overspendTripped.window == windowIndex"
mutate "BoundedMap capacity unclamped" $M "self.capacity = min(max(1, capacity), Self.maxCapacity)" "self.capacity = max(1, capacity)"
mutate "claim on a finished ID ignores the request" $L "              record.estimate == nil || record.promptDigest == promptDigest else {" "              true else {"
mutate "claim on a finished ID ignores the owner" $L "        guard record.key == key, record.apiKey == apiKey,
              record.estimate" "        guard true,
              record.estimate"
mutate "mid-call expiry ignores who is authorizing" $L "        if let parked = provisional[id] {
            guard parked.hold.matches(key: key, apiKey: apiKey, estimate: estimate, promptDigest: promptDigest) else {
                return rejectReuse()
            }" "        if let parked = provisional[id] {
            _ = parked"
mutate "mid-call expiry ignores who is claiming" $L "            guard parked.hold.matchesClaim(key: key, apiKey: apiKey, promptDigest: promptDigest) else {" "            guard true else {"
mutate "claim on an expired-unclaimed ID isn't noHold" $L "        case .expiredUnclaimed: return .noHold" "        case .expiredUnclaimed: return .alreadySettled"
mutate "refund ignores the debited window day" $L "let refund = JournalEntry(key: hold.key, apiKey: hold.apiKey, windowDay: hold.windowDay," "let refund = JournalEntry(key: hold.key, apiKey: hold.apiKey, windowDay: Time.dayIndex(hold.createdMs),"
mutate "global lazy expiry not rate-limited" $L "if lastGlobalExpiryMs.map({ Sat.sub(now, \$0) >= Time.second }) ?? true {" "if true {"
mutate "sweep never purges mid-call expiries" $L "        purgeRecords(now: now)
        purgeProvisional(now: now)" "        purgeRecords(now: now)"
mutate "provisional evictions not reported" $L "        snapshot.provisionalEvictions = provisional.evictions
" ""
mutate "settlement attribution ignored on late settles" $L "        case .settlement: attributionDay = today" "        case .settlement: attributionDay = Time.dayIndex(record?.startedAtMs ?? now)"
mutate "dropped provisional charge not counted" $L "                    counters.journalDroppedChargeTokens = Sat.add(counters.journalDroppedChargeTokens, entry.counterAdjust)
" ""
mutate "attempts not capped" $C "let attempts = min(max(1, policy.maxAttempts), 10)" "let attempts = max(1, policy.maxAttempts)"
echo "$caught/$total mutations caught"
exit $status
