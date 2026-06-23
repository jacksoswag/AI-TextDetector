import Foundation
import Combine

/// User-managed whitelist of domains that bypass filtering entirely.
/// Stored locally in the shared app-group defaults. Subdomains of a trusted
/// domain are trusted ("en.wikipedia.org" matches "wikipedia.org").
public final class DomainTrustManager: ObservableObject, @unchecked Sendable {

    private static let key = "trust.domains"
    private let defaults: UserDefaults
    private let lock = NSLock()

    @Published public private(set) var domains: [String]

    public init(defaults: UserDefaults = .appGroup) {
        self.defaults = defaults
        if defaults.object(forKey: Self.key) == nil {
            defaults.set(["wikipedia.org"], forKey: Self.key)
        }
        self.domains = (defaults.stringArray(forKey: Self.key) ?? []).sorted()
    }

    public var count: Int { domains.count }

    @discardableResult
    public func add(_ raw: String) -> Bool {
        guard let domain = Self.normalize(raw), !domain.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !domains.contains(domain) else { return false }
        domains = (domains + [domain]).sorted()
        defaults.set(domains, forKey: Self.key)
        return true
    }

    public func remove(_ domain: String) {
        lock.lock(); defer { lock.unlock() }
        domains.removeAll { $0 == domain }
        defaults.set(domains, forKey: Self.key)
    }

    public func isTrusted(_ host: String) -> Bool {
        guard let host = Self.normalize(host) else { return false }
        // Reload from defaults so a stale in-memory copy can never outvote
        // an edit the user just made in the panel.
        let current = defaults.stringArray(forKey: Self.key) ?? domains
        return current.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Accepts "https://en.wikipedia.org/wiki/X", "www.wikipedia.org", "wikipedia.org".
    public static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if s.contains("://"), let url = URL(string: s), let host = url.host {
            s = host
        }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        guard s.contains(".") || s.hasPrefix("app:") else { return nil }
        return s
    }
}
