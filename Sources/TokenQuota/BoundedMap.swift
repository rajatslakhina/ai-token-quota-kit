/// A recency-ordered map with a hard capacity: beyond it, the least recently written entries are evicted.
///
/// Backs the idempotency window. The ledger expires entries by *time* (`removeOldest(while:)`), and
/// `capacity` is a memory safety valve; an eviction by capacity is counted in `evictions`, so
/// operators can see when the window has become shorter than its retention.
///
/// **Writing an existing key moves it to the newest end.** Otherwise an entry updated with a newer
/// timestamp would sit at the old end: it would stall time-based removal for everything behind it,
/// and be the first thing capacity evicts, although it is the freshest entry in the map.
/// Slots carry a generation number, so the slot an update or removal leaves behind is recognised
/// as stale and skipped, and compaction keeps the ordering array O(count).
public struct BoundedMap<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        var value: Value
        var generation: UInt64
    }

    private struct Slot: Sendable {
        let key: Key
        let generation: UInt64
    }

    public let capacity: Int
    private var storage: [Key: Entry] = [:]
    private var order: [Slot] = []
    private var head = 0
    private var nextGeneration: UInt64 = 0
    /// Entries removed by capacity (not by time, and not by `removeValue`).
    public private(set) var evictions: Int64 = 0

    /// The largest capacity accepted: keeps every size computation (`2 × capacity + 16`) far from
    /// `Int.max`, on 32-bit platforms too.
    public static var maxCapacity: Int { Int.max / 4 }

    public init(capacity: Int) { self.capacity = min(max(1, capacity), Self.maxCapacity) }

    public var count: Int { storage.count }

    public subscript(key: Key) -> Value? { storage[key]?.value }

    /// Physical size of the ordering array: what bounded memory actually means here.
    var storageFootprint: Int { order.count }

    /// Inserts or overwrites `key`, making it the newest entry.
    public mutating func insert(_ value: Value, for key: Key) {
        nextGeneration &+= 1   // wrapping: only equality with a live entry's generation matters
        storage[key] = Entry(value: value, generation: nextGeneration)
        order.append(Slot(key: key, generation: nextGeneration))
        while storage.count > capacity, let oldest = popOldestLiveKey() {
            storage.removeValue(forKey: oldest)
            evictions = Sat.add(evictions, 1)
        }
        compactIfNeeded()
    }

    @discardableResult
    public mutating func removeValue(forKey key: Key) -> Value? {
        let removed = storage.removeValue(forKey: key)?.value
        compactIfNeeded()
        return removed
    }

    /// Removes entries from the oldest end while `shouldRemove` is true; stops at the first one it keeps.
    public mutating func removeOldest(while shouldRemove: (Key, Value) -> Bool) {
        while head < order.count {
            let slot = order[head]
            guard let entry = storage[slot.key], entry.generation == slot.generation else {
                head += 1   // stale slot: the key was rewritten later or removed
                continue
            }
            guard shouldRemove(slot.key, entry.value) else { break }
            storage.removeValue(forKey: slot.key)
            head += 1
        }
        compactIfNeeded()
    }

    private mutating func popOldestLiveKey() -> Key? {
        while head < order.count {
            let slot = order[head]
            head += 1
            if let entry = storage[slot.key], entry.generation == slot.generation { return slot.key }
        }
        return nil
    }

    /// Drops consumed and stale slots so `order` stays O(count + capacity): amortised O(1) per call.
    private mutating func compactIfNeeded() {
        if head > 0, head > capacity || head == order.count {
            order.removeFirst(min(head, order.count))
            head = 0
        }
        if order.count > 2 * max(storage.count, capacity) + 16 {
            order = order.filter { slot in storage[slot.key]?.generation == slot.generation }
            head = 0
        }
    }
}
