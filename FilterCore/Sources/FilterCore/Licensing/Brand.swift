import Foundation

/// Brand constants and the offline-license public key. Single edit point for the
/// product name, the website URLs, and the signing key. Change the domain here
/// if it is not veritas.app.
public enum Brand {
    public static let productName = "Veritas"

    /// Ed25519 public key (base64, raw 32 bytes) that verifies license keys. The
    /// matching private key lives in .secrets/license-private.pem (never shipped)
    /// and is used by scripts/sign-license.py and web/api/stripe-webhook.js.
    /// Regenerate both with scripts/license-keygen.py.
    public static let licensePublicKeyBase64 = "LrITl84AgLS62gxUk+xwgMh/Ry1/SQrfM3B54W9vA6A="

    public static let siteURL = "https://veritas.app"
    public static let purchaseURL = "https://veritas.app/#pricing"
    public static let privacyURL = "https://veritas.app/privacy.html"
    public static let termsURL = "https://veritas.app/terms.html"
    public static let supportEmail = "jacksoswag@proton.me"
}
