import Foundation

/// Persisted OAuth 2.0 configuration for a connected mail account.
public struct OAuth2AccountConfig: Codable, Equatable, Hashable, Sendable {
    public var provider: OAuth2ProviderID
    public var issuer: String
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var registrationEndpoint: URL?
    public var scopes: [String]
    public var clientID: String
    public var clientSecret: String?
    public var usePKCE: Bool

    public init(
        provider: OAuth2ProviderID,
        issuer: String,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        registrationEndpoint: URL? = nil,
        scopes: [String],
        clientID: String,
        clientSecret: String? = nil,
        usePKCE: Bool = true
    ) {
        self.provider = provider
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.scopes = scopes
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.usePKCE = usePKCE
    }

    public init?(provider: OAuth2ProviderID, clientID: String, clientSecret: String? = nil) {
        guard let defaults = provider.defaults else { return nil }
        self.init(
            provider: provider,
            issuer: defaults.issuer,
            authorizationEndpoint: defaults.authorizationEndpoint,
            tokenEndpoint: defaults.tokenEndpoint,
            registrationEndpoint: defaults.registrationEndpoint,
            scopes: defaults.scopes,
            clientID: clientID,
            clientSecret: clientSecret?.isEmpty == true ? nil : clientSecret,
            usePKCE: defaults.usePKCE
        )
    }
}

/// How an account authenticates to its IMAP and SMTP servers.
public enum MailAuthMethod: Codable, Equatable, Hashable, Sendable {
    case password
    case oauth2(OAuth2AccountConfig)

    public var isOAuth2: Bool {
        if case .oauth2 = self { true } else { false }
    }

    public var oauthConfig: OAuth2AccountConfig? {
        if case .oauth2(let config) = self { config } else { nil }
    }
}

/// A live credential passed to an IMAP or SMTP connection.
public enum MailCredential: Equatable, Sendable {
    case password(String)
    case xoauth2(accessToken: String)

    /// Encodes the SASL `XOAUTH2` initial client response:
    /// `base64("user=<username>\x01auth=Bearer <token>\x01\x01")`.
    public func xoauth2SASLResponse(username: String) -> String? {
        guard case .xoauth2(let accessToken) = self else { return nil }
        let raw = "user=\(username)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        return Data(raw.utf8).base64EncodedString()
    }

    /// Decodes a base64-encoded SASL `XOAUTH2` JSON error challenge (returned by IMAP `+`
    /// or SMTP `334` continuations) into a short human-readable detail string.
    public static func decodeXOAuth2ErrorChallenge(_ challenge: String) -> String? {
        let trimmed = challenge.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = Data(base64Encoded: trimmed) else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let parts = [
                json["error"] as? String,
                json["error_description"] as? String,
                json["message"] as? String,
                (json["status"] as? String).map { "status \($0)" },
            ].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: ": ") }
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Access and refresh tokens persisted as a JSON secret in the keychain.
public struct OAuth2Tokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    /// True when the access token has expired or will expire within `leeway` seconds.
    public func isExpiringSoon(at now: Date, leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }

    public func encodedSecret() throws(StorageError) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(self)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw StorageError("Could not encode OAuth tokens (\(error.localizedDescription)).")
        }
    }

    public static func decoded(from secret: String) throws(StorageError) -> OAuth2Tokens {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(OAuth2Tokens.self, from: Data(secret.utf8))
        } catch {
            throw StorageError("Could not read saved OAuth tokens (\(error.localizedDescription)).")
        }
    }
}

/// Supplies fresh credentials to IMAP and SMTP connections.
public protocol CredentialProvider: Sendable {
    var supportsRefresh: Bool { get }
    func credential(forceRefresh: Bool) async throws(MailError) -> MailCredential
}

/// Fixed password or token provider.
public struct StaticCredentialProvider: CredentialProvider {
    private let value: MailCredential
    public let supportsRefresh = false

    public init(_ credential: MailCredential) {
        self.value = credential
    }

    public func credential(forceRefresh: Bool) async throws(MailError) -> MailCredential {
        value
    }
}

/// Manages an OAuth 2.0 account's access/refresh tokens in the keychain and
/// coalesces concurrent refreshes so rotating refresh tokens are never raced.
public actor OAuth2CredentialManager: CredentialProvider {
    public nonisolated let supportsRefresh = true

    private let account: MailAccount
    private let config: OAuth2AccountConfig
    private let store: any PasswordStore
    private let client: OAuth2Client
    private let now: @Sendable () -> Date

    private var cached: OAuth2Tokens?
    private var inFlightRefresh: Task<OAuth2Tokens, Error>?

    public init(
        account: MailAccount,
        config: OAuth2AccountConfig,
        initialTokens: OAuth2Tokens? = nil,
        store: any PasswordStore,
        client: OAuth2Client = OAuth2Client(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account
        self.config = config
        self.cached = initialTokens
        self.store = store
        self.client = client
        self.now = now
    }

    public func credential(forceRefresh: Bool = false) async throws(MailError) -> MailCredential {
        let current = try loadTokensIfNeeded()
        if !forceRefresh, !current.isExpiringSoon(at: now()) {
            return .xoauth2(accessToken: current.accessToken)
        }
        let refreshed = try await refreshTokens(from: current)
        return .xoauth2(accessToken: refreshed.accessToken)
    }

    private func loadTokensIfNeeded() throws(MailError) -> OAuth2Tokens {
        if let cached { return cached }
        let secret: String?
        do {
            secret = try store.password(for: account)
        } catch {
            throw MailError(.notConfigured, error.message)
        }
        guard let secret else {
            throw MailError(.loginRefused, "Saved OAuth tokens are missing. Sign in again.")
        }
        do {
            let tokens = try OAuth2Tokens.decoded(from: secret)
            cached = tokens
            return tokens
        } catch {
            throw MailError(.loginRefused, "Saved OAuth tokens could not be read. Sign in again.")
        }
    }

    private func refreshTokens(from current: OAuth2Tokens) async throws(MailError) -> OAuth2Tokens {
        if let inFlightRefresh {
            do {
                return try await inFlightRefresh.value
            } catch let error as MailError {
                throw error
            } catch let error as OAuth2Error {
                throw error.asMailError
            } catch {
                throw MailError(.unreachable, error.localizedDescription)
            }
        }

        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw MailError(.loginRefused, "Your sign-in session expired and cannot be refreshed automatically. Sign in again.")
        }

        let client = client
        let config = config
        let task = Task<OAuth2Tokens, Error> {
            try await client.refresh(refreshToken: refreshToken, config: config)
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }

        let refreshed: OAuth2Tokens
        do {
            refreshed = try await task.value
        } catch let error as OAuth2Error {
            throw error.asMailError
        } catch {
            throw MailError(.unreachable, error.localizedDescription)
        }

        cached = refreshed
        if let secret = try? refreshed.encodedSecret() {
            try? store.save(secret, for: account)
        }
        return refreshed
    }
}
