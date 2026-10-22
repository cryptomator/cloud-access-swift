//
//  OAuthPersistence.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Where the library keeps the OAuth logins of every provider, and the directory of the lock that serializes their token refreshes.

 Pass one value to the setup of every OAuth provider. Every process that uses the same logins, e.g., the app and its extensions, must pass an equal value, with a token lock directory in a container that they share.
 */
public struct OAuthPersistence: Sendable {
	let storage: any OAuthTokenStorage
	let tokenLockDirectory: URL

	private init(storage: any OAuthTokenStorage, tokenLockDirectory: URL) throws {
		guard tokenLockDirectory.isFileURL else {
			throw OAuthTokenStoreError.invalidLockDirectory
		}
		self.storage = storage
		self.tokenLockDirectory = tokenLockDirectory
	}

	/**
	 Keeps the logins in the keychain, one generic password per account. An item that the library adds is accessible after the first unlock on this device only, and an existing item keeps its accessibility.

	 A Google Drive login is kept in GTMAppAuth's item layout (service `GoogleDriveAuth` followed by the user ID, account `OAuth`), so that a login that GTMAppAuth stored is read in place. Any other provider's login is an item whose account is the user ID, in the service of `services`, or else in `CryptomatorCloudAccess.OAuth.<provider>`.

	 - Parameter accessGroup: The keychain access group of the items. With `nil`, a new item goes to the default group, which is the first group of the `keychain-access-groups` entitlement. An existing item is then found in any group that the process is entitled to.
	 - Parameter services: The keychain service of each provider's items, e.g., the one in which the app keeps its Box logins. To read the Dropbox logins that earlier versions of the library stored, pass the app's keychain service followed by `.dropbox.authv2`. Google Drive ignores it.
	 - Throws: `OAuthTokenStoreError.invalidLockDirectory` if `tokenLockDirectory` isn't a file URL.
	 */
	public static func keychain(accessGroup: String?, tokenLockDirectory: URL, services: [OAuthProvider: String] = [:]) throws -> OAuthPersistence {
		return try OAuthPersistence(storage: KeychainOAuthTokenStorage(accessGroup: accessGroup, services: services), tokenLockDirectory: tokenLockDirectory)
	}

	/**
	 Keeps the logins in the given storage, e.g., for another kind of persistence or for tests.

	 - Throws: `OAuthTokenStoreError.invalidLockDirectory` if `tokenLockDirectory` isn't a file URL.
	 */
	public static func custom(storage: any OAuthTokenStorage, tokenLockDirectory: URL) throws -> OAuthPersistence {
		return try OAuthPersistence(storage: storage, tokenLockDirectory: tokenLockDirectory)
	}
}
