//
//  OAuthTokenStorage.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 The app's persistent storage of the OAuth tokens of a provider, e.g., one keychain service with one item per account.

 The library decides what the stored bytes contain. The storage keeps them as they are and must hold to this contract:
 - `load(forAccount:)` returns `nil` only if no item exists for the account, and throws for any other failure, e.g., a keychain that is locked.
 - Nothing is cached: every `load(forAccount:)` reads the persisted bytes, because other processes write them, too.
 - `save(_:forAccount:)` returns after the write completed. It replaces an existing item in place.
 - One storage object is one persistence namespace. Every process and every instance that uses the same items must pass the same token lock directory, e.g., to `BoxSetup`. The lock in it serializes token refreshes across processes.
 */
public protocol OAuthTokenStorage: Sendable {
	func load(forAccount account: String) throws -> Data?
	func save(_ data: Data, forAccount account: String) throws
	func delete(forAccount account: String) throws
}
