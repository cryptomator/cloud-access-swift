//
//  OAuthTokenSource.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// Supplies the access token of the requests of an OAuth provider's client, and keeps the login's username.
protocol OAuthTokenSource: Sendable {
	func accessToken() async throws -> String
	/// Returns a token that replaces the rejected one.
	func refresh(rejecting accessToken: String) async throws -> String
	func storedUsername() throws -> String?
	func updateUsername(_ username: String) async throws
	func deauthenticate() async throws
}

extension OAuthTokenSource {
	/// Stores a username that differs from the stored one. A failure is only logged, because the username is just shown.
	func storeUsernameIfChanged(_ username: String) async {
		do {
			guard try storedUsername() != username else {
				return
			}
			try await updateUsername(username)
		} catch {
			CloudAccessDDLogDebug("OAuthTokenSource: storing the username failed with \(error)")
		}
	}
}

/// The token of a login that the `OAuthPersistence` keeps and `OAuthTokenStore` refreshes.
final class StoredOAuthTokenSource: OAuthTokenSource {
	private let store: OAuthTokenStore
	private let revoke: @Sendable (OAuthToken) async throws -> Void

	/**
	 - Parameter refresher: Sends the refresh grant of the given token once and returns the new token.
	 - Parameter revoke: Revokes the token of the login when it is deauthenticated, after it was deleted.
	 */
	init(provider: OAuthProvider, account: String, persistence: OAuthPersistence, legacyDecoder: @escaping @Sendable (Data) throws -> OAuthToken, refresher: @escaping @Sendable (OAuthToken) async throws -> OAuthToken, revoke: @escaping @Sendable (OAuthToken) async throws -> Void, assertion: ProcessExecutionAssertion = ProcessExecutionAssertion()) {
		self.store = OAuthTokenStore(provider: provider, account: account, persistence: persistence, legacyDecoder: legacyDecoder, refresher: refresher, assertion: assertion)
		self.revoke = revoke
	}

	func accessToken() async throws -> String {
		return try await store.accessToken()
	}

	func refresh(rejecting accessToken: String) async throws -> String {
		return try await store.refresh(rejecting: accessToken)
	}

	func storedUsername() throws -> String? {
		return try store.storedUsername()
	}

	func updateUsername(_ username: String) async throws {
		try await store.updateUsername(username)
	}

	func replace(with token: OAuthToken) async throws {
		try await store.replace(with: token)
	}

	func deauthenticate() async throws {
		try await store.delete(revoking: revoke)
	}
}

/// The token of a login that isn't stored yet, for the request that reads the account.
struct StaticOAuthTokenSource: OAuthTokenSource {
	let token: String

	func accessToken() async throws -> String {
		return token
	}

	func refresh(rejecting accessToken: String) async throws -> String {
		throw CloudProviderError.unauthorized
	}

	func storedUsername() throws -> String? {
		return nil
	}

	func updateUsername(_ username: String) async throws {}

	func deauthenticate() async throws {}
}
