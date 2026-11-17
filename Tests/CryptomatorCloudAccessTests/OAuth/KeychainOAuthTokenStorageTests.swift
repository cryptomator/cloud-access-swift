//
//  KeychainOAuthTokenStorageTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Security
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct KeychainOAuthTokenStorageTests {
		private static let googleKey = OAuthAccountKey(provider: .googleDrive, account: "112233")
		private static let boxKey = OAuthAccountKey(provider: .box, account: "USER-ID")

		@Test
		func loadReturnsNilOnlyForMissingItem() throws {
			let keychain = KeychainRecorder(copyMatchingStatus: errSecItemNotFound)

			#expect(try keychain.storage().load(KeychainOAuthTokenStorageTests.googleKey) == nil)

			keychain.copyMatchingStatus = errSecInteractionNotAllowed

			#expect(throws: OAuthTokenStoreError.keychain(status: errSecInteractionNotAllowed)) { try keychain.storage().load(KeychainOAuthTokenStorageTests.googleKey) }

			keychain.copyMatchingStatus = errSecSuccess

			#expect(try Data("stored".utf8) == keychain.storage().load(KeychainOAuthTokenStorageTests.googleKey))
			let query = try #require(keychain.calls.last?.query)
			#expect((query[kSecReturnData as String] as? Bool) == true)
			#expect((kSecMatchLimitOne as String) == (query[kSecMatchLimit as String] as? String))
		}

		@Test
		func saveUpdatesItemAndAddsItOnlyIfMissing() throws {
			let keychain = KeychainRecorder(updateStatus: errSecSuccess)

			try keychain.storage().save(Data("new".utf8), for: KeychainOAuthTokenStorageTests.googleKey)

			#expect(keychain.calls.map(\.operation) == ["update"])
			#expect(Data("new".utf8) == (keychain.calls.first?.attributes?[kSecValueData as String] as? Data))

			keychain.reset(updateStatus: errSecItemNotFound)
			try keychain.storage().save(Data("new".utf8), for: KeychainOAuthTokenStorageTests.googleKey)

			#expect(keychain.calls.map(\.operation) == ["update", "add"])
			let added = try #require(keychain.calls.last?.query)
			#expect(Data("new".utf8) == (added[kSecValueData as String] as? Data))
			#expect((kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String) == (added[kSecAttrAccessible as String] as? String))

			keychain.reset(updateStatus: errSecInteractionNotAllowed)

			#expect(throws: OAuthTokenStoreError.keychain(status: errSecInteractionNotAllowed)) { try keychain.storage().save(Data("new".utf8), for: KeychainOAuthTokenStorageTests.googleKey) }
			#expect(keychain.calls.map(\.operation) == ["update"])

			keychain.reset(updateStatus: errSecItemNotFound, addStatus: errSecMissingEntitlement)

			#expect(throws: OAuthTokenStoreError.keychain(status: errSecMissingEntitlement)) { try keychain.storage().save(Data("new".utf8), for: KeychainOAuthTokenStorageTests.googleKey) }
		}

		@Test
		func deleteOfMissingItemSucceeds() throws {
			let keychain = KeychainRecorder(deleteStatus: errSecItemNotFound)

			try keychain.storage().delete(KeychainOAuthTokenStorageTests.googleKey)

			keychain.reset(deleteStatus: errSecInteractionNotAllowed)
			#expect(throws: (any Error).self) { try keychain.storage().delete(KeychainOAuthTokenStorageTests.googleKey) }
		}

		@Test
		func onlyAddSetsAccessibility() throws {
			let keychain = KeychainRecorder(copyMatchingStatus: errSecItemNotFound, updateStatus: errSecItemNotFound)
			let storage = keychain.storage()

			_ = try storage.load(KeychainOAuthTokenStorageTests.googleKey)
			try storage.save(Data("new".utf8), for: KeychainOAuthTokenStorageTests.googleKey)
			try storage.delete(KeychainOAuthTokenStorageTests.googleKey)

			#expect(keychain.calls.map(\.operation) == ["copyMatching", "update", "add", "delete"])
			for call in keychain.calls {
				#expect((call.operation == "add") == (call.query[kSecAttrAccessible as String] != nil), "\(call.operation)")
				#expect(call.attributes?[kSecAttrAccessible as String] == nil, "\(call.operation)")
			}
		}

		@Test
		func itemLocations() throws {
			let keychain = KeychainRecorder(copyMatchingStatus: errSecItemNotFound)

			_ = try keychain.storage(services: [.box: "org.cryptomator.ios.box.auth", .googleDrive: "ignored"]).load(KeychainOAuthTokenStorageTests.googleKey)
			_ = try keychain.storage(services: [.box: "org.cryptomator.ios.box.auth"]).load(KeychainOAuthTokenStorageTests.boxKey)
			_ = try keychain.storage().load(KeychainOAuthTokenStorageTests.boxKey)
			_ = try keychain.storage(accessGroup: "TEAM.org.cryptomator").load(KeychainOAuthTokenStorageTests.boxKey)

			let queries = keychain.calls.map(\.query)
			#expect(queries.map { $0[kSecAttrService as String] as? String } == ["GoogleDriveAuth112233", "org.cryptomator.ios.box.auth", "CryptomatorCloudAccess.OAuth.box", "CryptomatorCloudAccess.OAuth.box"])
			#expect(queries.map { $0[kSecAttrAccount as String] as? String } == ["OAuth", "USER-ID", "USER-ID", "USER-ID"])
			#expect(queries.map { $0[kSecAttrAccessGroup as String] as? String } == [nil, nil, nil, "TEAM.org.cryptomator"])
			for query in queries {
				#expect((kSecClassGenericPassword as String) == (query[kSecClass as String] as? String))
				#expect((query[kSecUseDataProtectionKeychain as String] as? Bool) == true)
			}
		}
	}
}

