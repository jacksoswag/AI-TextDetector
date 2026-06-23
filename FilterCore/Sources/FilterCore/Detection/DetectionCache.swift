import Foundation

/// Content-keyed classifier output for one block. The cache key encodes which
/// detector scored the text, so entries never mix detectors. Calibration is
/// recomputed per evaluation (not cached), keeping the cache valid under the
/// rule: invalidate only on text change.
public struct CachedScores: Sendable {
    public let aiProbability: Double?   // nil = classifier didn't run
    public let uncertainty: Double?

    public init(aiProbability: Double?, uncertainty: Double?) {
        self.aiProbability = aiProbability
        self.uncertainty = uncertainty
    }
}

/// Small thread-safe LRU keyed by content hash. Re-encounters of the same block
/// (scrolling, rescans, window switches) cost a dictionary lookup instead of a
/// model inference — the main battery saver. Get/insert/evict are all O(1) via
/// an intrusive doubly-linked list, so a hit never scans an order array.
public final class DetectionCache: @unchecked Sendable {

    private final class Node {
        let key: String
        var value: CachedScores
        var prev: Node?
        var next: Node?
        init(key: String, value: CachedScores) { self.key = key; self.value = value }
    }

    private let capacity: Int
    private var store: [String: Node] = [:]
    private var head: Node?   // least-recently used
    private var tail: Node?   // most-recently used
    private let lock = NSLock()

    public init(capacity: Int = 1024) {
        self.capacity = max(8, capacity)
    }

    public func scores(for key: String) -> CachedScores? {
        lock.lock(); defer { lock.unlock() }
        guard let node = store[key] else { return nil }
        moveToTail(node)
        return node.value
    }

    public func insert(_ scores: CachedScores, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if let node = store[key] {
            node.value = scores
            moveToTail(node)
            return
        }
        let node = Node(key: key, value: scores)
        store[key] = node
        appendToTail(node)
        if store.count > capacity, let oldest = head {
            unlink(oldest)
            store.removeValue(forKey: oldest.key)
        }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return store.count
    }

    // MARK: - Intrusive list ops (all O(1); caller already holds the lock)

    private func appendToTail(_ node: Node) {
        node.prev = tail
        node.next = nil
        tail?.next = node
        tail = node
        if head == nil { head = node }
    }

    private func unlink(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.prev = nil
        node.next = nil
    }

    private func moveToTail(_ node: Node) {
        guard tail !== node else { return }
        unlink(node)
        appendToTail(node)
    }
}
