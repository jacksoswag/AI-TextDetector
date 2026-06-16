import Foundation
import Combine

/// Local-only usage counters shown in the menu. Written by the scan pipeline,
/// read by the menu UI; persisted in defaults so they survive relaunches.
public final class StatisticsManager: ObservableObject, @unchecked Sendable {

    enum Key {
        static let words = "stats.wordsFiltered"
        static let blocks = "stats.blocksFiltered"
        static let reveals = "stats.revealActions"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    @Published public private(set) var wordsFiltered: Int = 0
    @Published public private(set) var blocksFiltered: Int = 0
    @Published public private(set) var revealActions: Int = 0

    public init(defaults: UserDefaults = .appGroup) {
        self.defaults = defaults
        reload()
    }

    /// Re-read the persisted values (the menu calls this on open and on a
    /// 2 s tick while the Statistics section is expanded).
    public func reload() {
        wordsFiltered = defaults.integer(forKey: Key.words)
        blocksFiltered = defaults.integer(forKey: Key.blocks)
        revealActions = defaults.integer(forKey: Key.reveals)
    }

    public func recordFiltered(words: Int, blocks: Int) {
        guard words > 0 || blocks > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        defaults.set(defaults.integer(forKey: Key.words) + max(0, words), forKey: Key.words)
        defaults.set(defaults.integer(forKey: Key.blocks) + max(0, blocks), forKey: Key.blocks)
        DispatchQueue.main.async { self.reload() }
    }

    public func recordReveal() {
        lock.lock(); defer { lock.unlock() }
        defaults.set(defaults.integer(forKey: Key.reveals) + 1, forKey: Key.reveals)
        DispatchQueue.main.async { self.reload() }
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Key.words)
        defaults.removeObject(forKey: Key.blocks)
        defaults.removeObject(forKey: Key.reveals)
        DispatchQueue.main.async { self.reload() }
    }
}
