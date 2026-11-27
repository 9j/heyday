import CryptoKit
import Foundation

/// Failure during OAuth 2.0 registration, authorization, code exchange, or refresh.
public struct OAuth2Error: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case cancelled
        case accessDenied
        case invalidGrant
        case missingClientID
        case network
        case serverError
        case invalidResponse
    }

    public let kind: Kind
    public let detail: String

    public init(_ kind: Kind, _ detail: String = "") {
        self.kind = kind
        self.detail = detail
    }

    public var userMessage: String {
        let suffix = detail.isEmpty ? "" : " (\(detail))"
        return switch kind {
        case .cancelled: "Sign-in was cancelled."
        case .accessDenied: "Access was denied by the mail provider.\(suffix)"
        case .invalidGrant: "Your sign-in session expired. Please sign in again.\(suffix)"
        case .missingClientID: "Enter an OAuth Client ID for this provider."
        case .network: "Couldn’t reach the sign-in server.\(suffix)"
        case .serverError: "The sign-in server refused the request.\(suffix)"
        case .invalidResponse: "The sign-in server returned an unexpected response.\(suffix)"
        }
    }

    public var asMailError: MailError {
        switch kind {
        case .cancelled: MailError(.refused, userMessage)
        case .accessDenied, .invalidGrant: MailError(.loginRefused, detail.isEmpty ? userMessage : detail)
        case .missingClientID: MailError(.notConfigured, userMessage)
        case .network: MailError(.unreachable, detail)
        case .serverError: MailError(.refused, detail)
        case .invalidResponse: MailError(.garbled, detail)
        }
    }
}

