import Foundation
import Security

enum KeychainStore {
    private static let service = "app.whatnotch.Whatnotch"
    private static let previousService = "app.agenticnotch.AgenticNotch"
    private static let account = "cursor-api-key"

    static func save(_ secret: String) throws {
        let data = Data(secret.utf8)
        SecItemDelete(baseQuery(service) as CFDictionary)
        var query = baseQuery(service)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        if let access = trustedAccess() {
            query[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    static func load() -> String? {
        if let current = read(service) { return current }
        guard let previous = read(previousService) else { return nil }
        try? save(previous)
        SecItemDelete(baseQuery(previousService) as CFDictionary)
        return previous
    }

    private static func read(_ service: String) -> String? {
        var query = baseQuery(service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func baseQuery(_ service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func trustedAccess() -> SecAccess? {
        var application: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &application) == errSecSuccess,
              let application else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("Cursor API key" as CFString, [application] as CFArray, &access) == errSecSuccess else {
            return nil
        }
        return access
    }
}

struct KeychainError: Error {
    let status: OSStatus
}
