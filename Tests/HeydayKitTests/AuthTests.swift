import Foundation
import Testing
@testable import HeydayKit

// MARK: - Test Doubles

private final class ScriptedAuthHTTPTransport: AuthHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [@Sendable (URLRequest) throws -> (Data, HTTPURLResponse)]
    private(set) var recordedRequests: [URLRequest] = []

    init(_ handlers: [@Sendable (URLRequest) throws -> (Data, HTTPURLResponse)]) {
        self.handlers = handlers
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let handler: (@Sendable (URLRequest) throws -> (Data, HTTPURLResponse))? = lock.withLock {
            recordedRequests.append(request)
            return handlers.isEmpty ? nil : handlers.removeFirst()
        }
        guard let handler else { throw URLError(.badServerResponse) }
        return try handler(request)
    }

    var requestCount: Int {
        lock.withLock { recordedRequests.count }
    }
}

private final class InMemoryPasswordStore: PasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func password(for account: MailAccount) throws(StorageError) -> String? {
        lock.withLock { secrets[key(for: account)] }
    }

    func save(_ password: String, for account: MailAccount) throws(StorageError) {
        lock.withLock { secrets[key(for: account)] = password }
    }

    func delete(for account: MailAccount) throws(StorageError) {
        lock.withLock { _ = secrets.removeValue(forKey: key(for: account)) }
    }

    private func key(for account: MailAccount) -> String {
        "\(account.username)@\(account.imap.host):\(account.imap.port)"
    }
}

private func httpResponse(url: String = "https://example.com", status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!
}

// MARK: - Provider Catalog & ISPDB Tests

@Suite struct MailProviderCatalogTests {
    @Test func knownDomainsResolveToCuratedPresetsWithExpectedAuthSupport() {
        #expect(MailProviderCatalog.preset(forAddress: "Jane@iCloud.com")?.id == "icloud")
        #expect(MailProviderCatalog.preset(forAddress: "jane@me.com")?.authSupport == .passwordOnly)
        #expect(MailProviderCatalog.preset(forAddress: "jane@gmail.com")?.authSupport == .passwordOrOAuth2(.google, recommendedOAuth: false))
        #expect(MailProviderCatalog.preset(forAddress: "jane@outlook.kr")?.authSupport == .oauth2Only(.microsoft))
        #expect(MailProviderCatalog.preset(forAddress: "jane@fastmail.com")?.authSupport == .passwordOrOAuth2(.fastmail, recommendedOAuth: true))
        #expect(MailProviderCatalog.preset(forAddress: "jane@naver.com")?.imap == ServerEndpoint(host: "imap.naver.com", port: 993, security: .tls))
        #expect(MailProviderCatalog.preset(forAddress: "jane@unknown-domain.example") == nil)
    }

    @Test func incompleteAddressesReturnNilDomain() {
        #expect(MailProviderCatalog.domain(of: "alice") == nil)
        #expect(MailProviderCatalog.domain(of: "alice@localhost") == nil)
        #expect(MailProviderCatalog.domain(of: "@gmail.com") == nil)
        #expect(MailProviderCatalog.domain(of: "alice@gmail.com.") == nil)
        #expect(MailProviderCatalog.domain(of: "  Alice@Example.ORG ") == "example.org")
    }

    @Test func oauthProviderIsInferredFromCustomDomainServerHostnames() {
        #expect(MailProviderCatalog.oauthProvider(forHostname: "imap.gmail.com") == .google)
        #expect(MailProviderCatalog.oauthProvider(forHostname: "outlook.office365.com") == .microsoft)
        #expect(MailProviderCatalog.oauthProvider(forHostname: "imap.fastmail.com") == .fastmail)
        #expect(MailProviderCatalog.oauthProvider(forHostname: "imap.mail.me.com") == nil)
    }
}

