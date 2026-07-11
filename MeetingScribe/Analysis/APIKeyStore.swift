import Foundation
import Security

protocol APIKeyStoring: Sendable {
    func save(_ apiKey: String) async throws
    func load() async throws -> String?
    func delete() async throws
}

actor KeychainAPIKeyStore: APIKeyStoring {
    private let service: String
    private let account: String

    init(
        service: String = "com.martinhostak.MeetingScribe",
        account: String = "openai-api-key"
    ) {
        self.service = service
        self.account = account
    }

    func save(_ apiKey: String) throws {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw AnalysisError.missingAPIKey }
        guard let data = normalized.data(using: .utf8) else {
            throw KeychainStoreError.invalidUTF8
        }

        let base = baseQuery
        let updateStatus = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainStoreError.status(updateStatus)
        }

        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.status(addStatus)
        }
    }

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.status(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidUTF8
        }
        return value
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.status(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum KeychainStoreError: Error, Equatable, LocalizedError {
    case invalidUTF8
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "The OpenAI API key could not be encoded."
        case let .status(status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain error \(status): \(message ?? "Unknown error")"
        }
    }
}