/// PKCE (RFC 7636) verifier/challenge and CSRF state for one authorization attempt.
public struct OAuth2PKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String
    public let state: String

    public init(verifier: String, state: String) {
        self.verifier = verifier
        self.challenge = Self.s256Challenge(for: verifier)
        self.state = state
    }

    public static func generate() -> OAuth2PKCE {
        let verifier = randomURLSafeToken(byteCount: 48)
        let state = randomURLSafeToken(byteCount: 24)
        return OAuth2PKCE(verifier: verifier, state: state)
    }

    public static func s256Challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncoded(Data(digest))
    }

    private static func randomURLSafeToken(byteCount: Int) -> String {
        let key = SymmetricKey(size: SymmetricKeySize(bitCount: byteCount * 8))
        let data = key.withUnsafeBytes { Data($0) }
        return base64URLEncoded(data)
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Pure OAuth 2.0 protocol client: RFC 7591 dynamic client registration, PKCE
/// authorization URL building, callback validation, code exchange, and token refresh.
public struct OAuth2Client: Sendable {
    private let transport: any AuthHTTPTransport
    private let now: @Sendable () -> Date

    public init(
        transport: any AuthHTTPTransport = URLSessionAuthTransport(timeout: 20),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.now = now
    }

    /// Registers a public native client dynamically via RFC 7591 (used by Fastmail).
    public func registerDynamicClient(
        at endpoint: URL,
        clientName: String = "Heyday",
        redirectURI: String
    ) async throws(OAuth2Error) -> String {
        struct RegistrationRequest: Encodable {
            let client_name: String
            let redirect_uris: [String]
            let grant_types: [String]
            let response_types: [String]
            let token_endpoint_auth_method: String
        }
        struct RegistrationResponse: Decodable {
            let client_id: String
        }

        let payload = RegistrationRequest(
            client_name: clientName,
            redirect_uris: [redirectURI],
            grant_types: ["authorization_code", "refresh_token"],
            response_types: ["code"],
            token_endpoint_auth_method: "none"
        )
        let body: Data
        do {
            body = try JSONEncoder().encode(payload)
        } catch {
            throw OAuth2Error(.invalidResponse, error.localizedDescription)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.parseError(data: data, statusCode: response.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(RegistrationResponse.self, from: data),
              !decoded.client_id.isEmpty
        else {
            throw OAuth2Error(.invalidResponse, "Missing client_id in registration response")
        }
        return decoded.client_id
    }

    /// Builds the browser authorization URL with PKCE and provider-appropriate parameters.
    public func authorizationURL(
        config: OAuth2AccountConfig,
        redirectURI: String,
        pkce: OAuth2PKCE,
        loginHint: String? = nil
    ) -> URL {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        if config.usePKCE {
            items.append(URLQueryItem(name: "code_challenge", value: pkce.challenge))
            items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        if let loginHint = loginHint?.trimmingCharacters(in: .whitespacesAndNewlines), !loginHint.isEmpty {
            items.append(URLQueryItem(name: "login_hint", value: loginHint))
        }
        if config.provider == .google {
            // Request an offline refresh token and ensure Google returns it on first consent.
            items.append(URLQueryItem(name: "access_type", value: "offline"))
            items.append(URLQueryItem(name: "prompt", value: "consent"))
        }

        var components = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + items
        return components.url!
    }

    /// Validates an OAuth redirect callback URL and extracts the authorization `code`.
    public func parseCallbackURL(_ url: URL, expectedState: String) throws(OAuth2Error) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OAuth2Error(.invalidResponse, "Malformed callback URL")
        }
        let params = Dictionary(
            (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { _, latest in latest }
        )
        if let error = params["error"] {
            let description = params["error_description"] ?? error
            if error == "access_denied" {
                throw OAuth2Error(.accessDenied, description)
            }
            throw OAuth2Error(.serverError, description)
        }
        guard params["state"] == expectedState else {
            throw OAuth2Error(.invalidResponse, "Sign-in state did not match.")
        }
        guard let code = params["code"], !code.isEmpty else {
            throw OAuth2Error(.invalidResponse, "Authorization code missing from callback.")
        }
        return code
    }

    /// Exchanges an authorization code for access and refresh tokens.
    public func exchangeCode(
        _ code: String,
        config: OAuth2AccountConfig,
        redirectURI: String,
        pkce: OAuth2PKCE
    ) async throws(OAuth2Error) -> OAuth2Tokens {
        var fields: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", config.clientID),
        ]
        if config.usePKCE {
            fields.append(("code_verifier", pkce.verifier))
        }
        if let secret = config.clientSecret, !secret.isEmpty {
            fields.append(("client_secret", secret))
        }
        return try await requestTokens(fields: fields, endpoint: config.tokenEndpoint, fallbackRefreshToken: nil)
    }

    /// Refreshes an expired access token using the saved refresh token.
    public func refresh(
        refreshToken: String,
        config: OAuth2AccountConfig
    ) async throws(OAuth2Error) -> OAuth2Tokens {
        var fields: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", config.clientID),
        ]
        if let secret = config.clientSecret, !secret.isEmpty {
            fields.append(("client_secret", secret))
        }
        return try await requestTokens(fields: fields, endpoint: config.tokenEndpoint, fallbackRefreshToken: refreshToken)
    }

    private func requestTokens(
        fields: [(String, String)],
        endpoint: URL,
        fallbackRefreshToken: String?
    ) async throws(OAuth2Error) -> OAuth2Tokens {
        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
            let scope: String?
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(Self.formEncoded(fields).utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.parseError(data: data, statusCode: response.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !decoded.access_token.isEmpty
        else {
            throw OAuth2Error(.invalidResponse, "Missing access_token in token response")
        }
        let lifetime = max(60, decoded.expires_in ?? 3600)
        return OAuth2Tokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token ?? fallbackRefreshToken,
            expiresAt: now().addingTimeInterval(lifetime),
            scope: decoded.scope
        )
    }

    private func send(_ request: URLRequest) async throws(OAuth2Error) -> (Data, HTTPURLResponse) {
        do {
            return try await transport.data(for: request)
        } catch {
            throw OAuth2Error(.network, error.localizedDescription)
        }
    }

    private static func parseError(data: Data, statusCode: Int) -> OAuth2Error {
        struct ErrorBody: Decodable {
            let error: String?
            let error_description: String?
        }
        if let body = try? JSONDecoder().decode(ErrorBody.self, from: data) {
            let code = body.error?.lowercased() ?? ""
            let detail = body.error_description ?? body.error ?? "HTTP \(statusCode)"
            if code == "invalid_grant" || code == "invalid_token" {
                return OAuth2Error(.invalidGrant, detail)
            }
            if code == "access_denied" {
                return OAuth2Error(.accessDenied, detail)
            }
            return OAuth2Error(.serverError, detail)
        }
        return OAuth2Error(.serverError, "HTTP \(statusCode)")
    }

    /// Strict RFC 3986 form encoding so `+`, `&`, `=`, `/` in tokens/secrets travel safely.
    static func formEncoded(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&")
    }

    private static let formAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func percentEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? string
    }
}
