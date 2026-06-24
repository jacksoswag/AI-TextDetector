import Foundation

/// Brand constants: the product name, the website URLs, and the support address.
/// Single edit point for the brand. Change the domain here if it is not
/// pilcrow.app. The checkout URL lives in `LicenseConfig` (it is a Lemon Squeezy
/// concern), and there is no longer an embedded signing key — keys are validated
/// online once at activation rather than verified against a public key.
public enum Brand {
    public static let productName = "Pilcrow"

    public static let siteURL = "https://pilcrow.app"
    public static let privacyURL = "https://pilcrow.app/privacy.html"
    public static let termsURL = "https://pilcrow.app/terms.html"
    public static let supportEmail = "jacksoswag@proton.me"
}
