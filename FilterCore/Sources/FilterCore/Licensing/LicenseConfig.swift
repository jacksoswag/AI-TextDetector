import Foundation

/// Static licensing configuration. The build carries no store, no price and no
/// remote validation endpoint: keys are checked locally by `LocalLicenseBackend`.
/// A distribution build would replace that backend here without touching any
/// call site.
public enum LicenseConfig {
    static let backend: LicenseBackendKind = .local
}

/// Selects the concrete validation backend.
enum LicenseBackendKind {
    case local

    func makeBackend() -> LicenseBackend {
        switch self {
        case .local: return LocalLicenseBackend()
        }
    }
}
