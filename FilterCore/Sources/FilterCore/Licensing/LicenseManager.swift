import Combine
import CryptoKit
import Foundation

public enum LicenseStatus: Equatable, Sendable {
    case owner
    case licensed(name: String)
    case unlicensed

    public var isActive: Bool {
        switch self {
        case .owner, .licensed: return true
        case .unlicensed: return false
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
/// promise. The whole app requires a key from first launch, both always-on
/// detection and the manual Check Text window. Builds compiled with the
/// OWNER_BUILD flag (scripts/install.sh sets it) are always unlocked, so the
/// owner never pays; the public release build (scripts/release.sh) omits it
/// and enforces the key.
public final class LicenseManager: ObservableObject {

    public static let shared = LicenseManager()

    private enum Key {
        static let license = "license.key"
    }

    private let defaults: UserDefaults

    @Published public private(set) var status: LicenseStatus = .unlicensed

    public init(defaults: UserDefaults = .appGroup) {
        self.defaults = defaults
        status = Self.computeStatus(defaults)
    }

    public var isActive: Bool { status.isActive }

    /// Set true at launch by an owner build (the App target's OWNER_BUILD flag,
    /// which scripts/install.sh passes) to unlock everything without a key, so
    /// the owner never pays. The public release build leaves it false. It is set
    /// once before the first scan and only read thereafter, so `nonisolated(unsafe)`
    /// is sound: the single write happens-before every off-main read in
    /// `isCurrentlyActive()`.
    nonisolated(unsafe) public static var ownerOverride = false

    /// Thread-safe gate for the detection engine. Reads UserDefaults directly so
    /// it is safe to call off the main actor (it never touches @Published state).
    public static func isCurrentlyActive(defaults: UserDefaults = .appGroup) -> Bool {
        if ownerOverride { return true }
        return storedRecord(defaults) != nil
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
        let updated = Self.computeStatus(defaults)
        if updated != status { status = updated }
    }

    // MARK: - Pure logic (no @Published access; safe to call anywhere)

    static func computeStatus(_ defaults: UserDefaults) -> LicenseStatus {
        if ownerOverride { return .owner }
        if let record = storedRecord(defaults) { return .licensed(name: record.name) }
        return .unlicensed
    }

    static func storedRecord(_ defaults: UserDefaults) -> LicenseRecord? {
        guard let key = defaults.string(forKey: Key.license) else { return nil }
        return verify(key)
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
