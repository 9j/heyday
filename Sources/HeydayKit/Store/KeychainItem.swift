import Foundation
import Security

/// One secret in the login keychain, kept as a generic-password item.
struct KeychainItem: Sendable {
    let service: String
    let account: String
    /// What the item is called in Keychain Access and in the system's permission prompt.
    let label: String
    /// What to call the secret in an error message, such as "password".
    let noun: String

    /// Whether the item is there. Only its attributes are asked for, so this never
    /// brings up the system's permission prompt.
    func exists() -> Bool {
        var query = query
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func read() throws(StorageError) -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw StorageError("Could not read the \(noun) from the keychain (\(Self.describe(status))).")
        }
        return String(decoding: data, as: UTF8.self)
    }

    func save(_ secret: String) throws(StorageError) {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw StorageError("Could not update the \(noun) in the keychain (\(Self.describe(update))).")
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = label
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else {
            throw StorageError("Could not save the \(noun) to the keychain (\(Self.describe(add))).")
        }
    }

    func delete() throws(StorageError) {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StorageError("Could not remove the \(noun) from the keychain (\(Self.describe(status))).")
        }
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
