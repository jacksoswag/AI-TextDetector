import Foundation

/// The result of validating a key against the licensing backend.
enum LicenseValidation: Sendable {
    case valid
    case invalid
    /// The server couldn't be reached (offline, timeout, or unexpected response).
    /// Distinct from `.invalid` so activation fails closed — the app never stores
    /// an unverified key, and a transient outage at activation is "try again",
    /// not "rejected".
    case unreachable
}

/// Abstraction over the licensing server, so the call site (`LicenseManager`)
/// does not depend on Lemon Squeezy directly and tests can inject a fake.
protocol LicenseBackend: Sendable {
    func validate(key: String) async -> LicenseValidation
}

#if DEBUG
/// Offline stub used in DEBUG builds (and as the default test backend) until the
/// live Lemon Squeezy store exists. Accepts a well-formed test key of the form
/// `PILCROW-XXXX-XXXX-XXXX` so the whole activation + relaunch flow can be
/// exercised with no network and no account. Never compiled into a release.
struct StubLicenseBackend: LicenseBackend {
    func validate(key: String) async -> LicenseValidation {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let pattern = #"^PILCROW(-[A-Z0-9]{4}){3}$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil ? .valid : .invalid
    }
}
#endif
