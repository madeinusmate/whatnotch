import Foundation
import Security

enum KeychainStore {
    private static let service = "app.whatnotch.Whatnotch"
    private static let previousService = "app.agenticnotch.AgenticNotch"
    enum Provider: String {
        case cursor, claude, codex

        var account: String { "\(rawValue)-api-key" }
    }

    private static let account = Provider.cursor.account

    static func save(_ secret: String) throws {
        try save(secret, for: .cursor)
    }

    static func save(_ secret: String, for provider: Provider) throws {
        let data = Data(secret.utf8)
        SecItemDelete(baseQuery(service, account: provider.account) as CFDictionary)
        var query = baseQuery(service, account: provider.account)
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
        load(for: .cursor)
    }

    static func load(for provider: Provider) -> String? {
        if provider != .cursor { return read(service, account: provider.account) }
        if let current = read(service) { return current }
        guard let previous = read(previousService) else { return nil }
        try? save(previous)
        SecItemDelete(baseQuery(previousService) as CFDictionary)
        return previous
    }

    private static func read(_ service: String, account: String = Provider.cursor.account) -> String? {
        var query = baseQuery(service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func baseQuery(_ service: String, account: String = Provider.cursor.account) -> [String: Any] {
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
