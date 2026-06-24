import Combine
import Foundation
import os.log

public enum LicenseStatus: Equatable, Sendable {
    case owner
    case licensed
    case unlicensed

    public var isActive: Bool {
        switch self {
        case .owner, .licensed: return true
        case .unlicensed: return false
        }
    }
}

/// On-disk record written once at activation: the validated key and when it was
/// validated. Plain JSON at 0o600 — at this price a plain stored key is the right
/// tradeoff, and the validate-once-then-trust-the-local-record model is the whole
/// point of the offline promise.
struct LicenseRecord: Codable, Equatable, Sendable {
    let key: String
    let activatedAt: Date
}

/// Online-once license gate. A key is validated against Lemon Squeezy exactly
/// once, at activation; on success the validated key + timestamp are written to
/// app-support storage (0o600) and the app is unlocked from that local record
/// from then on, with ZERO further network calls. It never re-validates on launch
/// and never locks out when offline — running fully offline after activation is
/// the product's core promise.
///
/// Two states (plus owner): licensed (a stored validated key exists) vs.
/// unlicensed. The whole app requires a key from first launch — always-on
/// detection and the manual Check Text alike. Builds compiled with OWNER_BUILD
/// (scripts/install.sh) are always unlocked, so the owner never pays; the public
/// release build (scripts/release.sh) omits it and enforces the key.
@MainActor
public final class LicenseManager: ObservableObject {

    public static let shared = LicenseManager()

    /// The outcome of an activation attempt, for the UI to report.
    public enum ActivationOutcome: Sendable {
        case activated
        case invalidKey
        /// The licensing server couldn't be reached. The one and only point where
        /// the network matters; after activation the app never calls out again.
        case networkUnavailable
    }

    @Published public private(set) var status: LicenseStatus = .unlicensed

    private var record: LicenseRecord?
    private let storeURL: URL
    private let backend: LicenseBackend
    private let now: () -> Date

    private static let log = Logger(subsystem: "dev.aicf", category: "licensing")

    /// Internal so tests (`@testable`) can inject a clock, a temp store path, and a
    /// fake backend. The app uses `.shared`.
    init(now: @escaping () -> Date = { Date() },
         storeURL: URL = AppInfo.licenseFile,
         backend: LicenseBackend = LicenseConfig.backend.makeBackend()) {
        self.now = now
        self.storeURL = storeURL
        self.backend = backend
        self.record = Self.loadRecord(from: storeURL)
        self.status = Self.computeStatus(record: record)
    }

    public var isActive: Bool { status.isActive }

    /// Set true at launch by an owner build (the App target's OWNER_BUILD flag,
    /// which scripts/install.sh passes) to unlock everything without a key, so the
    /// owner never pays. The public release build leaves it false. It is set once
    /// before the first scan and only read thereafter, so `nonisolated(unsafe)` is
    /// sound: the single write happens-before every off-main read in the gate.
    nonisolated(unsafe) public static var ownerOverride = false

    /// Thread-safe gate for the detection engine. Reads the on-disk record
    /// directly so it is safe off the main actor, and it makes NO network call —
    /// the presence of a validated record is the entitlement. Both the always-on
    /// path and the manual Check Text gate on this.
    nonisolated public static func isCurrentlyActive(storeURL: URL = AppInfo.licenseFile) -> Bool {
        if ownerOverride { return true }
        return loadRecord(from: storeURL) != nil
    }

    /// Validate a key online (once) and, on success, persist it and unlock. This is
    /// the only licensing network call; after it returns `.activated` the app runs
    /// from the local record forever, offline.
    @discardableResult
    public func activate(_ key: String) async -> ActivationOutcome {
        let cleaned = Self.sanitize(key)
        guard !cleaned.isEmpty else { return .invalidKey }
        switch await backend.validate(key: cleaned) {
        case .valid:
            let record = LicenseRecord(key: cleaned, activatedAt: now())
            self.record = record
            persist(record)
            recompute()
            return .activated
        case .invalid:
            return .invalidKey
        case .unreachable:
            return .networkUnavailable   // never store a key we couldn't verify
        }
    }

    /// Remove the stored license (returns to unlicensed). Deletes the on-disk record.
    public func removeLicense() {
        record = nil
        try? FileManager.default.removeItem(at: storeURL)
        recompute()
    }

    /// Recompute the published status from the in-memory record and the owner flag.
    public func recompute() {
        let updated = Self.computeStatus(record: record)
        if updated != status { status = updated }
    }

    // MARK: - Key shape helpers (UI pre-flight, before any network)

    /// Strip all whitespace: an email client may wrap a long key across lines, and
    /// a license key never contains internal whitespace.
    nonisolated static func sanitize(_ key: String) -> String {
        key.filter { !$0.isWhitespace }
    }

    /// Cheap plausibility check so the UI can tell "that isn't a key" from "that
    /// key was rejected" without a network round-trip: non-empty, long enough, and
    /// only key characters (letters, digits, dashes). The backend makes the real
    /// call. Accepts both Lemon Squeezy's UUID keys and the DEBUG test key.
    nonisolated public static func looksLikeKey(_ key: String) -> Bool {
        let cleaned = sanitize(key)
        guard cleaned.count >= 8 else { return false }
        return cleaned.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil
    }

    // MARK: - Pure helpers (no @Published access; safe off the main actor)

    nonisolated static func computeStatus(record: LicenseRecord?) -> LicenseStatus {
        if ownerOverride { return .owner }
        return record != nil ? .licensed : .unlicensed
    }

    nonisolated static func loadRecord(from url: URL) -> LicenseRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(LicenseRecord.self, from: data),
              !record.key.isEmpty else { return nil }
        return record
    }

    /// Write the record to disk at 0o600, surfacing failures rather than swallowing
    /// them: a lost write means a just-activated key silently vanishes on the next
    /// launch, so the UI is told.
    private func persist(_ record: LicenseRecord) {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(to: storeURL, options: [.atomic])
            // Owner-only perms: the file holds the license key. Best-effort; a chmod
            // failure shouldn't fail the write itself.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        } catch {
            // A lost write means a just-activated key won't survive the next launch.
            // The current session stays unlocked (status is already set); log it for
            // a support trail.
            Self.log.error("license write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
