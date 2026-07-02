#if LOGIN_ENABLED
import Foundation
import Security

enum SessionTokenStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidTokenData
}

protocol SessionTokenStore {
    func saveToken(_ token: String) throws
    func loadToken() throws -> String?
    func deleteToken() throws
}

struct KeychainSessionTokenStore: SessionTokenStore {
    static let defaultService = "com.zeit.ESP32ControllerLogin.auth-session"
    static let defaultAccount = "FastAPI"

    private let service: String
    private let account: String

    init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SessionTokenStoreError.unexpectedStatus(addStatus)
            }
        default:
            throw SessionTokenStoreError.unexpectedStatus(updateStatus)
        }
    }

    func loadToken() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard
                let data = result as? Data,
                let token = String(data: data, encoding: .utf8)
            else {
                throw SessionTokenStoreError.invalidTokenData
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw SessionTokenStoreError.unexpectedStatus(status)
        }
    }

    func deleteToken() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SessionTokenStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }
}
#endif