@Suite struct ISPDBAutoconfigTests {
    @Test func parsesThunderbirdISPDBXMLForICloudAndOutlook() throws {
        let icloudXML = Data("""
        <clientConfig version="1.1">
          <emailProvider id="me.com">
            <displayName>Apple iCloud</displayName>
            <incomingServer type="imap">
              <hostname>imap.mail.me.com</hostname>
              <port>993</port>
              <socketType>SSL</socketType>
              <authentication>password-cleartext</authentication>
            </incomingServer>
            <outgoingServer type="smtp">
              <hostname>smtp.mail.me.com</hostname>
              <port>587</port>
              <socketType>STARTTLS</socketType>
              <authentication>password-cleartext</authentication>
            </outgoingServer>
          </emailProvider>
        </clientConfig>
        """.utf8)

        let icloud = try #require(AutoconfigXMLParser.parse(icloudXML))
        #expect(icloud.displayName == "Apple iCloud")
        #expect(icloud.imap == ServerEndpoint(host: "imap.mail.me.com", port: 993, security: .tls))
        #expect(icloud.smtp == ServerEndpoint(host: "smtp.mail.me.com", port: 587, security: .startTLS))
        #expect(!icloud.prefersOAuth2)
        #expect(icloud.oauthProvider == nil)

        let outlookXML = Data("""
        <clientConfig version="1.1">
          <emailProvider id="hotmail.com">
            <displayName>Outlook.com (Microsoft)</displayName>
            <incomingServer type="imap">
              <hostname>outlook.office365.com</hostname>
              <port>993</port>
              <socketType>SSL</socketType>
              <authentication>OAuth2</authentication>
            </incomingServer>
            <outgoingServer type="smtp">
              <hostname>smtp-mail.outlook.com</hostname>
              <port>587</port>
              <socketType>STARTTLS</socketType>
              <authentication>OAuth2</authentication>
            </outgoingServer>
          </emailProvider>
        </clientConfig>
        """.utf8)

        let outlook = try #require(AutoconfigXMLParser.parse(outlookXML))
        #expect(outlook.prefersOAuth2)
        #expect(outlook.oauthProvider == .microsoft)
        #expect(outlook.serverSavesSentMail)
    }

    @Test func ispdbClientFetchesDomainConfigAndReturnsNilOn404() async {
        let transport = ScriptedAuthHTTPTransport([
            { request in
                #expect(request.url?.absoluteString == "https://autoconfig.thunderbird.net/v1.1/naver.com")
                let xml = Data("""
                <clientConfig version="1.1">
                  <emailProvider id="naver.com">
                    <displayName>Naver</displayName>
                    <incomingServer type="imap"><hostname>imap.naver.com</hostname><port>993</port><socketType>SSL</socketType><authentication>password-cleartext</authentication></incomingServer>
                    <outgoingServer type="smtp"><hostname>smtp.naver.com</hostname><port>465</port><socketType>SSL</socketType><authentication>password-encrypted</authentication></outgoingServer>
                  </emailProvider>
                </clientConfig>
                """.utf8)
                return (xml, httpResponse(status: 200))
            },
            { _ in
                (Data(), httpResponse(status: 404))
            },
        ])
        let client = ISPDBClient(transport: transport)

        let found = await client.lookup(domain: "NAVER.COM")
        #expect(found?.imap.host == "imap.naver.com")
        #expect(found?.smtp.port == 465)

        let missing = await client.lookup(domain: "missing.invalid")
        #expect(missing == nil)
    }
}

// MARK: - OAuth 2.0 PKCE, DCR, and Token Refresh Tests