/// Records the keychain calls of a `KeychainOAuthTokenStorage` and answers them with the given statuses.
///
/// `@unchecked Sendable`: the recorded queries aren't `Sendable` dictionaries, but they hold only immutable values, and all state is behind the lock.
private final class KeychainRecorder: @unchecked Sendable {
	struct Call {
		let operation: String
		let query: [String: Any]
		let attributes: [String: Any]?
	}

	private struct State {
		var copyMatchingStatus: OSStatus
		var updateStatus: OSStatus
		var deleteStatus: OSStatus
		var addStatus = errSecSuccess
		var calls = [Call]()
	}

	private let state: OSAllocatedUnfairLock<State>

	init(copyMatchingStatus: OSStatus = errSecSuccess, updateStatus: OSStatus = errSecSuccess, deleteStatus: OSStatus = errSecSuccess) {
		self.state = OSAllocatedUnfairLock(uncheckedState: State(copyMatchingStatus: copyMatchingStatus, updateStatus: updateStatus, deleteStatus: deleteStatus))
	}

	var calls: [Call] {
		return state.withLockUnchecked { $0.calls }
	}

	var copyMatchingStatus: OSStatus {
		get { state.withLockUnchecked { $0.copyMatchingStatus } }
		set { state.withLockUnchecked { $0.copyMatchingStatus = newValue } }
	}

	func reset(updateStatus: OSStatus = errSecSuccess, deleteStatus: OSStatus = errSecSuccess, addStatus: OSStatus = errSecSuccess) {
		state.withLockUnchecked { state in
			state.calls = []
			state.updateStatus = updateStatus
			state.deleteStatus = deleteStatus
			state.addStatus = addStatus
		}
	}

	func storage(accessGroup: String? = nil, services: [OAuthProvider: String] = [:]) -> KeychainOAuthTokenStorage {
		let operations = KeychainOperations(copyMatching: { query in
			let status = self.record(Call(operation: "copyMatching", query: query, attributes: nil)) { $0.copyMatchingStatus }
			return (status, status == errSecSuccess ? Data("stored".utf8) : nil)
		}, add: { attributes in
			self.record(Call(operation: "add", query: attributes, attributes: nil)) { $0.addStatus }
		}, update: { query, attributes in
			self.record(Call(operation: "update", query: query, attributes: attributes)) { $0.updateStatus }
		}, delete: { query in
			self.record(Call(operation: "delete", query: query, attributes: nil)) { $0.deleteStatus }
		})
		return KeychainOAuthTokenStorage(accessGroup: accessGroup, services: services, operations: operations)
	}

	private func record(_ call: Call, status: (State) -> OSStatus) -> OSStatus {
		return state.withLockUnchecked { state in
			state.calls.append(call)
			return status(state)
		}
	}
}
