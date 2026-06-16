import Foundation

/// Personal-communication surfaces are never filtered. Blurring a friend's
/// email or a DM is the catastrophic false positive — it costs more trust
/// than every invisible miss combined — so mail and messaging apps/sites are
/// suppressed wholesale. The recall lost here is invisible by definition.
public enum PersonalSurfaces {

    /// Native apps, matched against the engine's "app:<bundle-id>" domains.
    static let bundleIDs: Set<String> = [
        "com.apple.mail",
        "com.apple.MobileSMS",          // Messages
        "com.tinyspeck.slackmacgap",    // Slack
        "com.hnc.Discord",
        "org.whispersystems.signal-desktop",
        "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram", "org.telegram.desktop",
        "com.microsoft.teams2", "com.microsoft.teams",
        "com.facebook.archon",          // Messenger
        "com.readdle.SparkDesktop",
        "com.airmail.beta", "it.bloop.airmail2",
    ]

    /// Webmail and messaging web apps, suffix-matched like the trust list.
    static let webDomains: Set<String> = [
        "mail.google.com",
        "outlook.live.com", "outlook.office.com", "outlook.office365.com",
        "mail.yahoo.com",
        "mail.proton.me", "mail.protonmail.com",
        "mail.icloud.com",
        "web.whatsapp.com",
        "web.telegram.org",
        "app.slack.com",
        "discord.com",
        "teams.microsoft.com", "teams.live.com",
        "messenger.com",
        "chat.google.com",
    ]

    public static func isPersonalSurface(_ domain: String?) -> Bool {
        guard let domain, !domain.isEmpty else { return false }
        if domain.hasPrefix("app:") {
            return bundleIDs.contains(String(domain.dropFirst(4)))
        }
        guard let host = DomainTrustManager.normalize(domain) else { return false }
        return webDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