@Suite struct OAuth2ClientTests {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func pkceS256MatchesRFC7636TestVector() {
        // RFC 7636 Appendix B test vector.
        let pkce = OAuth2PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "state-123")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func authorizationURLIncludesPKCEAndGoogleOfflineConsent() throws {
        let config = try #require(OAuth2AccountConfig(provider: .google, clientID: "cid.apps.googleusercontent.com"))
        let pkce = OAuth2PKCE(verifier: "verifier-1", state: "state-xyz")
        let client = OAuth2Client()

        let url = client.authorizationURL(
            config: config,
            redirectURI: "http://127.0.0.1:43210/oauth/google",
            pkce: pkce,
            loginHint: "me@gmail.com"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(query["client_id"] == "cid.apps.googleusercontent.com")
        #expect(query["response_type"] == "code")
        #expect(query["code_challenge"] == pkce.challenge)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "state-xyz")
        #expect(query["login_hint"] == "me@gmail.com")
        #expect(query["access_type"] == "offline")
        #expect(query["prompt"] == "consent")
        #expect(query["scope"] == "https://mail.google.com/")
    }

    @Test func callbackParsingValidatesStateAndExtractsCodeOrError() throws {
        let client = OAuth2Client()

        let ok = URL(string: "http://127.0.0.1:5000/oauth/fastmail?code=abc123&state=s1")!
        #expect(try client.parseCallbackURL(ok, expectedState: "s1") == "abc123")

        let wrongState = URL(string: "http://127.0.0.1:5000/oauth/fastmail?code=abc123&state=wrong")!
        #expect(throws: OAuth2Error(.invalidResponse, "Sign-in state did not match.")) {
            try client.parseCallbackURL(wrongState, expectedState: "s1")
        }

        let denied = URL(string: "http://127.0.0.1:5000/oauth/google?error=access_denied&error_description=User+denied")!
        #expect(throws: OAuth2Error(.accessDenied, "User+denied")) {
            try client.parseCallbackURL(denied, expectedState: "s1")
        }
    }

    @Test func dynamicClientRegistrationExchangesMetadataForClientID() async throws {
        let transport = ScriptedAuthHTTPTransport([
            { request in
                #expect(request.httpMethod == "POST")
                let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                #expect(json?["client_name"] as? String == "Heyday")
                #expect(json?["token_endpoint_auth_method"] as? String == "none")
                #expect(json?["redirect_uris"] as? [String] == ["http://127.0.0.1:54321/oauth/fastmail"])
                return (Data(#"{"client_id":"fm-dyn-999"}"#.utf8), httpResponse(status: 201))
            },
        ])
        let client = OAuth2Client(transport: transport)
        let id = try await client.registerDynamicClient(
            at: URL(string: "https://api.fastmail.com/oauth/register")!,
            redirectURI: "http://127.0.0.1:54321/oauth/fastmail"
        )
        #expect(id == "fm-dyn-999")
    }

    @Test func codeExchangeAndRefreshPreserveUnrotatedRefreshTokenAndEncodeReservedCharacters() async throws {
        let config = try #require(OAuth2AccountConfig(provider: .google, clientID: "cid", clientSecret: "sec+ret&1=2"))
        let pkce = OAuth2PKCE(verifier: "ver", state: "st")
        let transport = ScriptedAuthHTTPTransport([
            { request in
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                #expect(body.contains("client_secret=sec%2Bret%261%3D2"))
                #expect(body.contains("code_verifier=ver"))
                return (
                    Data(#"{"access_token":"tok-1","refresh_token":"ref-1","expires_in":3600}"#.utf8),
                    httpResponse(status: 200)
                )
            },
            { _ in
                // Server omits refresh_token when not rotating it: previous refresh_token must survive.
                (
                    Data(#"{"access_token":"tok-2","expires_in":1800}"#.utf8),
                    httpResponse(status: 200)
                )
            },
        ])
        let client = OAuth2Client(transport: transport, now: { fixedNow })

        let initial = try await client.exchangeCode("auth-code", config: config, redirectURI: "http://127.0.0.1:9/cb", pkce: pkce)
        #expect(initial.accessToken == "tok-1")
        #expect(initial.refreshToken == "ref-1")
        #expect(initial.expiresAt == fixedNow.addingTimeInterval(3600))

        let refreshed = try await client.refresh(refreshToken: "ref-1", config: config)
        #expect(refreshed.accessToken == "tok-2")
        #expect(refreshed.refreshToken == "ref-1")
        #expect(refreshed.expiresAt == fixedNow.addingTimeInterval(1800))
    }

    @Test func credentialManagerCoalescesConcurrentRefreshesAndSavesUpdatedTokens() async throws {
        let config = try #require(OAuth2AccountConfig(provider: .microsoft, clientID: "ms-cid"))
        let account = MailAccount(
            sender: EmailAddress(address: "me@outlook.com"),
            username: "me@outlook.com",
            imap: MailProviderCatalog.outlook.imap,
            smtp: MailProviderCatalog.outlook.smtp,
            serverSavesSentMail: true,
            authMethod: .oauth2(config)
        )
        let store = InMemoryPasswordStore()
        let expired = OAuth2Tokens(accessToken: "old-tok", refreshToken: "ref-1", expiresAt: fixedNow.addingTimeInterval(-10))
        try store.save(try expired.encodedSecret(), for: account)

        let transport = ScriptedAuthHTTPTransport([
            { _ in
                (
                    Data(#"{"access_token":"fresh-tok","refresh_token":"ref-2","expires_in":3600}"#.utf8),
                    httpResponse(status: 200)
                )
            },
        ])
        let oauth = OAuth2Client(transport: transport, now: { fixedNow })
        let manager = OAuth2CredentialManager(account: account, config: config, store: store, client: oauth, now: { fixedNow })

        let results = try await withThrowingTaskGroup(of: MailCredential.self) { group in
            for _ in 0..<5 {
                group.addTask { try await manager.credential(forceRefresh: false) }
            }
            var out: [MailCredential] = []
            for try await item in group { out.append(item) }
            return out
        }

        #expect(results == Array(repeating: .xoauth2(accessToken: "fresh-tok"), count: 5))
        #expect(transport.requestCount == 1)
        let persisted = try OAuth2Tokens.decoded(from: try #require(try store.password(for: account)))
        #expect(persisted.accessToken == "fresh-tok")
        #expect(persisted.refreshToken == "ref-2")
    }

    @Test func invalidGrantRefreshMapsToLoginRefused() async throws {
        let config = try #require(OAuth2AccountConfig(provider: .google, clientID: "cid"))
        let account = MailAccount(
            sender: EmailAddress(address: "me@gmail.com"),
            username: "me@gmail.com",
            imap: MailProviderCatalog.gmail.imap,
            smtp: MailProviderCatalog.gmail.smtp,
            serverSavesSentMail: true,
            authMethod: .oauth2(config)
        )
        let store = InMemoryPasswordStore()
        let expired = OAuth2Tokens(accessToken: "old", refreshToken: "revoked", expiresAt: fixedNow.addingTimeInterval(-10))
        try store.save(try expired.encodedSecret(), for: account)

        let transport = ScriptedAuthHTTPTransport([
            { _ in
                (
                    Data(#"{"error":"invalid_grant","error_description":"Token has been revoked."}"#.utf8),
                    httpResponse(status: 400)
                )
            },
        ])
        let manager = OAuth2CredentialManager(
            account: account,
            config: config,
            store: store,
            client: OAuth2Client(transport: transport, now: { fixedNow }),
            now: { fixedNow }
        )

        do throws(MailError) {
            _ = try await manager.credential(forceRefresh: false)
            Issue.record("expected loginRefused")
        } catch {
            #expect(error.kind == .loginRefused)
            #expect(error.detail.contains("revoked"))
        }
    }
}

// MARK: - IMAP & SMTP XOAUTH2 Protocol Tests

@Suite struct XOAuth2ProtocolTests {
    @Test func imapAuthenticatesWithXOAuth2AndHandlesErrorContinuation() async throws {
        let expectedSASL = try #require(MailCredential.xoauth2(accessToken: "access-123").xoauth2SASLResponse(username: "me@gmail.com"))
        let okServer = ScriptedServer(greeting: "* OK ready\r\n", [
            ("AUTHENTICATE XOAUTH2 \(expectedSASL)", "{tag} OK authenticated\r\n"),
            ("CAPABILITY", "* CAPABILITY IMAP4rev1 MOVE\r\n{tag} OK\r\n"),
        ])

        let session = try await IMAPSession.open(
            ServerEndpoint(host: "127.0.0.1", port: 993, security: .none),
            username: "me@gmail.com",
            credential: .xoauth2(accessToken: "access-123"),
            using: okServer
        )
        await session.close()
        #expect(okServer.transcript.contains("AUTHENTICATE XOAUTH2 \(expectedSASL)\r\n"))

        let errorChallenge = Data(#"{"status":"400","error":"invalid_token"}"#.utf8).base64EncodedString()
        let failServer = ScriptedServer(greeting: "* OK ready\r\n", [
            ("AUTHENTICATE XOAUTH2", "+ \(errorChallenge)\r\n"),
            ("\r\n", "A1 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n"),
        ])
        do throws(MailError) {
            _ = try await IMAPSession.open(
                ServerEndpoint(host: "127.0.0.1", port: 993, security: .none),
                username: "me@gmail.com",
                credential: .xoauth2(accessToken: "bad-token"),
                using: failServer
            )
            Issue.record("expected loginRefused")
        } catch {
            #expect(error.kind == .loginRefused)
            #expect(error.detail.contains("invalid_token"))
        }
    }

    @Test func smtpAuthenticatesWithXOAuth2AndAborts334ErrorChallenge() async throws {
        let expectedSASL = try #require(MailCredential.xoauth2(accessToken: "smtp-tok").xoauth2SASLResponse(username: "me@fastmail.com"))
        let okServer = ScriptedServer(greeting: "220 ready\r\n", [
            ("EHLO", "250 AUTH XOAUTH2\r\n"),
            ("AUTH XOAUTH2 \(expectedSASL)", "235 ok\r\n"),
            ("MAIL FROM", "250 ok\r\n"),
            ("RCPT TO", "250 ok\r\n"),
            ("DATA", "354 go\r\n"),
            ("\r\n.\r\n", "250 queued\r\n"),
            ("QUIT", "221 bye\r\n"),
        ])

        try await SMTPClient.send(
            Data("Subject: Hi\r\n\r\nBody\r\n".utf8),
            from: "me@fastmail.com",
            to: ["jane@example.com"],
            via: ServerEndpoint(host: "127.0.0.1", port: 587, security: .none),
            username: "me@fastmail.com",
            credential: .xoauth2(accessToken: "smtp-tok"),
            using: okServer
        )
        #expect(okServer.transcript.contains("AUTH XOAUTH2 \(expectedSASL)\r\n"))

        let errorChallenge = Data(#"{"status":"401","message":"expired"}"#.utf8).base64EncodedString()
        let failServer = ScriptedServer(greeting: "220 ready\r\n", [
            ("EHLO", "250 AUTH XOAUTH2\r\n"),
            ("AUTH XOAUTH2", "334 \(errorChallenge)\r\n"),
            ("\r\n", "535 5.7.8 Authentication failed\r\n"),
        ])

        do throws(MailError) {
            try await SMTPClient.send(
                Data("Subject: Hi\r\n\r\nBody\r\n".utf8),
                from: "me@fastmail.com",
                to: ["jane@example.com"],
                via: ServerEndpoint(host: "127.0.0.1", port: 587, security: .none),
                username: "me@fastmail.com",
                credential: .xoauth2(accessToken: "expired-tok"),
                using: failServer
            )
            Issue.record("expected loginRefused")
        } catch {
            #expect(error.kind == .loginRefused)
            #expect(error.detail.contains("expired"))
        }
    }

    @Test func imapMailServiceRetriesOnceWithForcedOAuthRefreshWhenTokenWasRevokedEarly() async throws {
        let config = try #require(OAuth2AccountConfig(provider: .google, clientID: "cid"))
        let account = MailAccount(
            sender: EmailAddress(address: "me@gmail.com"),
            username: "me@gmail.com",
            imap: ServerEndpoint(host: "127.0.0.1", port: 993, security: .none),
            smtp: ServerEndpoint(host: "127.0.0.1", port: 465, security: .none),
            serverSavesSentMail: true,
            authMethod: .oauth2(config)
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = InMemoryPasswordStore()
        // Locally unexpired, but server rejects it and forces a refresh.
        let stale = OAuth2Tokens(accessToken: "stale-tok", refreshToken: "ref-1", expiresAt: now.addingTimeInterval(3600))
        try store.save(try stale.encodedSecret(), for: account)

        let transport = ScriptedAuthHTTPTransport([
            { _ in
                (Data(#"{"access_token":"fresh-tok","expires_in":3600}"#.utf8), httpResponse(status: 200))
            },
        ])
        let credentials = OAuth2CredentialManager(
            account: account,
            config: config,
            store: store,
            client: OAuth2Client(transport: transport, now: { now }),
            now: { now }
        )

        let staleSASL = try #require(MailCredential.xoauth2(accessToken: "stale-tok").xoauth2SASLResponse(username: "me@gmail.com"))
        let freshSASL = try #require(MailCredential.xoauth2(accessToken: "fresh-tok").xoauth2SASLResponse(username: "me@gmail.com"))
        let first = ScriptedServer(greeting: "* OK ready\r\n", [
            ("AUTHENTICATE XOAUTH2 \(staleSASL)", "{tag} NO [AUTHENTICATIONFAILED] invalid\r\n"),
        ])
        let second = ScriptedServer(greeting: "* OK ready\r\n", [
            ("AUTHENTICATE XOAUTH2 \(freshSASL)", "{tag} OK\r\n"),
            ("CAPABILITY", "* CAPABILITY IMAP4rev1\r\n{tag} OK\r\n"),
            ("LIST", "* LIST () \"/\" INBOX\r\n{tag} OK\r\n"),
        ])
        let service = IMAPMailService(
            account: account,
            credentials: credentials,
            connector: SequentialConnector([first, second])
        )

        let directory = try await service.directory()
        #expect(directory.mailboxes.map(\.path) == ["INBOX"])
        #expect(transport.requestCount == 1)
    }
}

// MARK: - AccountFeature OAuth2 & Autoconfig Tests

@Suite struct AccountFeatureOAuthTests {
    private let feature = AccountFeature()
    private let directory = MailboxDirectory(mailboxes: [Mailbox(path: "INBOX", name: "INBOX", role: .inbox)])

    @Test func legacySavedMailAccountWithoutAuthMethodDecodesAsPassword() throws {
        let legacyJSON = Data("""
        {
          "sender": {"name": "Me", "address": "me@example.com"},
          "username": "me@example.com",
          "imap": {"host": "imap.example.com", "port": 993, "security": "tls"},
          "smtp": {"host": "smtp.example.com", "port": 465, "security": "tls"},
          "serverSavesSentMail": false
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(MailAccount.self, from: legacyJSON)
        #expect(decoded.authMethod == .password)
    }

    @Test func fastmailOAuthAllowsEmptyClientIDWhileGoogleRequiresOne() throws {
        var fastmail = AccountSetup()
        fastmail.address = "me@fastmail.com"
        fastmail.apply(preset: MailProviderCatalog.fastmail)
        let fastmailAccount = try fastmail.account().get()
        #expect(fastmailAccount.authMethod.oauthConfig?.provider == .fastmail)
        #expect(fastmailAccount.authMethod.oauthConfig?.clientID == "")

        var gmail = AccountSetup()
        gmail.address = "me@gmail.com"
        gmail.apply(preset: MailProviderCatalog.gmail)
        gmail.authChoice = .oauth2
        #expect(gmail.account() == .failure(.missingOAuthClientID))

        gmail.oauthClientID = "my-google-client.apps.googleusercontent.com"
        let gmailAccount = try gmail.account().get()
        #expect(gmailAccount.authMethod.oauthConfig?.clientID == "my-google-client.apps.googleusercontent.com")
    }

    @Test func oauthConnectFlowAuthorizesConnectsAndHandlesCancelAndReauthorize() throws {
        var setup = AccountSetup()
        setup.address = "me@fastmail.com"
        setup.apply(preset: MailProviderCatalog.fastmail)

        var state = AccountFeature.State.settingUp(setup, problem: nil)
        let authEffects = feature.reduce(&state, .connectRequested)
        guard case .authorizing(let account, setup: setup) = state,
              case .oauth2(let config) = account.authMethod
        else {
            Issue.record("expected authorizing state")
            return
        }
        #expect(authEffects == [.authorizeOAuth(account, config)])

        // Cancelling returns cleanly to the setup form without an error banner.
        _ = feature.reduce(&state, .authorizationCancelled)
        #expect(state == .settingUp(setup, problem: nil))

        // Completing OAuth moves to connecting with the freshly issued tokens.
        _ = feature.reduce(&state, .connectRequested)
        var resolved = account
        var resolvedConfig = config
        resolvedConfig.clientID = "fm-dynamic-id"
        resolved.authMethod = .oauth2(resolvedConfig)
        let tokens = OAuth2Tokens(accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 1_900_000_000))

        #expect(feature.reduce(&state, .authorizationFinished(.success((resolved, tokens)))) == [.connectOAuth(resolved, newTokens: tokens)])
        _ = feature.reduce(&state, .connectionFinished(.success(directory)))
        #expect(state == .ready(resolved, directory))

        // Re-authenticating a saved OAuth account enters authorizing with setup == nil.
        let reauthEffects = feature.reduce(&state, .reauthorizeRequested)
        #expect(state == .authorizing(resolved, setup: nil))
        #expect(reauthEffects == [.authorizeOAuth(resolved, resolvedConfig)])
    }

    @Test func autoconfigMatchesBuiltInPresetImmediatelyAndIgnoresStaleISPDBReplies() {
        var setup = AccountSetup()
        setup.address = "me@icloud.com"
        var state = AccountFeature.State.settingUp(setup, problem: nil)

        #expect(feature.reduce(&state, .autoconfigRequested(domain: "icloud.com")).isEmpty)
        if case .settingUp(let updated, nil) = state {
            #expect(updated.imap.host == "imap.mail.me.com")
            #expect(updated.matchedPresetID == "icloud")
        } else {
            Issue.record("expected iCloud preset to be applied synchronously")
        }

        // Unknown domain triggers ISPDB lookup; if user changes address before reply arrives, stale reply is ignored.
        var customSetup = AccountSetup()
        customSetup.address = "me@company.example"
        state = .settingUp(customSetup, problem: nil)
        #expect(feature.reduce(&state, .autoconfigRequested(domain: "company.example")) == [.lookupAutoconfig(domain: "company.example")])

        var movedOn = customSetup
        movedOn.address = "me@other.example"
        _ = feature.reduce(&state, .setupChanged(movedOn))

        let stale = AutoconfigResult(
            displayName: "Company",
            imap: ServerEndpoint(host: "imap.company.example", port: 993, security: .tls),
            smtp: ServerEndpoint(host: "smtp.company.example", port: 465, security: .tls),
            prefersOAuth2: false,
            oauthProvider: nil,
            serverSavesSentMail: false
        )
        _ = feature.reduce(&state, .autoconfigFinished(domain: "company.example", stale))
        if case .settingUp(let current, _) = state {
            #expect(current.imap.host.isEmpty)
        } else {
            Issue.record("expected stale reply to be ignored")
        }
    }
}

// MARK: - Multi-Account Storage & Migration Tests

@Suite struct MultiAccountStoreTests {
    private func sampleAccount(_ address: String, host: String) -> MailAccount {
        MailAccount(
            sender: EmailAddress(name: address.split(separator: "@").first.map(String.init) ?? "", address: address),
            username: address,
            imap: ServerEndpoint(host: host, port: 993, security: .tls),
            smtp: ServerEndpoint(host: host, port: 465, security: .tls),
            serverSavesSentMail: false
        )
    }

    @Test func savedAccountsUpsertsSwitchesAndFallsBackOnRemoval() {
        let first = sampleAccount("me@icloud.com", host: "imap.mail.me.com")
        let second = sampleAccount("me@gmail.com", host: "imap.gmail.com")
        var updatedFirst = first
        updatedFirst.sender = EmailAddress(name: "Updated", address: first.sender.address)

        var saved = SavedAccounts()
        saved.upsert(first)
        saved.upsert(second)
        #expect(saved.accounts == [first, second])
        #expect(saved.activeAccount == second)

        // Updating an existing account preserves its position in the list.
        saved.upsert(updatedFirst, makeActive: false)
        #expect(saved.accounts.map(\.id) == [first.id, second.id])
        #expect(saved.accounts[0].sender.name == "Updated")
        #expect(saved.activeAccount == second)

        saved.select(id: first.id)
        #expect(saved.activeAccount == updatedFirst)

        // Removing the active account falls back to the next remaining one.
        saved.remove(id: first.id)
        #expect(saved.accounts == [second])
        #expect(saved.activeAccount == second)

        saved.remove(id: second.id)
        #expect(saved.isEmpty)
        #expect(saved.activeAccount == nil)
    }

    @Test func accountStoreMigratesLegacySingleAccountFileCleanly() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "heyday-accounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appending(path: "account.json")
        let multiURL = dir.appending(path: "accounts.json")

        let legacyAccount = sampleAccount("me@proton.me", host: "127.0.0.1")
        try JSONFileStore<MailAccount>(url: legacyURL).save(legacyAccount)

        let store = AccountStore(accountsURL: multiURL, legacyAccountURL: legacyURL)
        var loaded = try store.load()
        #expect(loaded.accounts == [legacyAccount])
        #expect(loaded.activeAccount == legacyAccount)

        // Adding a second account saves to accounts.json and removes the legacy file.
        let second = sampleAccount("me@fastmail.com", host: "imap.fastmail.com")
        loaded.upsert(second)
        try store.save(loaded)

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        let reloaded = try store.load()
        #expect(reloaded.accounts == [legacyAccount, second])
        #expect(reloaded.activeAccount == second)
    }

    @Test func composeStatePreservesDraftWhenSwitchingFromAccount() {
        var draft = ComposeFeature.Draft()
        draft.to = "jane@example.com"
        draft.subject = "Hello"
        draft.body = "Switching accounts keeps this text."

        let sender = EmailAddress(name: "Work", address: "me@company.com")
        let state = ComposeFeature.State(intent: .newMessage, sender: sender, draft: draft)
        #expect(state.sender == sender)
        #expect(state.draft == draft)
        #expect(state.phase == .editing(problem: nil))
    }
}
