import Foundation

/// Content-keyed scores from Layers 1 and 2. Layer 3 (calibration) is context-
/// dependent and time-varying, so it is deliberately NOT cached — it is
/// recomputed per evaluation (it's a handful of arithmetic ops). That keeps the
/// cache valid under the spec's rule: invalidate only on text change.
///
/// The full feature vector rides along because the §3.2 fusion consumes
/// individual features, not just the squashed `fastScore` — a cache hit must
/// be able to recombine them with fresh context (domain trust, provenance,
/// calibration) without re-running the analyzer.
///
/// `aiProbability`/`uncertainty` are the GENERAL detector's output;
/// `expertProbability`/`expertUncertainty` come from the routed expert when
/// one ran. The cache key already encodes which (general, expert) pair scored
/// the text, so entries never mix detectors.
public struct CachedScores: Sendable {
    public let fastScore: Double
    public let heuristicConfidence: Double
    public let aiProbability: Double?         // nil = general classifier didn't run
    public let uncertainty: Double?
    public let expertProbability: Double?     // nil = no expert ran
    public let expertUncertainty: Double?
    public let features: HeuristicFeatures

    public init(fastScore: Double, heuristicConfidence: Double,
                aiProbability: Double?, uncertainty: Double?,
                expertProbability: Double? = nil, expertUncertainty: Double? = nil,
                features: HeuristicFeatures) {
        self.fastScore = fastScore
        self.heuristicConfidence = heuristicConfidence
        self.aiProbability = aiProbability
        self.uncertainty = uncertainty
        self.expertProbability = expertProbability
        self.expertUncertainty = expertUncertainty
        self.features = features
    }
}

/// Small thread-safe LRU keyed by content hash. Re-encounters of the same
/// block (scrolling, rescans, window switches) cost a dictionary lookup
/// instead of a model inference — the main battery saver.
public final class DetectionCache: @unchecked Sendable {

    private let capacity: Int
    private var store: [String: CachedScores] = [:]
    private var order: [String] = []   // least-recent first
    private let lock = NSLock()

    public init(capacity: Int = 1024) {
        self.capacity = max(8, capacity)
    }

    public func scores(for key: String) -> CachedScores? {
        lock.lock(); defer { lock.unlock() }
        let value = store[key]
        if value != nil { touch(key) }
        return value
    }

    public func insert(_ scores: CachedScores, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if store[key] == nil, store.count >= capacity, let oldest = order.first {
            store.removeValue(forKey: oldest)
            order.removeFirst()
        }
        store[key] = scores
        touch(key)
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return store.count
    }

    private func touch(_ key: String) {
        if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
        order.append(key)
    }
}
