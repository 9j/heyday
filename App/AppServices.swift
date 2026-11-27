import Foundation
import HeydayKit
import Observation

/// The composition root: builds the pieces that talk to the outside world (the mail
/// server, the keychain, files on disk) and hands them to the state machines.
@MainActor
@Observable
final class AppServices {
    let session: Store<AccountFeature>
    /// The translation service and language chosen, for every window.
    let translation: Store<TranslationSettingsFeature>
    @ObservationIgnored private let connection = Connection()
    @ObservationIgnored private let translationKeys = KeychainTranslationKeyStore()
    private var workspace: Workspace?

    init() {
        let connection = connection
        translation = Store(
            // Until the saved choices are read: Google Translate, into the Mac's own language.
            initialState: .init(settings: TranslationSettings(
                language: TranslationLanguages.code(forLocale: Locale.preferredLanguages.first ?? "")
            )),
            feature: TranslationSettingsFeature(),
            runEffect: TranslationSettingsFeature.effects(
                store: JSONFileStore(url: Self.supportDirectory.appending(path: "translation.json")),
                keys: translationKeys
            )
        )
        translation.send(.loadRequested)
        session = Store(
            initialState: .restoring,
            feature: AccountFeature(),
            runEffect: AccountFeature.effects(
                accounts: JSONFileStore(url: Self.supportDirectory.appending(path: "account.json")),
                passwords: KeychainPasswordStore(),
                connect: { account, password throws(MailError) in
                    let service = IMAPMailService(account: account, password: password, connector: URLSessionStreamConnector())
                    // Listing the folders is also the proof that the login works.
                    let directory = try await service.directory()
                    await connection.set(service)
                    return directory
                },
                disconnect: { await connection.set(nil) }
            )
        )
    }

    /// The signed-in app, for every window and menu. Nil until an account is connected.
    var activeWorkspace: Workspace? {
        guard case .ready(let account, _) = session.state, let workspace, workspace.account == account else { return nil }
        return workspace
    }

    /// Builds the workspace for the account that has just connected.
    func openWorkspace(for account: MailAccount, directory: MailboxDirectory) async {
        guard workspace?.account != account, let service = await connection.service else { return }
        workspace = Workspace(
            account: account,
            directory: directory,
            service: service,
            imageLoader: URLSessionImageLoader(),
            translation: translation,
            translationKeys: translationKeys,
            translationTransport: URLSessionTransport(),
            rulesStore: JSONFileStore(url: Self.supportDirectory.appending(path: "rules-\(account.sender.key).json")),
            foldersStore: JSONFileStore(url: Self.supportDirectory.appending(path: "folders-\(account.sender.key).json")),
            notificationsStore: JSONFileStore(url: Self.supportDirectory.appending(path: "notifications-\(account.sender.key).json")),
            visitsStore: JSONFileStore(url: Self.supportDirectory.appending(path: "visits-\(account.sender.key).json"))
        )
    }

    /// Lets go of the workspace, and with it the connection it listens on, once its
    /// account is no longer connected.
    func closeWorkspace() {
        workspace = nil
    }

    private static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Heyday", directoryHint: .isDirectory)
    }
}

/// The live connection to the mail server, shared between the account state machine
/// (which opens and closes it) and the screens (which use it).
private actor Connection {
    private(set) var service: (any MailService)?

    func set(_ service: (any MailService)?) {
        self.service = service
    }
}
