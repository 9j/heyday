import Foundation

/// The account form: everything typed on the set-up screen.
public struct AccountSetup: Equatable, Sendable {
    public enum AuthChoice: String, Equatable, Hashable, Sendable, CaseIterable {
        case password
        case oauth2
    }

    public enum AutoconfigStatus: Equatable, Sendable {
        case idle
        case lookingUp(String)
        case matched(String)
        case notFound
    }

    public var name = ""
    public var address = ""
    public var username = ""
    public var password = ""
    public var imap = ServerEndpoint(host: "", port: 993, security: .tls)
    public var smtp = ServerEndpoint(host: "", port: 465, security: .tls)
    public var serverSavesSentMail = false
    public var authChoice: AuthChoice = .password
    public var oauthProvider: OAuth2ProviderID = .google
    public var oauthClientID = ""
    public var oauthClientSecret = ""
    public var customAuthURL = ""
    public var customTokenURL = ""
    public var customScopes = ""
    public var matchedPresetID: String?
    public var autoconfigStatus: AutoconfigStatus = .idle

    public init() {}

    /// The settings Proton Mail Bridge listens on by default. Bridge speaks to mail
    /// clients on this Mac only, and files sent mail itself.
    public static var protonBridge: AccountSetup {
        var setup = AccountSetup()
        setup.imap = ServerEndpoint(host: "127.0.0.1", port: 1143, security: .startTLS)
        setup.smtp = ServerEndpoint(host: "127.0.0.1", port: 1025, security: .startTLS)
        setup.serverSavesSentMail = true
        setup.authChoice = .password
        setup.autoconfigStatus = .matched("Proton Mail Bridge")
        return setup
    }

    public var matchedPreset: MailProviderPreset? {
        matchedPresetID.flatMap { id in MailProviderCatalog.all.first { $0.id == id } }
    }

    /// Fills server and auth defaults from a curated provider preset while keeping
    /// what the person already typed for their identity and credentials.
    public mutating func apply(preset: MailProviderPreset, defaultClientID: String? = nil) {
        imap = preset.imap
        smtp = preset.smtp
        serverSavesSentMail = preset.serverSavesSentMail
        matchedPresetID = preset.id
        autoconfigStatus = .matched(preset.displayName)
        authChoice = preset.authSupport.prefersOAuth2 ? .oauth2 : .password
        if let provider = preset.authSupport.oauthProvider {
            oauthProvider = provider
            if oauthClientID.isEmpty, let defaultClientID, !defaultClientID.isEmpty {
                oauthClientID = defaultClientID
            }
        }
    }

    /// Fills server settings from a Thunderbird ISPDB lookup result.
    public mutating func apply(autoconfig: AutoconfigResult, domain: String, defaultClientID: String? = nil) {
        imap = autoconfig.imap
        smtp = autoconfig.smtp
        serverSavesSentMail = autoconfig.serverSavesSentMail
        matchedPresetID = nil
        autoconfigStatus = .matched(autoconfig.displayName ?? domain)
        if let provider = autoconfig.oauthProvider {
            oauthProvider = provider
            authChoice = autoconfig.prefersOAuth2 ? .oauth2 : .password
            if oauthClientID.isEmpty, let defaultClientID, !defaultClientID.isEmpty {
                oauthClientID = defaultClientID
            }
        } else {
            authChoice = .password
        }
    }

    /// What is missing before a connection can be tried.
    public enum Problem: Error, Equatable, Sendable {
        case missingAddress
        case missingPassword
        case missingServer
        case missingOAuthClientID
        case invalidOAuthEndpoints

        public var userMessage: String {
            switch self {
            case .missingAddress: "Enter your email address."
            case .missingPassword: "Enter the password for this account."
            case .missingServer: "Enter the IMAP and SMTP server addresses."
            case .missingOAuthClientID: "Enter an OAuth Client ID for this provider."
            case .invalidOAuthEndpoints: "Enter valid HTTPS authorization and token URLs and at least one scope."
            }
        }
    }

