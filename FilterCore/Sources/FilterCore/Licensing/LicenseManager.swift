import Combine
import CryptoKit
import Foundation

public enum LicenseStatus: Equatable, Sendable {
    case owner
    case licensed(name: String)
    case trial(daysRemaining: Int)
    case expired

    public var isActive: Bool {
        switch self {
        case .owner, .licensed: return true
        case .trial(let days): return days > 0
        case .expired: return false
        }
    }
}

public struct LicenseRecord: Equatable, Sendable {
    public let name: String
    public let email: String
}

/// Offline license gate. License keys are Ed25519-signed payloads verified
/// locally against the embedded public key (`Brand.licensePublicKeyBase64`), so
/// activation needs no network and the app keeps its "nothing leaves the Mac"
/// promise. A 7-day trial runs before a key is required. Builds compiled with
/// the OWNER_BUILD flag (scripts/install.sh sets it) are always unlocked, so the
/// owner never pays; the public release build (scripts/release.sh) does not set
/// it and enforces the trial/license.
public final class LicenseManager: ObservableObject {

    public static let shared = LicenseManager()
    public static let trialDays = 7

    private enum Key {
        static let license = "license.key"
        static let trialStart = "license.trialStart" // Legacy key — read once in ensureTrialStart to migrate upgraders; never written after migration.
    }

    private let defaults: UserDefaults

    @Published public private(set) var status: LicenseStatus = .expired

    public init(defaults: UserDefaults = .appGroup) {
        self.defaults = defaults
        Self.ensureTrialStart(defaults)
        Self.touchTrialClock()
        status = Self.computeStatus(defaults)
    }

    public var isActive: Bool { status.isActive }

    /// Set true at launch by an owner build (the App target's OWNER_BUILD flag,
    /// which scripts/install.sh passes) to unlock everything without a license,
    /// so the owner never pays. The public release build leaves it false. It is
    /// set once before the first scan and only read thereafter.
    public static var ownerOverride = false

    /// Storage seam for the trial anchor: the Keychain in production, swapped for
    /// an in-memory store in tests so they never touch the real Keychain.
    static var trialStore: TrialAnchorStore = KeychainTrialStore()

    /// Thread-safe gate for the detection engine. Reads UserDefaults directly so
    /// it is safe to call off the main actor (it never touches @Published state).
    public static func isCurrentlyActive(defaults: UserDefaults = .appGroup) -> Bool {
        if ownerOverride { return true }
        if storedRecord(defaults) != nil { return true }
        return trialDaysRemaining(defaults) > 0
    }

    /// Validate and store a license key. Returns true and unlocks on success.
    @discardableResult
    public func activate(_ key: String) -> Bool {
        let cleaned = Self.sanitize(key)
        guard Self.verify(cleaned) != nil else { return false }
        defaults.set(cleaned, forKey: Key.license)
        recompute()
        return true
    }

    /// Strip all whitespace: email clients wrap a long key across lines, and a
    /// valid key (`base64url.base64url`) never contains any.
    static func sanitize(_ key: String) -> String {
        key.filter { !$0.isWhitespace }
    }

    /// Cheap shape check for the UI so it can tell "this isn't a key" from "this
    /// key was rejected": two non-empty parts separated by a single dot.
    public static func looksLikeKey(_ key: String) -> Bool {
        let parts = sanitize(key).split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    public func removeLicense() {
        defaults.removeObject(forKey: Key.license)
        recompute()
    }

    /// Recompute the published status from storage. Call on the main actor.
    public func recompute() {
        Self.touchTrialClock()
        let updated = Self.computeStatus(defaults)
        if updated != status { status = updated }
    }

    // MARK: - Pure logic (no @Published access; safe to call anywhere)

    static func computeStatus(_ defaults: UserDefaults) -> LicenseStatus {
        if ownerOverride { return .owner }
        if let record = storedRecord(defaults) { return .licensed(name: record.name) }
        let left = trialDaysRemaining(defaults)
        return left > 0 ? .trial(daysRemaining: left) : .expired
    }

    static func storedRecord(_ defaults: UserDefaults) -> LicenseRecord? {
        guard let key = defaults.string(forKey: Key.license) else { return nil }
        return verify(key)
    }

    /// Seed the trial anchor once. Migrates an existing install's UserDefaults
    /// start date into the Keychain store so upgraders keep their remaining days;
    /// a fresh install starts the clock now.
    static func ensureTrialStart(_ defaults: UserDefaults) {
        guard trialStore.start() == nil else { return }
        let seed = (defaults.object(forKey: Key.trialStart) as? Date) ?? Date()
        trialStore.seedStart(seed)
        trialStore.setLastSeen(Date())
    }

    static func trialDaysRemaining(_ defaults: UserDefaults) -> Int {
        guard let start = trialStore.start() else { return trialDays }
        let last = trialStore.lastSeen() ?? start
        return remainingDays(start: start, lastSeen: last, now: Date())
    }

    /// Days left, measured from `max(now, lastSeen)` so rolling the system clock
    /// back cannot lengthen the trial. Pure; unit-tested.
    static func remainingDays(start: Date, lastSeen: Date, now: Date) -> Int {
        let effectiveNow = max(now, lastSeen)
        let elapsedDays = Int(effectiveNow.timeIntervalSince(start) / 86_400)
        return max(0, trialDays - elapsedDays)
    }

    /// Advance the monotonic high-water mark. Called at launch and ~hourly, never
    /// on the hot gate path (a Keychain write per evaluation would be wasteful).
    static func touchTrialClock() {
        let now = Date()
        let last = trialStore.lastSeen() ?? now
        if now > last { trialStore.setLastSeen(now) }
    }

    /// Verify a license key against a public key. Returns the record on a valid
    /// signature for this product, nil otherwise. The key format is
    /// `base64url(payloadJSON).base64url(ed25519signature)`.
    public static func verify(_ key: String,
                              publicKeyBase64: String = Brand.licensePublicKeyBase64) -> LicenseRecord? {
        let parts = key.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let body = base64urlDecode(String(parts[0])),
              let signature = base64urlDecode(String(parts[1])),
              let pubData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData),
              publicKey.isValidSignature(signature, for: body),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              (json["product"] as? String) == "veritas",
              let name = json["name"] as? String,
              let email = json["email"] as? String
        else { return nil }
        return LicenseRecord(name: name, email: email)
    }

    static func base64urlDecode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}
