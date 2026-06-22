import Foundation

/// Persistent anchor for the free trial. Two timestamps:
///   - `start`: seeded once, immutable. When the trial began.
///   - `lastSeen`: a monotonic high-water mark of observed wall-clock time.
///
/// Storing these in the Keychain rather than UserDefaults means a `defaults
/// delete` or an app reinstall cannot hand out a fresh trial, and the high-water
/// mark means rolling the system clock back cannot lengthen one (elapsed time is
/// measured from `max(now, lastSeen)`). The protocol seam lets tests substitute
/// an in-memory store so they never touch the real Keychain.
protocol TrialAnchorStore: AnyObject {
    func start() -> Date?
    func seedStart(_ date: Date)
    func lastSeen() -> Date?
    func setLastSeen(_ date: Date)
}

/// Production store. Caches both values in memory (the first read populates the
/// cache) so the per-evaluate license gate does not hit the Keychain in a hot
/// loop. The lock guards the cache for the off-main-thread gate path.
final class KeychainTrialStore: TrialAnchorStore {
    private static let service = "dev.aicf.Veritas.trial"
    private let lock = NSLock()
    private var cachedStart: Date??      // outer nil = not loaded; inner nil = absent
    private var cachedLastSeen: Date??

    func start() -> Date? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cachedStart { return cached }
        let value = Self.readDate("start")
        cachedStart = .some(value)
        return value
    }

    func seedStart(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        Self.writeDate(date, "start")
        cachedStart = .some(date)
    }

    func lastSeen() -> Date? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cachedLastSeen { return cached }
        let value = Self.readDate("lastSeen")
        cachedLastSeen = .some(value)
        return value
    }

    func setLastSeen(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        Self.writeDate(date, "lastSeen")
        cachedLastSeen = .some(date)
    }

    private static func readDate(_ account: String) -> Date? {
        guard let raw = Keychain.read(service: service, account: account),
              let seconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func writeDate(_ date: Date, _ account: String) {
        Keychain.write(String(date.timeIntervalSince1970), service: service, account: account)
    }
}
