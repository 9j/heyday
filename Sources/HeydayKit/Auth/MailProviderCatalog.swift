import Foundation

/// Well-known OAuth 2.0 providers whose endpoints and IMAP/SMTP scopes Heyday knows.
public enum OAuth2ProviderID: String, Codable, Hashable, Sendable, CaseIterable {
    case fastmail
    case microsoft
    case google
    case custom

    public var displayName: String {
        switch self {
        case .fastmail: "Fastmail"
        case .microsoft: "Microsoft"
        case .google: "Google"
        case .custom: "Custom OAuth 2.0"
        }
    }

    /// Whether the provider supports RFC 7591 dynamic client registration so no
    /// pre-registered Client ID is required.
    public var supportsDynamicRegistration: Bool {
        self == .fastmail
    }

    /// Standard OAuth 2.0 endpoints and scopes for this provider (nil for `.custom`).
    public var defaults: OAuth2ProviderDefaults? {
        switch self {
        case .fastmail:
            OAuth2ProviderDefaults(
                issuer: "https://api.fastmail.com",
                authorizationEndpoint: URL(string: "https://api.fastmail.com/oauth/authorize")!,
                tokenEndpoint: URL(string: "https://api.fastmail.com/oauth/refresh")!,
                registrationEndpoint: URL(string: "https://api.fastmail.com/oauth/register")!,
                scopes: ["urn:ietf:params:oauth:scope:mail", "offline_access"],
                usePKCE: true
            )
        case .microsoft:
            OAuth2ProviderDefaults(
                issuer: "https://login.microsoftonline.com/common/v2.0",
                authorizationEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
                tokenEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
                registrationEndpoint: nil,
                scopes: [
                    "https://outlook.office.com/IMAP.AccessAsUser.All",
                    "https://outlook.office.com/SMTP.Send",
                    "offline_access",
                ],
                usePKCE: true
            )
        case .google:
            OAuth2ProviderDefaults(
                issuer: "https://accounts.google.com",
                authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
                registrationEndpoint: nil,
                scopes: ["https://mail.google.com/"],
                usePKCE: true
            )
        case .custom:
            nil
        }
    }
}

/// Static protocol endpoints and scopes for a known OAuth 2.0 mail provider.
public struct OAuth2ProviderDefaults: Equatable, Sendable {
    public let issuer: String
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let registrationEndpoint: URL?
    public let scopes: [String]
    public let usePKCE: Bool

    public init(
        issuer: String,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        registrationEndpoint: URL? = nil,
        scopes: [String],
        usePKCE: Bool = true
    ) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.scopes = scopes
        self.usePKCE = usePKCE
    }
}

/// A known mail provider's server settings, authentication options, and setup guidance.
public struct MailProviderPreset: Equatable, Hashable, Sendable, Identifiable {
    public enum AuthSupport: Equatable, Hashable, Sendable {
        /// Standard password or provider-issued app password only.
        case passwordOnly
        /// Supports both password/app password and OAuth 2.0 (`recommendedOAuth` decides the default).
        case passwordOrOAuth2(OAuth2ProviderID, recommendedOAuth: Bool)
        /// Requires OAuth 2.0 (for example Microsoft consumer/M365 accounts where Basic Auth is retired).
        case oauth2Only(OAuth2ProviderID)

        public var oauthProvider: OAuth2ProviderID? {
            switch self {
            case .passwordOnly: nil
            case .passwordOrOAuth2(let provider, _), .oauth2Only(let provider): provider
            }
        }

        public var prefersOAuth2: Bool {
            switch self {
            case .passwordOnly: false
            case .passwordOrOAuth2(_, let recommended): recommended
            case .oauth2Only: true
            }
        }

        public var allowsPassword: Bool {
            if case .oauth2Only = self { return false }
            return true
        }
    }

    public let id: String
    public let displayName: String
    public let domains: [String]
    public let imap: ServerEndpoint
    public let smtp: ServerEndpoint
    public let serverSavesSentMail: Bool
    public let authSupport: AuthSupport
    /// Short one-line hint shown in the sign-in section when using password auth.
    public let passwordHelp: String?
    /// Link to the provider's app-password or IMAP settings page, when useful.
    public let passwordHelpURL: URL?
    /// Short one-line hint shown when configuring OAuth 2.0.
    public let oauthHelp: String?
    public let oauthHelpURL: URL?

    public init(
        id: String,
        displayName: String,
        domains: [String],
        imap: ServerEndpoint,
        smtp: ServerEndpoint,
        serverSavesSentMail: Bool,
        authSupport: AuthSupport,
        passwordHelp: String? = nil,
        passwordHelpURL: URL? = nil,
        oauthHelp: String? = nil,
        oauthHelpURL: URL? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.domains = domains
        self.imap = imap
        self.smtp = smtp
        self.serverSavesSentMail = serverSavesSentMail
        self.authSupport = authSupport
        self.passwordHelp = passwordHelp
        self.passwordHelpURL = passwordHelpURL
        self.oauthHelp = oauthHelp
        self.oauthHelpURL = oauthHelpURL
    }
}

/// Curated presets for major IMAP/SMTP providers so entering an email address
/// fills servers, ports, security, and auth options without manual lookup.
public enum MailProviderCatalog {
    public static let icloud = MailProviderPreset(
        id: "icloud",
        displayName: "iCloud Mail",
        domains: ["icloud.com", "me.com", "mac.com"],
        imap: ServerEndpoint(host: "imap.mail.me.com", port: 993, security: .tls),
        smtp: ServerEndpoint(host: "smtp.mail.me.com", port: 587, security: .startTLS),
        serverSavesSentMail: false,
        authSupport: .passwordOnly,
        passwordHelp: "iCloud Mail requires an Apple app-specific password (OAuth isn’t offered for third-party IMAP).",
        passwordHelpURL: URL(string: "https://account.apple.com/account/manage")
    )

