import Foundation

public enum ListFormat: Sendable {
    /// `0.0.0.0 example.com` lines (classic hosts file).
    case hosts
    /// Adblock Plus syntax; only plain `||domain^` rules are usable for hosts blocking.
    case abp
}

public struct ListSource: Sendable, Hashable {
    public let name: String
    public let url: URL
    public let format: ListFormat

    init(_ name: String, _ url: String, _ format: ListFormat) {
        self.name = name
        self.url = URL(string: url)!
        self.format = format
    }
}

/// Protection categories. They mirror Adblock Plus's feature set as far as a
/// hosts file can: whole-domain blocking only (no cosmetic filters, no VPN).
public enum BlockCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case ads, trackers, malware, cookieConsent, distractions

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ads: "Ads & adware"
        case .trackers: "Tracking protection"
        case .malware: "Malware & malvertising"
        case .cookieConsent: "Cookie consent pop-ups"
        case .distractions: "Distractions"
        }
    }

    public var summary: String {
        switch self {
        case .ads: "Banner, video and pop-up ad servers."
        case .trackers: "Analytics and cross-site tracking domains."
        case .malware: "Known malware, phishing and malvertising hosts."
        case .cookieConsent: "Consent-banner providers (OneTrust, Cookiebot, Usercentrics…)."
        case .distractions: "Push-notification prompts, newsletter pop-ups and similar nags."
        }
    }

    public var symbol: String {
        switch self {
        case .ads: "rectangle.slash"
        case .trackers: "eye.slash"
        case .malware: "ladybug"
        case .cookieConsent: "checkmark.shield"
        case .distractions: "bell.slash"
        }
    }

    /// Free in Adblock Plus, or a Premium feature there.
    public var isPremiumEquivalent: Bool {
        self == .cookieConsent || self == .distractions
    }

    public var caution: String? {
        switch self {
        case .cookieConsent:
            "Blocking the consent script usually hides the banner, but a few sites wait for it and may load incompletely."
        case .distractions:
            "Domain-level only: it removes the providers, not in-page elements served by the site itself."
        default: nil
        }
    }

    public var defaultEnabled: Bool { !isPremiumEquivalent }

    public var sources: [ListSource] {
        switch self {
        case .ads:
            [
                ListSource("StevenBlack unified hosts", "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts", .hosts),
                ListSource("Peter Lowe's ad servers", "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext", .hosts),
                ListSource("EasyList (domain rules)", "https://easylist.to/easylist/easylist.txt", .abp),
            ]
        case .trackers:
            [ListSource("EasyPrivacy (domain rules)", "https://easylist.to/easylist/easyprivacy.txt", .abp)]
        case .malware:
            [
                ListSource("URLhaus malicious hosts", "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-hosts.txt", .hosts),
                ListSource("Dandelion Sprout anti-malware", "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareHosts.txt", .hosts),
            ]
        case .cookieConsent:
            [ListSource("Fanboy Cookiemonster (domain rules)", "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt", .abp)]
        case .distractions:
            [ListSource("Fanboy Annoyances (domain rules)", "https://secure.fanboy.co.nz/fanboy-annoyance.txt", .abp)]
        }
    }

    /// Built-in domains that work even before any list has been downloaded.
    public var seed: [String] {
        switch self {
        case .cookieConsent:
            [
                "cookiebot.com", "consent.cookiebot.com", "consentcdn.cookiebot.com",
                "cdn.cookielaw.org", "cookielaw.org", "geolocation.onetrust.com",
                "cdn.privacy-mgmt.com", "sourcepoint.mgr.consensu.org", "quantcast.mgr.consensu.org",
                "cmp.quantcast.com", "consent.trustarc.com", "consent-pref.trustarc.com",
                "app.usercentrics.eu", "config.usercentrics.eu", "consent.usercentrics.eu",
                "sdk.privacy-center.org", "api.privacy-center.org", "notice.sp-prod.net",
                "cookie-script.com", "cdn.cookie-script.com", "consent.cookiefirst.com",
                "app.termly.io", "cdn.consentmanager.net", "delivery.consentmanager.net",
                "cdn.cookiehub.eu", "cmp.osano.com", "cdn.civiccomputing.com",
            ]
        case .distractions:
            [
                "cdn.onesignal.com", "onesignal.com", "api.onesignal.com",
                "cdn.pushengage.com", "clientcdn.pushengage.com", "cdn.pushcrew.com",
                "pushcrew.com", "cdn.pushwoosh.com", "cdn.webpushr.com", "app.webpushr.com",
                "cdn.izooto.com", "load.sumo.com", "a.omappapi.com", "chimpstatic.com",
            ]
        default: []
        }
    }
}
