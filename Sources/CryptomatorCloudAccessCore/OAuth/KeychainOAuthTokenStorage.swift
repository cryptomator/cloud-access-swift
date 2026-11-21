//
//  KeychainOAuthTokenStorage.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Security

/// The keychain calls of `KeychainOAuthTokenStorage`, which tests replace.
struct KeychainOperations: Sendable {
	var copyMatching: @Sendable (_ query: [String: Any]) -> (status: OSStatus, data: Data?) = { query in
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		return (status, result as? Data)
	}

	var add: @Sendable (_ attributes: [String: Any]) -> OSStatus = { attributes in
		SecItemAdd(attributes as CFDictionary, nil)
	}

	var update: @Sendable (_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus = { query, attributes in
		SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
	}

	var delete: @Sendable (_ query: [String: Any]) -> OSStatus = { query in
		SecItemDelete(query as CFDictionary)
	}
}

/**
 Keeps each login in a generic password of the keychain, see `OAuthPersistence.keychain(accessGroup:tokenLockDirectory:services:)`.

 An item is updated in place and never deleted to be added again, so that a failed write can't lose it. Queries don't filter by accessibility, so that an item stored with another accessibility is found, too.
 */
final class KeychainOAuthTokenStorage: OAuthTokenStorage {
	private let accessGroup: String?
	private let services: [OAuthProvider: String]
	private let operations: KeychainOperations

	init(accessGroup: String?, services: [OAuthProvider: String], operations: KeychainOperations = KeychainOperations()) {
		self.accessGroup = accessGroup
		self.services = services
		self.operations = operations
	}

	/// - Throws: `OAuthTokenStoreError.keychain` for any status but success and a missing item.
	func load(_ key: OAuthAccountKey) throws -> Data? {
		var query = query(for: key)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		let (status, data) = operations.copyMatching(query)
		switch status {
		case errSecSuccess:
			guard let data else {
				throw OAuthTokenStoreError.keychain(status: errSecInternalError)
			}
			return data
		case errSecItemNotFound:
			return nil
		default:
			throw OAuthTokenStoreError.keychain(status: status)
		}
	}

	func save(_ data: Data, for key: OAuthAccountKey) throws {
		let query = query(for: key)
		let status = operations.update(query, [kSecValueData as String: data])
		guard status == errSecItemNotFound else {
			try KeychainOAuthTokenStorage.check(status)
			return
		}
		var attributes = query
		attributes[kSecValueData as String] = data
		attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		try KeychainOAuthTokenStorage.check(operations.add(attributes))
	}

	func delete(_ key: OAuthAccountKey) throws {
		let status = operations.delete(query(for: key))
		if status != errSecItemNotFound {
			try KeychainOAuthTokenStorage.check(status)
		}
	}

	/// The service and account of the item of a login. A Google Drive login uses GTMAppAuth's layout, so that a login that GTMAppAuth stored is read in place.
	func location(of key: OAuthAccountKey) -> (service: String, account: String) {
		if key.provider == .googleDrive {
			return ("GoogleDriveAuth" + key.account, "OAuth")
		}
		return (services[key.provider] ?? "CryptomatorCloudAccess.OAuth.\(key.provider.rawValue)", key.account)
	}

	private func query(for key: OAuthAccountKey) -> [String: Any] {
		let (service, account) = location(of: key)
		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecUseDataProtectionKeychain as String: true
		]
		if let accessGroup {
			query[kSecAttrAccessGroup as String] = accessGroup
		}
		return query
	}

	private static func check(_ status: OSStatus) throws {
		guard status == errSecSuccess else {
			throw OAuthTokenStoreError.keychain(status: status)
		}
	}
}
