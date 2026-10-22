//
//  MemoryOAuthTokenStorage.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

/// Keeps the logins of the integration tests in memory, so that no test touches the keychain.
final class MemoryOAuthTokenStorage: OAuthTokenStorage {
	private let items = OSAllocatedUnfairLock(initialState: [OAuthAccountKey: Data]())

	func load(_ key: OAuthAccountKey) throws -> Data? {
		return items.withLock { $0[key] }
	}

	func save(_ data: Data, for key: OAuthAccountKey) throws {
		items.withLock { $0[key] = data }
	}

	func delete(_ key: OAuthAccountKey) throws {
		_ = items.withLock { $0.removeValue(forKey: key) }
	}
}
