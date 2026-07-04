/// A small fixed-capacity ring of keyed snapshots, used to make recent undo
/// steps O(1) (restore a saved image) instead of an O(all strokes) re-bake.
///
/// Keys are the active layer's stroke count *before* a commit; on undo the
/// engine looks up the count it wants to return to. Only the most recent
/// `capacity` checkpoints are kept, bounding memory to that many images.
///
/// Pure value type — the ring logic is unit-tested independently of any pixels.
public struct CheckpointRing<Payload> {
    public let capacity: Int
    private var entries: [(key: Int, payload: Payload)] = []

    public init(capacity: Int) {
        self.capacity = max(capacity, 0)
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// Records a checkpoint. Any existing entry with the same or higher key is
    /// dropped first (that history was superseded), then the oldest entries are
    /// evicted to stay within `capacity`.
    public mutating func push(key: Int, _ payload: Payload) {
        guard capacity > 0 else { return }
        entries.removeAll { $0.key >= key }
        entries.append((key, payload))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// Returns and removes the checkpoint for exactly `key` if it is the newest
    /// one, so callers restore only a contiguous, still-valid step. Returns nil
    /// otherwise (caller falls back to a full re-bake).
    public mutating func take(key: Int) -> Payload? {
        guard let last = entries.last, last.key == key else { return nil }
        entries.removeLast()
        return last.payload
    }

    public mutating func invalidate() {
        entries.removeAll(keepingCapacity: true)
    }
}
