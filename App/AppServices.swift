import Foundation
import HeydayKit
import Observation

/// One configured mail account: its connection state machine, live mail service,
/// and (once connected) its running `Workspace`.
@MainActor
@Observable
final class AccountSlot: Identifiable {
    let id: MailAccount.ID
    var account: MailAccount
    let session: Store<AccountFeature>
    var workspace: Workspace?
    @ObservationIgnored let connection = Connection()

    init(account: MailAccount, session: Store<AccountFeature>, workspace: Workspace? = nil) {
        self.id = account.id
        self.account = account
        self.session = session
        self.workspace = workspace
    }
}

/// The composition root: manages one or more connected mail accounts, their live
/// workspaces, shared translation settings, keychain credentials, and OAuth sign-in.
@MainActor
@Observable
final class AppServices {
    /// All configured accounts, in the order added.
    private(set) var slots: [AccountSlot] = []
    /// Which account is shown in the main window.
    private(set) var activeAccountID: MailAccount.ID?
    /// True once saved accounts have been read from disk.
    private(set) var hasRestored = false
    /// Full-window onboarding store shown only when zero accounts are configured.
    private(set) var onboardingSession: Store<AccountFeature>?
    /// Modal sheet store shown when adding another account alongside existing ones.
    var addingSession: Store<AccountFeature>?

    /// The translation service and language chosen, shared across accounts and windows.
    let translation: Store<TranslationSettingsFeature>

    @ObservationIgnored private let accountStore: AccountStore
    @ObservationIgnored private let passwords = KeychainPasswordStore()
    @ObservationIgnored private let oauthController = OAuthSignInController()
    @ObservationIgnored private let translationKeys = KeychainTranslationKeyStore()
    /// Holds the newly verified `MailService` for an onboarding or Add Account flow
    /// until the store transitions to `.ready` and promotes it into an `AccountSlot`.
    @ObservationIgnored private let draftConnection = Connection()

    init() {
        accountStore = AccountStore(
            accountsURL: Self.supportDirectory.appending(path: "accounts.json"),
            legacyAccountURL: Self.supportDirectory.appending(path: "account.json")
        )
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
    }

    // MARK: Active & connected accounts

    var activeSlot: AccountSlot? {
        if let activeAccountID, let match = slots.first(where: { $0.id == activeAccountID }) {
            return match
        }
        return slots.first
    }

    var activeWorkspace: Workspace? {
        activeSlot?.workspace
    }

    var connectedWorkspaces: [Workspace] {
        slots.compactMap(\.workspace)
    }

    func slot(for id: MailAccount.ID) -> AccountSlot? {
        slots.first { $0.id == id }
    }

    func workspace(for id: MailAccount.ID) -> Workspace? {
        slot(for: id)?.workspace
    }

    /// Total unread Mebox count across every connected account whose inbox has loaded.
    /// Nil until at least one account has finished loading Mebox.
    var totalUnseenMeboxCount: Int? {
        let counts = connectedWorkspaces.compactMap { $0.unseenMeboxConversations?.count }
        guard !counts.isEmpty else { return nil }
        return counts.reduce(0, +)
    }

    /// Per-account conversations awaiting notification announcements.
    var unseenToAnnounceByAccount: [MailAccount.ID: [Conversation]] {
        var result: [MailAccount.ID: [Conversation]] = [:]
        for workspace in connectedWorkspaces {
            if let conversations = workspace.unseenToAnnounce {
                result[workspace.account.id] = conversations
            }
        }
        return result
    }

    // MARK: Lifecycle

    func restoreIfNeeded() {
        guard !hasRestored else { return }
        hasRestored = true
        let saved = (try? accountStore.load()) ?? SavedAccounts()
        if saved.accounts.isEmpty {
            onboardingSession = makeDraftSession()
        } else {
            activeAccountID = saved.activeAccount?.id
            for account in saved.accounts {
                let slot = makeSavedSlot(for: account)
                slots.append(slot)
                slot.session.send(.launched)
            }
        }
    }

    /// Brings every connected workspace up to date when the app comes to the front.
    func cameToTheFront() {
        for workspace in connectedWorkspaces {
            workspace.cameToTheFront()
        }
    }

    // MARK: Switching, adding, and removing accounts

