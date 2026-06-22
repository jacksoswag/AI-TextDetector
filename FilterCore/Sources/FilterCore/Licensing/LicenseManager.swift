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
        static let trialStart = "license.trialStart"
    }

    private let defaults: UserDefaults

    @Published public private(set) var status: LicenseStatus = .expired

    public init(defaults: UserDefaults = .appGroup) {
        self.defaults = defaults
        Self.ensureTrialStart(defaults)
        status = Self.computeStatus(defaults)
    }

    public var isActive: Bool { status.isActive }

    /// Set true at launch by an owner build (the App target's OWNER_BUILD flag,
    /// which scripts/install.sh passes) to unlock everything without a license,
    /// so the owner never pays. The public release build leaves it false. It is
    /// set once before the first scan and only read thereafter.
    public static var ownerOverride = false

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
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.verify(trimmed) != nil else { return false }
        defaults.set(trimmed, forKey: Key.license)
        recompute()
        return true
    }

    public func removeLicense() {
        defaults.removeObject(forKey: Key.license)
        recompute()
    }

    /// Recompute the published status from storage. Call on the main actor.
    public func recompute() {
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

    static func ensureTrialStart(_ defaults: UserDefaults) {
        if defaults.object(forKey: Key.trialStart) == nil {
            defaults.set(Date(), forKey: Key.trialStart)
        }
    }

    static func trialDaysRemaining(_ defaults: UserDefaults) -> Int {
        let start = (defaults.object(forKey: Key.trialStart) as? Date) ?? Date()
        let elapsedDays = Int(Date().timeIntervalSince(start) / 86_400)
        return max(0, trialDays - elapsedDays)
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
