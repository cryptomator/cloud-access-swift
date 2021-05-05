//
//  OneDriveKeychainItems.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 28.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation

enum OneDriveKeychainItemError: Error {
	case unhandledKeychainError(status: OSStatus)
	case missingAccountData
}

struct OneDriveKeychainItem {
	let account: String
	let data: Data?
	let service: String
	let secClass: String
	let generic: Data?
	let type: CFNumber?
	let accessible: String
}

extension OneDriveKeychainItem {
	static func fillKeychain() throws {
		let refreshTokenItem = try getOneDriveRefreshTokenKeychainItem()
		let accountAttribute = "\(refreshTokenItem.homeAccountId)-\(refreshTokenItem.environment)"
		let oneDriveKeychainRefreshTokenItem = OneDriveKeychainItem(account: accountAttribute, data: IntegrationTestSecrets.oneDriveRefrehTokenData, service: "refreshtoken-\(refreshTokenItem.clientId)--", secClass: kSecClassGenericPassword as String, generic: "refreshtoken-\(refreshTokenItem.clientId)-".data(using: .utf8), type: 2002 as CFNumber, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
		try save(oneDriveKeychainRefreshTokenItem)

		let accountItem = try getOneDriveAccountKeychainItem()
		let oneDriveKeychainAccountItem = OneDriveKeychainItem(account: accountAttribute, data: IntegrationTestSecrets.oneDriveAccountData, service: accountItem.realm, secClass: kSecClassGenericPassword as String, generic: nil, type: 1003 as CFNumber, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
		try save(oneDriveKeychainAccountItem)
	}

	static func getOneDriveRefreshTokenKeychainItem() throws -> OneDriveRefreshTokenKeychain {
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		guard let data = IntegrationTestSecrets.oneDriveRefrehTokenData else {
			throw OneDriveKeychainItemError.missingAccountData
		}
		return try decoder.decode(OneDriveRefreshTokenKeychain.self, from: data)
	}

	static func getOneDriveAccountKeychainItem() throws -> OneDriveAccountKeychain {
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		guard let data = IntegrationTestSecrets.oneDriveAccountData else {
			throw OneDriveKeychainItemError.missingAccountData
		}
		return try decoder.decode(OneDriveAccountKeychain.self, from: data)
	}

	static func save(_ item: OneDriveKeychainItem) throws {
		var query = [
			kSecAttrAccount as String: item.account as AnyObject,
			kSecAttrService as String: item.service as AnyObject,
			kSecClass as String: item.secClass as AnyObject,
			kSecAttrAccessible as String: item.accessible as AnyObject
		]
		query[kSecValueData as String] = item.data as AnyObject?
		query[kSecAttrGeneric as String] = item.generic as AnyObject?
		query[kSecAttrType as String] = item.type as AnyObject?

		let keychainQuery = query as CFDictionary

		SecItemDelete(keychainQuery)
		let status = SecItemAdd(keychainQuery, nil)

		guard status == noErr else {
			throw OneDriveKeychainItemError.unhandledKeychainError(status: status)
		}
	}
}

struct OneDriveRefreshTokenKeychain: Codable {
	let clientId: String
	let secret: String
	let environment: String
	let credentialType: String
	let homeAccountId: String
}

struct OneDriveAccountKeychain: Codable {
	let clientInfo: String
	let localAccountId: String
	let homeAccountId: String
	let username: String
	let environment: String
	let realm: String
	let authorityType: String
	let name: String
}
