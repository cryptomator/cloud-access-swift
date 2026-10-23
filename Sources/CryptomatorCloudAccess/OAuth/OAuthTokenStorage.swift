//
//  OAuthTokenStorage.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// A provider whose OAuth logins the library keeps. Its raw value names the provider in the persisted locations of the logins, e.g., keychain services.
public struct OAuthProvider: Hashable, Sendable {
	public static let box = OAuthProvider(rawValue: "box")
	public static let dropbox = OAuthProvider(rawValue: "dropbox")
	public static let googleDrive = OAuthProvider(rawValue: "googledrive")
	public static let pCloud = OAuthProvider(rawValue: "pcloud")

	public let rawValue: String
}

/// Identifies the login of one account at a provider.
public struct OAuthAccountKey: Hashable, Sendable {
	public let provider: OAuthProvider
	public let account: String

	public init(provider: OAuthProvider, account: String) {
		self.provider = provider
		self.account = account
	}
}

/**
 Persistent storage of OAuth tokens, e.g., one keychain item per account. Pass it to `OAuthPersistence.custom(storage:tokenLockDirectory:)` to keep the tokens elsewhere than in the library's keychain storage.

 The library decides what the stored bytes contain. The storage keeps them as they are and must hold to this contract:
 - `load(_:)` returns `nil` only if no item exists for the key, and throws for any other failure, e.g., a keychain that is locked.
 - Nothing is cached: every `load(_:)` reads the persisted bytes, because other processes write them, too.
 - `save(_:for:)` returns after the write completed. It replaces an existing item in place.
 - `save(_:for:)` and `delete(_:)` return promptly, e.g., without waiting for user interaction. When the process's background time runs out, the library releases the lock only once a running write returns, and iOS may terminate a process that still holds it.
 - One storage object is one persistence namespace. Every process and every instance that uses the same items must pass the same token lock directory. The lock in it serializes token refreshes across processes.
 */
public protocol OAuthTokenStorage: Sendable {
	func load(_ key: OAuthAccountKey) throws -> Data?
	func save(_ data: Data, for key: OAuthAccountKey) throws
	func delete(_ key: OAuthAccountKey) throws
}
