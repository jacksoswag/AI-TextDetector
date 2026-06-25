import Foundation

/// Static licensing configuration: the Lemon Squeezy validate endpoint, the
/// checkout URL, the price, and which backend validates keys. Centralised so the
/// store details plug in here without touching any call site.
///
/// Pilcrow sells through one Lemon Squeezy store (Merchant of Record). A key is
/// validated online exactly once, at activation; after that the app runs from the
/// local record with no further network calls (see `LicenseManager`). Validation
/// needs no secret API key — Lemon Squeezy's `/v1/licenses/validate` is keyed by
/// the license key itself.
public enum LicenseConfig {
    /// Lemon Squeezy's public license validation endpoint.
    static let validateEndpoint = URL(string: "https://api.lemonsqueezy.com/v1/licenses/validate")!

    /// Price shown in the purchase UI.
    public static let price = "$4.99"

    /// Lemon Squeezy checkout URL. OWNER-GATED placeholder: paste the real product
    /// checkout URL once the Lemon Squeezy store exists. The in-app "Buy Pilcrow"
    /// button opens this.
    public static let checkoutURL = URL(string: "https://spect-crow.lemonsqueezy.com/checkout/buy/f9643e6f-058f-4da1-841f-8ef58c56ddb6")!

    /// Which backend validates keys. Debug builds use `.stub`, which accepts a
    /// well-formed test key offline so the activation flow works before the store
    /// exists. Release builds always resolve `.lemonSqueezy`, so a stub can never
    /// ship and bypass licensing.
    #if DEBUG
    static let backend: LicenseBackendKind = .stub
    #else
    static let backend: LicenseBackendKind = .lemonSqueezy
    #endif
}

/// Selects the concrete validation backend. The `.stub` case is compiled only in
/// DEBUG, so the offline stub literally cannot exist in a release build.
enum LicenseBackendKind {
    case lemonSqueezy
    #if DEBUG
    case stub
    #endif

    func makeBackend() -> LicenseBackend {
        switch self {
        case .lemonSqueezy: return LemonSqueezyBackend()
        #if DEBUG
        case .stub: return StubLicenseBackend()
        #endif
        }
    }
}
