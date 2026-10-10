import ConceptCore
import Foundation
import Security

struct KeychainStore: KeyStore {
    static let service = "is.conceptstudio.keys"
    let vllmBaseURL: String?

    init(vllmBaseURL: String? = nil) {
        self.vllmBaseURL = vllmBaseURL
    }

    func apiKey(for provider: Provider) throws -> String? {
        try read(provider.rawValue)
    }

    func read(_ account: String) throws -> String? {
        var query = Self.query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw StudioError.message("Your Mac could not read this saved key. Unlock your Keychain and try again.")
        }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String, account: String) throws {
        let query = Self.query(account)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw StudioError.message("Your Mac could not remove this key. Unlock your Keychain and try again.")
            }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw StudioError.message("Your Mac could not save this key. Unlock your Keychain and try again.")
            }
        } else if status != errSecSuccess {
            throw StudioError.message("Your Mac could not update this key. Unlock your Keychain and try again.")
        }
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
