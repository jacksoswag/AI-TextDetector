import Foundation

/// The result of validating a key against the licensing backend.
enum LicenseValidation: Sendable {
    case valid
    case invalid
    /// The backend couldn't be reached. Distinct from `.invalid` so activation
    /// fails closed: an unverified key is never stored, and a transient outage
    /// reads as "try again" rather than "rejected".
    case unreachable
}

/// Abstraction over key validation, so `LicenseManager` depends on no particular
/// implementation and tests can inject a fake.
protocol LicenseBackend: Sendable {
    func validate(key: String) async -> LicenseValidation
}

/// Validates entirely on-device against a key shape. No network, no account, no
/// store. This is the only backend the open build ships.
struct LocalLicenseBackend: LicenseBackend {
    func validate(key: String) async -> LicenseValidation {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let pattern = #"^[A-Z0-9]{4}(-[A-Z0-9]{4}){3}$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil ? .valid : .invalid
    }
}
