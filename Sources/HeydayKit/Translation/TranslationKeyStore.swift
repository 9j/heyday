import Foundation

/// Where the API keys of translation services are kept, by the service's id.
public protocol TranslationKeyStore: Sendable {
    /// Whether a key is stored for a service, found out without reading the key.
    func hasKey(for service: String) -> Bool
    func key(for service: String) throws(StorageError) -> String?
    /// Stores a service's key. An empty one removes what was stored.
    func save(_ key: String, for service: String) throws(StorageError)
}

/// Keys in the login keychain, one generic-password item per service.
public struct KeychainTranslationKeyStore: TranslationKeyStore {
    private let service: String

    public init(service: String = "app.heyday.mac.translation") {
        self.service = service
    }

    public func hasKey(for service: String) -> Bool {
        item(for: service).exists()
    }

    public func key(for service: String) throws(StorageError) -> String? {
        try item(for: service).read()
    }

    public func save(_ key: String, for service: String) throws(StorageError) {
        if key.isEmpty {
            try item(for: service).delete()
        } else {
            try item(for: service).save(key)
        }
    }

    private func item(for account: String) -> KeychainItem {
        KeychainItem(service: service, account: account, label: "Heyday translation API key", noun: "API key")
    }
}

extension TranslationSettings {
    /// The chosen service as it would be called now, with its key read from where
    /// keys are kept. A service that takes no key has none read.
    public func route(readingKeyFrom keys: any TranslationKeyStore) -> Result<TranslationRoute, TranslationError> {
        let service = chosenService
        var key: String?
        if service.keyNeed != .none {
            do throws(StorageError) {
                key = try keys.key(for: service.id)
            } catch {
                return .failure(TranslationError(.notSetUp, error.message))
            }
        }
        do throws(TranslationError) {
            return .success(try route(apiKey: key))
        } catch {
            return .failure(error)
        }
    }
}
