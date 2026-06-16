import Foundation

public final class TemporalStabilizer: @unchecked Sendable {
    private var smoothed: [String: Double] = [:]
    private let lock = NSLock()

    private let alpha: Double = 0.35

    public init() {}

    public func update(blockID: String, p: Double) -> Double {
        lock.lock(); defer { lock.unlock() }

        let previousSmoothed = smoothed[blockID] ?? p
        let newSmoothed = alpha * p + (1 - alpha) * previousSmoothed
        smoothed[blockID] = newSmoothed

        return newSmoothed
    }

    public func clear(blockID: String) {
        lock.lock(); defer { lock.unlock() }
        smoothed.removeValue(forKey: blockID)
    }

    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        smoothed.removeAll()
    }

    /// Drop EMA state for every block id NOT in `ids`. Paragraphs that have
    /// scrolled off screen can no longer leak smoothed history into a future
    /// scan, and (with content-based ids) state can't grow unboundedly.
    public func retain(ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        for key in smoothed.keys where !ids.contains(key) {
            smoothed.removeValue(forKey: key)
        }
    }
}
