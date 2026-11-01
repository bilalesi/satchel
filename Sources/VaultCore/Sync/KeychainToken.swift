import Foundation
import Security

/// Remote credentials live in the login keychain as generic passwords, never in
/// UserDefaults or the vault directory. File-based keychain on purpose: the data
/// protection keychain needs a provisioning profile this personal build does not have.
public enum KeychainToken {
    static let account = "token"

    public static func save(_ token: String, service: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        let result: OSStatus
        if status == errSecSuccess {
            result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "\(AppIdentity.name) remote token"
            result = SecItemAdd(add as CFDictionary, nil)
        }
        guard result == errSecSuccess else {
            throw VaultError.io("Keychain error \(result): \(SecCopyErrorMessageString(result, nil) as String? ?? "")")
        }
    }

    public static func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