    public func oauthConfig() -> Result<OAuth2AccountConfig, Problem> {
        let trimmedClientID = oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = oauthClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        if oauthProvider == .custom {
            guard !trimmedClientID.isEmpty else { return .failure(.missingOAuthClientID) }
            let scopes = customScopes
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            guard let authURL = URL(string: customAuthURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  authURL.scheme?.lowercased() == "https",
                  let tokenURL = URL(string: customTokenURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  tokenURL.scheme?.lowercased() == "https",
                  !scopes.isEmpty
            else {
                return .failure(.invalidOAuthEndpoints)
            }
            return .success(OAuth2AccountConfig(
                provider: .custom,
                issuer: authURL.host ?? authURL.absoluteString,
                authorizationEndpoint: authURL,
                tokenEndpoint: tokenURL,
                scopes: scopes,
                clientID: trimmedClientID,
                clientSecret: trimmedSecret.isEmpty ? nil : trimmedSecret,
                usePKCE: true
            ))
        }

        if trimmedClientID.isEmpty && !oauthProvider.supportsDynamicRegistration {
            return .failure(.missingOAuthClientID)
        }
        guard let config = OAuth2AccountConfig(
            provider: oauthProvider,
            clientID: trimmedClientID,
            clientSecret: trimmedSecret.isEmpty ? nil : trimmedSecret
        ) else {
            return .failure(.invalidOAuthEndpoints)
        }
        return .success(config)
    }

    public func account() -> Result<MailAccount, Problem> {
        let address = address.trimmingCharacters(in: .whitespaces)
        guard address.contains("@") else { return .failure(.missingAddress) }

        let authMethod: MailAuthMethod
        switch authChoice {
        case .password:
            guard !password.isEmpty else { return .failure(.missingPassword) }
            authMethod = .password
        case .oauth2:
            switch oauthConfig() {
            case .success(let config): authMethod = .oauth2(config)
            case .failure(let problem): return .failure(problem)
            }
        }

        guard !imap.host.trimmingCharacters(in: .whitespaces).isEmpty,
              !smtp.host.trimmingCharacters(in: .whitespaces).isEmpty
        else { return .failure(.missingServer) }

        let username = username.trimmingCharacters(in: .whitespaces)
        return .success(MailAccount(
            sender: EmailAddress(name: name.trimmingCharacters(in: .whitespaces), address: address),
            username: username.isEmpty ? address : username,
            imap: imap,
            smtp: smtp,
            serverSavesSentMail: serverSavesSentMail,
            authMethod: authMethod
        ))
    }
}

/// Whether there is an account, and whether its server can be reached.
public struct AccountFeature: Feature {
    public enum State: Equatable, Sendable {
        /// Looking for a saved account. The app has shown nothing yet.
        case restoring
        case settingUp(AccountSetup, problem: String?)
        /// Waiting for the person to complete OAuth 2.0 sign-in in the browser.
        /// `setup` is nil when re-authenticating an already saved account.
        case authorizing(MailAccount, setup: AccountSetup?)
        /// `setup` is the form the account came from, kept so a failed first
        /// connection can hand it back for correcting. Nil for a saved account.
        case connecting(MailAccount, setup: AccountSetup?)
        /// A saved account whose server did not answer. Mail cannot be shown, but the
        /// account is not forgotten.
        case unavailable(MailAccount, MailError)
        case ready(MailAccount, MailboxDirectory)
    }

    public enum Event: Sendable {
        case launched
        case savedAccountChecked(MailAccount?)
        case setupChanged(AccountSetup)
        case autoconfigRequested(domain: String)
        case autoconfigFinished(domain: String, AutoconfigResult?)
        case connectRequested
        case authorizationFinished(Result<(MailAccount, OAuth2Tokens), OAuth2Error>)
        case authorizationCancelled
        case reauthorizeRequested
        case connectionFinished(Result<MailboxDirectory, MailError>)
        case retryRequested
        case signOutRequested
        case signedOut
    }

    public enum Effect: Equatable, Sendable {
        case checkSavedAccount
        case lookupAutoconfig(domain: String)
        case authorizeOAuth(MailAccount, OAuth2AccountConfig)
        /// `newPassword` is set when a password account comes from the form and must be
        /// saved once it works; a saved account uses the credential already stored.
        case connect(MailAccount, newPassword: String?)
        /// Connects with freshly authorized OAuth 2.0 tokens and saves both account and
        /// tokens to disk/keychain once the connection succeeds.
        case connectOAuth(MailAccount, newTokens: OAuth2Tokens)
        case forget(MailAccount)
    }

    public init() {}

    public func reduce(_ state: inout State, _ event: Event) -> [Effect] {
        switch (state, event) {
        case (.restoring, .launched):
            return [.checkSavedAccount]

        case (.restoring, .savedAccountChecked(let account?)):
            state = .connecting(account, setup: nil)
            return [.connect(account, newPassword: nil)]

        case (.restoring, .savedAccountChecked(nil)):
            state = .settingUp(AccountSetup(), problem: nil)
            return []

        case (.settingUp, .setupChanged(let setup)):
            state = .settingUp(setup, problem: nil)
            return []

        case (.settingUp(var setup, let problem), .autoconfigRequested(let domain)):
            let normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { return [] }
            if let preset = MailProviderCatalog.preset(forDomain: normalized) {
                setup.apply(preset: preset)
                state = .settingUp(setup, problem: problem)
                return []
            }
            setup.matchedPresetID = nil
            setup.autoconfigStatus = .lookingUp(normalized)
            state = .settingUp(setup, problem: problem)
            return [.lookupAutoconfig(domain: normalized)]

        case (.settingUp(var setup, let problem), .autoconfigFinished(let domain, let result)):
            guard MailProviderCatalog.domain(of: setup.address) == domain else { return [] }
            if let result {
                setup.apply(autoconfig: result, domain: domain)
            } else {
                setup.autoconfigStatus = .notFound
            }
            state = .settingUp(setup, problem: problem)
            return []

        case (.settingUp(let setup, _), .connectRequested):
            switch setup.account() {
            case .success(let account):
                if case .oauth2(let config) = account.authMethod {
                    state = .authorizing(account, setup: setup)
                    return [.authorizeOAuth(account, config)]
                }
                state = .connecting(account, setup: setup)
                return [.connect(account, newPassword: setup.password)]
            case .failure(let problem):
                state = .settingUp(setup, problem: problem.userMessage)
                return []
            }

        case (.authorizing(_, let setup), .authorizationFinished(.success((let resolvedAccount, let tokens)))):
            state = .connecting(resolvedAccount, setup: setup)
            return [.connectOAuth(resolvedAccount, newTokens: tokens)]

        case (.authorizing(let account, let setup), .authorizationFinished(.failure(let error))):
            if let setup {
                state = .settingUp(setup, problem: error.kind == .cancelled ? nil : error.userMessage)
            } else {
                state = .unavailable(account, error.asMailError)
            }
            return []

        case (.authorizing(let account, let setup), .authorizationCancelled):
            if let setup {
                state = .settingUp(setup, problem: nil)
            } else {
                state = .unavailable(account, MailError(.loginRefused, "Sign-in was cancelled."))
            }
            return []

        case (.unavailable(let account, _), .reauthorizeRequested), (.ready(let account, _), .reauthorizeRequested):
            guard case .oauth2(let config) = account.authMethod else { return [] }
            state = .authorizing(account, setup: nil)
            return [.authorizeOAuth(account, config)]

        case (.connecting(let account, _), .connectionFinished(.success(let directory))):
            state = .ready(account, directory)
            return []

        case (.connecting(_, let setup?), .connectionFinished(.failure(let error))):
            // An account that has never worked goes back to the form, as typed.
            state = .settingUp(setup, problem: error.userMessage)
            return []

        case (.connecting(let account, nil), .connectionFinished(.failure(let error))):
            state = .unavailable(account, error)
            return []

        case (.unavailable(let account, _), .retryRequested):
            state = .connecting(account, setup: nil)
            return [.connect(account, newPassword: nil)]

        case (.ready(let account, _), .signOutRequested), (.unavailable(let account, _), .signOutRequested):
            return [.forget(account)]

        case (_, .signedOut):
            state = .settingUp(AccountSetup(), problem: nil)
            return []

        default:
            // An event that does not apply to the current state, such as a late
            // connection result after signing out, changes nothing.
            return []
        }
    }
}

extension AccountFeature {
    /// - Parameters:
    ///   - connect: opens the account with a `CredentialProvider` and returns its folders.
    ///     The app keeps the resulting connection for the other screens.
    ///   - authorizeOAuth: opens the platform browser flow to acquire OAuth 2.0 tokens.
    ///   - disconnect: drops that connection.
    public static func effects(
        accounts: any AccountPersistence,
        passwords: any PasswordStore,
        ispdb: ISPDBClient = ISPDBClient(),
        oauthClient: OAuth2Client = OAuth2Client(),
        authorizeOAuth: @escaping @Sendable (MailAccount, OAuth2AccountConfig) async throws(OAuth2Error) -> (MailAccount, OAuth2Tokens),
        connect: @escaping @Sendable (MailAccount, any CredentialProvider) async throws(MailError) -> MailboxDirectory,
        disconnect: @escaping @Sendable () async -> Void
    ) -> EffectRunner<AccountFeature> {
        { effect, send in
            switch effect {
            case .checkSavedAccount:
                // A saved account that cannot be read is treated as none: setting the
                // account up again replaces the file.
                await send(.savedAccountChecked(try? accounts.load()))

            case .lookupAutoconfig(let domain):
                let result = await ispdb.lookup(domain: domain)
                await send(.autoconfigFinished(domain: domain, result))

            case .authorizeOAuth(let account, let config):
                do throws(OAuth2Error) {
                    let authorized = try await authorizeOAuth(account, config)
                    await send(.authorizationFinished(.success(authorized)))
                } catch {
                    await send(.authorizationFinished(.failure(error)))
                }

            case .connect(let account, let newPassword):
                let result: Result<MailboxDirectory, MailError>
                do throws(MailError) {
                    let provider: any CredentialProvider
                    switch account.authMethod {
                    case .password:
                        let password: String
                        if let newPassword {
                            password = newPassword
                        } else {
                            guard let saved = try? passwords.password(for: account) else {
                                throw MailError(.notConfigured, "the saved password is missing")
                            }
                            password = saved
                        }
                        provider = StaticCredentialProvider(.password(password))
                    case .oauth2(let config):
                        provider = OAuth2CredentialManager(
                            account: account,
                            config: config,
                            store: passwords,
                            client: oauthClient
                        )
                    }

                    let directory = try await connect(account, provider)
                    if let newPassword, case .password = account.authMethod {
                        // Only an account that has just worked is worth remembering.
                        do throws(StorageError) {
                            try accounts.save(account)
                            try passwords.save(newPassword, for: account)
                        } catch {
                            throw MailError(.notConfigured, error.message)
                        }
                    }
                    result = .success(directory)
                } catch {
                    result = .failure(error)
                }
                await send(.connectionFinished(result))

            case .connectOAuth(let account, let newTokens):
                let result: Result<MailboxDirectory, MailError>
                do throws(MailError) {
                    guard case .oauth2(let config) = account.authMethod else {
                        throw MailError(.notConfigured, "Account is not configured for OAuth 2.0.")
                    }
                    let provider = OAuth2CredentialManager(
                        account: account,
                        config: config,
                        initialTokens: newTokens,
                        store: passwords,
                        client: oauthClient
                    )
                    let directory = try await connect(account, provider)
                    do throws(StorageError) {
                        try accounts.save(account)
                        try passwords.save(try newTokens.encodedSecret(), for: account)
                    } catch {
                        throw MailError(.notConfigured, error.message)
                    }
                    result = .success(directory)
                } catch {
                    result = .failure(error)
                }
                await send(.connectionFinished(result))

            case .forget(let account):
                await disconnect()
                // Signing out succeeds even if a leftover file or keychain item
                // cannot be removed; the next set-up overwrites both.
                try? passwords.delete(for: account)
                try? accounts.delete(account)
                await send(.signedOut)
            }
        }
    }
}