    public static let gmail = MailProviderPreset(
        id: "gmail",
        displayName: "Gmail",
        domains: ["gmail.com", "googlemail.com"],
        imap: ServerEndpoint(host: "imap.gmail.com", port: 993, security: .tls),
        smtp: ServerEndpoint(host: "smtp.gmail.com", port: 465, security: .tls),
        serverSavesSentMail: true,
        authSupport: .passwordOrOAuth2(.google, recommendedOAuth: false),
        passwordHelp: "Use a Google App Password (requires 2-Step Verification), or switch to OAuth 2.0 with your own Google Cloud Desktop Client ID.",
        passwordHelpURL: URL(string: "https://myaccount.google.com/apppasswords"),
        oauthHelp: "Create a Desktop OAuth client in Google Cloud Console (Testing mode works free for your own account without CASA verification).",
        oauthHelpURL: URL(string: "https://console.cloud.google.com/apis/credentials")
    )

    public static let outlook = MailProviderPreset(
        id: "outlook",
        displayName: "Outlook / Microsoft 365",
        domains: [
            "outlook.com", "hotmail.com", "live.com", "msn.com", "windowslive.com",
            "outlook.kr", "hotmail.co.kr", "live.co.kr", "outlook.jp", "hotmail.co.jp",
            "outlook.co.uk", "hotmail.co.uk", "outlook.de", "outlook.fr",
        ],
        imap: ServerEndpoint(host: "outlook.office365.com", port: 993, security: .tls),
        smtp: ServerEndpoint(host: "smtp-mail.outlook.com", port: 587, security: .startTLS),
        serverSavesSentMail: true,
        authSupport: .oauth2Only(.microsoft),
        oauthHelp: "Microsoft retired basic IMAP passwords. Enter a free Microsoft Entra ID public-client Application ID with IMAP.AccessAsUser.All and SMTP.Send permissions.",
        oauthHelpURL: URL(string: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")
    )

    public static let fastmail = MailProviderPreset(
        id: "fastmail",
        displayName: "Fastmail",
        domains: ["fastmail.com", "fastmail.fm", "fastmail.net", "fastmail.org", "fastmail.us", "messagingengine.com"],
        imap: ServerEndpoint(host: "imap.fastmail.com", port: 993, security: .tls),
        smtp: ServerEndpoint(host: "smtp.fastmail.com", port: 465, security: .tls),
        serverSavesSentMail: false,
        authSupport: .passwordOrOAuth2(.fastmail, recommendedOAuth: true),
        passwordHelp: "Or sign in with a Fastmail app password from Settings → Privacy & Security.",
        passwordHelpURL: URL(string: "https://app.fastmail.com/settings/security/tokens"),
        oauthHelp: "Signs in directly via Fastmail OAuth 2.0 with automatic client registration — no Client ID needed."
    )

    public static let naver = MailProviderPreset(
        id: "naver",
        displayName: "Naver Mail",
        domains: ["naver.com"],
        imap: ServerEndpoint(host: "imap.naver.com", port: 993, security: .tls),
        smtp: ServerEndpoint(host: "smtp.naver.com", port: 465, security: .tls),
        serverSavesSentMail: false,
        authSupport: .passwordOnly,
        passwordHelp: "Enable IMAP/SMTP in Naver Mail settings and use an application password if 2-step verification is on.",
        passwordHelpURL: URL(string: "https://help.naver.com/service/30029/contents/21342")
    )

    public static let yahoo = MailProviderPreset(
        id: "yahoo",
        displayName: "Yahoo Mail",
        domains: ["yahoo.com", "ymail.com", "rocketmail.com"],
        imap: ServerEndpoint(host: "imap.mail.yahoo.com", port: 993, security: .tls),
        smtp: ServerEndpoint(host: "smtp.mail.yahoo.com", port: 465, security: .tls),
        serverSavesSentMail: false,
        authSupport: .passwordOnly,
        passwordHelp: "Yahoo Mail requires an app password generated in Account Security.",
        passwordHelpURL: URL(string: "https://login.yahoo.com/myaccount/security/")
    )

    public static let all: [MailProviderPreset] = [
        icloud, gmail, outlook, fastmail, naver, yahoo,
    ]

    /// Extracts the normalized domain from an email address, or nil if incomplete.
    public static func domain(of address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = trimmed.split(separator: "@", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        let domain = String(parts[1])
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return nil }
        return domain
    }

    /// Matches a known provider preset by email address or bare domain.
    public static func preset(forAddress address: String) -> MailProviderPreset? {
        guard let domain = domain(of: address) else { return nil }
        return preset(forDomain: domain)
    }

    public static func preset(forDomain domain: String) -> MailProviderPreset? {
        let normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.domains.contains(normalized) }
    }

    /// Infers a known OAuth 2.0 provider from an IMAP or SMTP hostname (e.g. for custom
    /// Google Workspace or Microsoft 365 domains discovered via Thunderbird ISPDB).
    public static func oauthProvider(forHostname hostname: String) -> OAuth2ProviderID? {
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host == "imap.gmail.com" || host == "smtp.gmail.com" || host.hasSuffix(".gmail.com") || host.hasSuffix(".googlemail.com") {
            return .google
        }
        if host.hasSuffix(".office365.com") || host.hasSuffix(".outlook.com") || host == "outlook.office365.com" {
            return .microsoft
        }
        if host.hasSuffix(".fastmail.com") || host == "imap.fastmail.com" || host == "smtp.fastmail.com" {
            return .fastmail
        }
        return nil
    }
}
