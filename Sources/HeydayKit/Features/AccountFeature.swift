import Foundation

/// The account form: everything typed on the set-up screen.
public struct AccountSetup: Equatable, Sendable {
    public var name = ""
    public var address = ""
    public var username = ""
    public var password = ""
    public var imap = ServerEndpoint(host: "", port: 993, security: .tls)
    public var smtp = ServerEndpoint(host: "", port: 465, security: .tls)
    public var serverSavesSentMail = false

    public init() {}

    /// The settings Proton Mail Bridge listens on by default. Bridge speaks to mail
    /// clients on this Mac only, and files sent mail itself.
    public static var protonBridge: AccountSetup {
        var setup = AccountSetup()
        setup.imap = ServerEndpoint(host: "127.0.0.1", port: 1143, security: .startTLS)
        setup.smtp = ServerEndpoint(host: "127.0.0.1", port: 1025, security: .startTLS)
        setup.serverSavesSentMail = true
        return setup
    }

    /// What is missing before a connection can be tried.
    public enum Problem: Error, Equatable, Sendable {
        case missingAddress
        case missingPassword
        case missingServer

        public var userMessage: String {
            switch self {
            case .missingAddress: "Enter your email address."
            case .missingPassword: "Enter the password for this account."
            case .missingServer: "Enter the IMAP and SMTP server addresses."
            }
        }
    }

    public func account() -> Result<MailAccount, Problem> {
        let address = address.trimmingCharacters(in: .whitespaces)
        guard address.contains("@") else { return .failure(.missingAddress) }
        guard !password.isEmpty else { return .failure(.missingPassword) }
        guard !imap.host.trimmingCharacters(in: .whitespaces).isEmpty,
              !smtp.host.trimmingCharacters(in: .whitespaces).isEmpty
        else { return .failure(.missingServer) }
        let username = username.trimmingCharacters(in: .whitespaces)
        return .success(MailAccount(
            sender: EmailAddress(name: name.trimmingCharacters(in: .whitespaces), address: address),
            username: username.isEmpty ? address : username,
            imap: imap,
            smtp: smtp,
            serverSavesSentMail: serverSavesSentMail
        ))
    }
}

/// Whether there is an account, and whether its server can be reached.
public struct AccountFeature: Feature {
    public enum State: Equatable, Sendable {
        /// Looking for a saved account. The app has shown nothing yet.
        case restoring
        case settingUp(AccountSetup, problem: String?)
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
        case connectRequested
        case connectionFinished(Result<MailboxDirectory, MailError>)
        case retryRequested
        case signOutRequested
        case signedOut
    }

    public enum Effect: Equatable, Sendable {
        case checkSavedAccount
        /// `newPassword` is set when the account comes from the form and must be
        /// saved once it works; a saved account uses the password already stored.
        case connect(MailAccount, newPassword: String?)
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

        case (.settingUp(let setup, _), .connectRequested):
            switch setup.account() {
            case .success(let account):
                state = .connecting(account, setup: setup)
                return [.connect(account, newPassword: setup.password)]
            case .failure(let problem):
                state = .settingUp(setup, problem: problem.userMessage)
                return []
            }

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
    ///   - connect: opens the account with a password and returns its folders. The
    ///     app keeps the resulting connection for the other screens.
    ///   - disconnect: drops that connection.
    public static func effects(
        accounts: JSONFileStore<MailAccount>,
        passwords: any PasswordStore,
        connect: @escaping @Sendable (MailAccount, String) async throws(MailError) -> MailboxDirectory,
        disconnect: @escaping @Sendable () async -> Void
    ) -> EffectRunner<AccountFeature> {
        { effect, send in
            switch effect {
            case .checkSavedAccount:
                // A saved account that cannot be read is treated as none: setting the
                // account up again replaces the file.
                await send(.savedAccountChecked(try? accounts.load()))

            case .connect(let account, let newPassword):
                let result: Result<MailboxDirectory, MailError>
                do throws(MailError) {
                    let password: String
                    if let newPassword {
                        password = newPassword
                    } else {
                        guard let saved = try? passwords.password(for: account) else {
                            throw MailError(.notConfigured, "the saved password is missing")
                        }
                        password = saved
                    }
                    let directory = try await connect(account, password)
                    if let newPassword {
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

            case .forget(let account):
                await disconnect()
                // Signing out succeeds even if a leftover file or keychain item
                // cannot be removed; the next set-up overwrites both.
                try? passwords.delete(for: account)
                try? accounts.delete()
                await send(.signedOut)
            }
        }
    }
}