    func selectAccount(_ id: MailAccount.ID) {
        guard slots.contains(where: { $0.id == id }), activeAccountID != id else { return }
        activeAccountID = id
        persistSavedAccounts()
    }

    func selectNextAccount() {
        guard slots.count > 1,
              let activeID = activeSlot?.id,
              let index = slots.firstIndex(where: { $0.id == activeID })
        else { return }
        let next = slots[(index + 1) % slots.count]
        selectAccount(next.id)
    }

    func beginAddingAccount() {
        guard addingSession == nil else { return }
        addingSession = makeDraftSession()
    }

    func dismissAddingAccount() {
        if let addingSession, case .authorizing = addingSession.state {
            Task { await oauthController.cancel() }
        }
        addingSession = nil
        Task { await draftConnection.set(nil) }
    }

    /// Promotes a newly connected onboarding or Add Account flow into a live `AccountSlot`.
    func promoteDraftAccount(_ account: MailAccount, directory: MailboxDirectory) async {
        guard let service = await draftConnection.service else { return }
        await draftConnection.set(nil)

        let workspace = makeWorkspace(for: account, directory: directory, service: service)
        if let existingIndex = slots.firstIndex(where: { $0.id == account.id }) {
            let slot = makeSavedSlot(for: account, initialState: .ready(account, directory), workspace: workspace)
            await slot.connection.set(service)
            slots[existingIndex] = slot
        } else {
            let slot = makeSavedSlot(for: account, initialState: .ready(account, directory), workspace: workspace)
            await slot.connection.set(service)
            slots.append(slot)
        }
        activeAccountID = account.id
        onboardingSession = nil
        addingSession = nil
        persistSavedAccounts()
    }

    /// Removes a configured account from disk, keychain, and memory without disturbing others.
    func removeAccount(_ id: MailAccount.ID) {
        guard let slot = slot(for: id) else { return }
        if case .authorizing = slot.session.state {
            Task { await oauthController.cancel() }
        }
        slot.session.send(.signOutRequested)
    }

    /// Cancels an in-flight OAuth browser sign-in for the given store and frees its listener immediately.
    func cancelOAuthSignIn(for store: Store<AccountFeature>) {
        Task { await oauthController.cancel() }
        store.send(.authorizationCancelled)
    }

    // MARK: Slot & draft store builders

    private func makeSavedSlot(
        for account: MailAccount,
        initialState: AccountFeature.State = .restoring,
        workspace: Workspace? = nil
    ) -> AccountSlot {
        let slotBox = SlotBox()
        let accountStore = accountStore
        let passwords = passwords
        let oauthController = oauthController

        let persistence = ClosureAccountPersistence(
            load: { account },
            save: { updated throws(StorageError) in
                var saved = (try? accountStore.load()) ?? SavedAccounts()
                saved.upsert(updated, makeActive: false)
                try accountStore.save(saved)
            },
            delete: { removed throws(StorageError) in
                var saved = (try? accountStore.load()) ?? SavedAccounts()
                saved.remove(id: removed.id)
                try accountStore.save(saved)
            }
        )

        let session = Store(
            initialState: initialState,
            feature: AccountFeature(),
            runEffect: AccountFeature.effects(
                accounts: persistence,
                passwords: passwords,
                ispdb: ISPDBClient(),
                oauthClient: OAuth2Client(),
                authorizeOAuth: { account, config throws(OAuth2Error) in
                    try await oauthController.authorize(account: account, config: config)
                },
                connect: { [weak self] account, credentials throws(MailError) in
                    let service = IMAPMailService(
                        account: account,
                        credentials: credentials,
                        connector: URLSessionStreamConnector()
                    )
                    // Listing the folders is also the proof that the login works.
                    let directory = try await service.directory()
                    if let slot = await slotBox.slot {
                        await slot.connection.set(service)
                        await self?.attachWorkspace(to: slot, account: account, directory: directory, service: service)
                    }
                    return directory
                },
                disconnect: { [weak self] in
                    if let slot = await slotBox.slot {
                        await slot.connection.set(nil)
                        await self?.finishRemovingSlot(id: slot.id)
                    }
                }
            )
        )

        let slot = AccountSlot(account: account, session: session, workspace: workspace)
        slotBox.slot = slot
        return slot
    }

