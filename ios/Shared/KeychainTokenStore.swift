import Foundation
import Security

/// Shared Keychain wrapper (`app.wakepc.token`) accessible from both the app and widget extension.
public enum KeychainTokenStore {
    private static func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConfig.keychainService,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup = SharedConfig.keychainAccessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public static func save(token: String, forProfileId profileId: String) {
        if token.isEmpty {
            delete(forProfileId: profileId)
            return
        }
        delete(forProfileId: profileId)
        var query = baseQuery(account: profileId)
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    public static func load(forProfileId profileId: String) -> String? {
        var query = baseQuery(account: profileId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(forProfileId profileId: String) {
        let query = baseQuery(account: profileId)
        SecItemDelete(query as CFDictionary)
    }
}
