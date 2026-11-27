import Foundation

/// The ordered list of accounts configured in Heyday and which one is currently open.
public struct SavedAccounts: Codable, Equatable, Sendable {
    public var accounts: [MailAccount]
    public var activeAccountID: MailAccount.ID?

    public init(accounts: [MailAccount] = [], activeAccountID: MailAccount.ID? = nil) {
        self.accounts = accounts
        if let activeAccountID, accounts.contains(where: { $0.id == activeAccountID }) {
            self.activeAccountID = activeAccountID
        } else {
            self.activeAccountID = accounts.first?.id
        }
    }

    public var isEmpty: Bool { accounts.isEmpty }

    public var activeAccount: MailAccount? {
        if let activeAccountID, let match = accounts.first(where: { $0.id == activeAccountID }) {
            return match
        }
        return accounts.first
    }

    /// Inserts a new account or updates an existing one with the same `id`, keeping list order.
    public mutating func upsert(_ account: MailAccount, makeActive: Bool = true) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        if makeActive || activeAccountID == nil {
            activeAccountID = account.id
        }
    }

    /// Removes the account with `id` and falls back `activeAccountID` to the first remaining account.
    public mutating func remove(id: MailAccount.ID) {
        accounts.removeAll { $0.id == id }
        if activeAccountID == id {
            activeAccountID = accounts.first?.id
        }
    }

    /// Makes `id` active if it exists in `accounts`.
    public mutating func select(id: MailAccount.ID) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        activeAccountID = id
    }
}

/// Persists multiple accounts in `accounts.json` while transparently migrating a
/// legacy single-account `account.json` on first read.
public struct AccountStore: Sendable {
    private let accountsFile: JSONFileStore<SavedAccounts>
    private let legacyFile: JSONFileStore<MailAccount>

    public init(accountsURL: URL, legacyAccountURL: URL) {
        self.accountsFile = JSONFileStore(url: accountsURL)
        self.legacyFile = JSONFileStore(url: legacyAccountURL)
    }

    public func load() throws(StorageError) -> SavedAccounts {
        if let saved = try accountsFile.load() {
            return saved
        }
        if let legacy = try legacyFile.load() {
            return SavedAccounts(accounts: [legacy], activeAccountID: legacy.id)
        }
        return SavedAccounts()
    }

    public func save(_ saved: SavedAccounts) throws(StorageError) {
        try accountsFile.save(saved)
        // Once persisted to the multi-account file, retire the legacy single-account file.
        try? legacyFile.delete()
    }
}

/// Persistence hooks used by one `AccountFeature` instance to load, save, and forget its account.
public protocol AccountPersistence: Sendable {
    func load() throws(StorageError) -> MailAccount?
    func save(_ account: MailAccount) throws(StorageError)
    func delete(_ account: MailAccount) throws(StorageError)
}

extension JSONFileStore: AccountPersistence where Value == MailAccount {
    public func delete(_ account: MailAccount) throws(StorageError) {
        try delete()
    }
}

/// Adapts custom persistence closures (such as a multi-account `AccountStore`) for `AccountFeature`.
public struct ClosureAccountPersistence: AccountPersistence {
    private let loadHandler: @Sendable () throws(StorageError) -> MailAccount?
    private let saveHandler: @Sendable (MailAccount) throws(StorageError) -> Void
    private let deleteHandler: @Sendable (MailAccount) throws(StorageError) -> Void

    public init(
        load: @escaping @Sendable () throws(StorageError) -> MailAccount?,
        save: @escaping @Sendable (MailAccount) throws(StorageError) -> Void,
        delete: @escaping @Sendable (MailAccount) throws(StorageError) -> Void
    ) {
        self.loadHandler = load
        self.saveHandler = save
        self.deleteHandler = delete
    }

    public func load() throws(StorageError) -> MailAccount? {
        try loadHandler()
    }

    public func save(_ account: MailAccount) throws(StorageError) {
        try saveHandler(account)
    }

    public func delete(_ account: MailAccount) throws(StorageError) {
        try deleteHandler(account)
    }
}