    private func makeDraftSession() -> Store<AccountFeature> {
        let accountStore = accountStore
        let passwords = passwords
        let oauthController = oauthController
        let draftConnection = draftConnection

        let persistence = ClosureAccountPersistence(
            load: { nil },
            save: { account throws(StorageError) in
                var saved = (try? accountStore.load()) ?? SavedAccounts()
                saved.upsert(account, makeActive: true)
                try accountStore.save(saved)
            },
            delete: { _ in }
        )

        return Store(
            initialState: .settingUp(AccountSetup(), problem: nil),
            feature: AccountFeature(),
            runEffect: AccountFeature.effects(
                accounts: persistence,
                passwords: passwords,
                ispdb: ISPDBClient(),
                oauthClient: OAuth2Client(),
                authorizeOAuth: { account, config throws(OAuth2Error) in
                    try await oauthController.authorize(account: account, config: config)
                },
                connect: { account, credentials throws(MailError) in
                    let service = IMAPMailService(
                        account: account,
                        credentials: credentials,
                        connector: URLSessionStreamConnector()
                    )
                    let directory = try await service.directory()
                    await draftConnection.set(service)
                    return directory
                },
                disconnect: {
                    await draftConnection.set(nil)
                }
            )
        )
    }

    private func attachWorkspace(
        to slot: AccountSlot,
        account: MailAccount,
        directory: MailboxDirectory,
        service: any MailService
    ) {
        slot.account = account
        slot.workspace = makeWorkspace(for: account, directory: directory, service: service)
    }

    private func finishRemovingSlot(id: MailAccount.ID) {
        slots.removeAll { $0.id == id }
        if activeAccountID == id {
            activeAccountID = slots.first?.id
        }
        persistSavedAccounts()
        if slots.isEmpty, onboardingSession == nil {
            onboardingSession = makeDraftSession()
        }
    }

    private func persistSavedAccounts() {
        let saved = SavedAccounts(accounts: slots.map(\.account), activeAccountID: activeAccountID)
        try? accountStore.save(saved)
    }

    private func makeWorkspace(for account: MailAccount, directory: MailboxDirectory, service: any MailService) -> Workspace {
        Workspace(
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
            visitsStore: JSONFileStore(url: Self.supportDirectory.appending(path: "visits-\(account.sender.key).json")),
            bubbleUpsStore: JSONFileStore(url: Self.supportDirectory.appending(path: "bubbleups-\(account.sender.key).json"))
        )
    }

    /// Optional build-time or environment default OAuth Client ID for a provider.
    static func defaultOAuthClientID(for provider: OAuth2ProviderID) -> String? {
        let keys: (env: String, info: String)? = switch provider {
        case .google: ("HEYDAY_GOOGLE_CLIENT_ID", "HeydayGoogleClientID")
        case .microsoft: ("HEYDAY_MICROSOFT_CLIENT_ID", "HeydayMicrosoftClientID")
        case .fastmail, .custom: nil
        }
        guard let keys else { return nil }
        if let env = ProcessInfo.processInfo.environment[keys.env]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        if let info = Bundle.main.object(forInfoDictionaryKey: keys.info) as? String {
            let trimmed = info.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Heyday", directoryHint: .isDirectory)
    }
}

/// The live connection to one mail server, owned by its `AccountSlot`.
actor Connection {
    private(set) var service: (any MailService)?

    func set(_ service: (any MailService)?) {
        self.service = service
    }
}

/// Lets a slot's effect closures reach the `AccountSlot` created right after them.
@MainActor
private final class SlotBox {
    weak var slot: AccountSlot?
}

/// Serializes and cancels interactive OAuth 2.0 browser sign-in attempts cleanly.
private actor OAuthSignInController {
    private let authenticator = OAuthWebAuthenticator()
    private var currentTask: Task<(MailAccount, OAuth2Tokens), Error>?

    func authorize(account: MailAccount, config: OAuth2AccountConfig) async throws(OAuth2Error) -> (MailAccount, OAuth2Tokens) {
        currentTask?.cancel()
        let authenticator = authenticator
        let task = Task<(MailAccount, OAuth2Tokens), Error> {
            try await authenticator.authorize(account: account, config: config)
        }
        currentTask = task
        defer { currentTask = nil }
        do {
            return try await task.value
        } catch let error as OAuth2Error {
            throw error
        } catch is CancellationError {
            throw OAuth2Error(.cancelled)
        } catch {
            throw OAuth2Error(.network, error.localizedDescription)
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }
}
