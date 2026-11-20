//
//  Keychain.swift
//  Journeys
//
//  Secrets kept in the Keychain: the sign-in's refresh token, never in UserDefaults or source.
//

import Foundation
import Security

/// Small secrets by key. A protocol so tests keep them in memory instead of the Keychain.
protocol CredentialStoring: AnyObject {
    func data(for key: String) -> Data?
    /// Stores `data`, replacing any value; `nil` deletes it. Returns false if the Keychain refused.
    @discardableResult
    func set(_ data: Data?, for key: String) -> Bool
}

/// Generic-password items for this app. Readable after the phone's first unlock since it started,
/// so background uploads can refresh the sign-in while the phone is locked; never synced to iCloud
/// or restored onto another device.
final class Keychain: CredentialStoring {
    private let service: String

    init(service: String = "com.performiq.Journeys") {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    func data(for key: String) -> Data? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    func set(_ data: Data?, for key: String) -> Bool {
        guard let data else {
            let status = SecItemDelete(query(key) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = query(key).merging(attributes) { _, new in new }
            return SecItemAdd(added as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}
