import Foundation
import Security

/// PodBean OAuth 2.0 Client Credentials stored as a single JSON item in the macOS Keychain.
public struct PodbeanCredentials: Codable, Sendable, Equatable {
    public var clientID: String
    public var clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isValid: Bool {
        !clientID.isEmpty && !clientSecret.isEmpty
    }
}

public enum KeychainError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Could not access macOS Keychain: \(message)"
        }
    }
}

/// Reads, writes, and deletes PodBean credentials in the user's login Keychain.
public enum KeychainCredentialsStore {
    public static let service = "com.rubiconetic.atcstudio.publishing"
    public static let account = "podbean"

    /// Reads the saved PodBean credentials, or returns `nil` when none are stored.
    public static func load(service: String = service, account: String = account) -> PodbeanCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PodbeanCredentials.self, from: data)
    }

    /// Saves `credentials` in the Keychain (deletes any existing entry first, then adds).
    public static func save(
        _ credentials: PodbeanCredentials,
        service: String = service,
        account: String = account
    ) throws {
        try delete(service: service, account: account)
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Removes the stored PodBean credentials from the Keychain.
    public static func delete(service: String = service, account: String = account) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
