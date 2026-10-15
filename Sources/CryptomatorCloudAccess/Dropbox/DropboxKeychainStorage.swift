//
//  DropboxKeychainStorage.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 15.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Security
@preconcurrency import SwiftyDropbox

/**
 Keychain storage of the Dropbox access tokens, keyed by their `uid`.

 It uses the keychain items of the ObjC Dropbox SDK and reads the tokens that SDK stored, so that existing accounts stay authorized. Tokens are written in the JSON format of SwiftyDropbox.
 */
final class DropboxKeychainStorage: SecureStorageAccess, Sendable {
	private let service: String

	init(keychainService: String) {
		self.service = "\(keychainService).dropbox.authv2"
	}

	/// Nothing to migrate, because the ObjC Dropbox SDK already migrated its items to the accessibility that `query(_:)` uses.
	func checkAccessibilityMigrationOneTime() {}

	func setAccessTokenData(for userId: String, data: Data) -> Bool {
		SecItemDelete(query([kSecAttrAccount: userId]))
		return SecItemAdd(query([kSecAttrAccount: userId, kSecValueData: data]), nil) == errSecSuccess
	}

	func getAllUserIds() -> [String] {
		var result: CFTypeRef?
		guard SecItemCopyMatching(query([kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll]), &result) == errSecSuccess, let items = result as? [[CFString: Any]] else {
			return []
		}
		return items.compactMap { $0[kSecAttrAccount] as? String }
	}

	func getDropboxAccessToken(for key: String) -> DropboxAccessToken? {
		var result: CFTypeRef?
		guard SecItemCopyMatching(query([kSecAttrAccount: key, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]), &result) == errSecSuccess, let data = result as? Data else {
			return nil
		}
		return DropboxKeychainStorage.decodeAccessToken(from: data, uid: key)
	}

	func deleteInfo(for key: String) -> Bool {
		return SecItemDelete(query([kSecAttrAccount: key])) == errSecSuccess
	}

	func deleteInfoForAllKeys() -> Bool {
		return SecItemDelete(query([:])) == errSecSuccess
	}

	/// Decodes a token in the JSON format of SwiftyDropbox, in the archive format of the ObjC Dropbox SDK, or as the plain string that older versions of the ObjC Dropbox SDK stored.
	static func decodeAccessToken(from data: Data, uid: String) -> DropboxAccessToken? {
		if let accessToken = try? JSONDecoder().decode(DropboxAccessToken.self, from: data) {
			return accessToken
		} else if let legacyAccessToken = LegacyDropboxAccessToken.decode(from: data) {
			return legacyAccessToken.dropboxAccessToken
		} else {
			return String(data: data, encoding: .utf8).map { DropboxAccessToken(accessToken: $0, uid: uid) }
		}
	}

	private func query(_ attributes: [CFString: Any]) -> CFDictionary {
		let baseQuery: [CFString: Any] = [
			kSecClass: kSecClassGenericPassword,
			kSecAttrService: service,
			kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		]
		return baseQuery.merging(attributes) { $1 } as CFDictionary
	}
}

/// Decodes the `DBAccessToken` that the ObjC Dropbox SDK archived with `NSKeyedArchiver`.
final class LegacyDropboxAccessToken: NSObject, NSSecureCoding {
	static let supportsSecureCoding = true

	private let uid: String
	private let accessToken: String
	private let refreshToken: String?
	/// Seconds since 1970 at which a short-lived access token expires, or 0 for a long-lived one.
	private let tokenExpirationTimestamp: TimeInterval

	var dropboxAccessToken: DropboxAccessToken {
		if let refreshToken, tokenExpirationTimestamp > 0 {
			return DropboxAccessToken(accessToken: accessToken, uid: uid, refreshToken: refreshToken, tokenExpirationTimestamp: tokenExpirationTimestamp)
		} else {
			return DropboxAccessToken(accessToken: accessToken, uid: uid)
		}
	}

	init?(coder: NSCoder) {
		guard let uid = coder.decodeObject(of: NSString.self, forKey: "uid") as String?, let accessToken = coder.decodeObject(of: NSString.self, forKey: "accessToken") as String? else {
			return nil
		}
		self.uid = uid
		self.accessToken = accessToken
		self.refreshToken = coder.decodeObject(of: NSString.self, forKey: "refreshToken") as String?
		self.tokenExpirationTimestamp = coder.decodeDouble(forKey: "tokenExpirationTimestamp")
	}

	func encode(with coder: NSCoder) {
		coder.encode(uid, forKey: "uid")
		coder.encode(accessToken, forKey: "accessToken")
		coder.encode(refreshToken, forKey: "refreshToken")
		coder.encode(tokenExpirationTimestamp, forKey: "tokenExpirationTimestamp")
	}

	static func decode(from data: Data) -> LegacyDropboxAccessToken? {
		guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
			return nil
		}
		defer {
			unarchiver.finishDecoding()
		}
		unarchiver.setClass(LegacyDropboxAccessToken.self, forClassName: "DBAccessToken")
		return unarchiver.decodeObject(of: LegacyDropboxAccessToken.self, forKey: NSKeyedArchiveRootObjectKey)
	}
}
