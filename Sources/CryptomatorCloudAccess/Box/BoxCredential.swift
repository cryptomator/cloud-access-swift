//
//  BoxCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 19.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum BoxCredentialError: Error {
	case noUsername
	case missingUserID
}

/// The login of a Box account, which the `oauth` of its `BoxSetup` keeps under the user ID. Persist the user ID to re-create the credential later.
public final class BoxCredential: Sendable {
	public let userID: String
	let tokenSource: any OAuthTokenSource

	init(userID: String, tokenSource: any OAuthTokenSource) {
		self.userID = userID
		self.tokenSource = tokenSource
	}

	/**
	 Creates the credential of a login that `BoxAuthenticator` or the Box SDK stored. It reads nothing until the first request.

	 - Throws: `BoxCredentialError.missingUserID` for an empty user ID.
	 */
	public convenience init(userID: String, setup: BoxSetup) throws {
		guard !userID.isEmpty else {
			throw BoxCredentialError.missingUserID
		}
		self.init(userID: userID, tokenSource: BoxCredential.makeTokenSource(userID: userID, oauth: setup.oauth, endpoint: BoxOAuthEndpoint(setup: setup)))
	}

	static func makeTokenSource(userID: String, oauth: OAuthPersistence, endpoint: BoxOAuthEndpoint, assertion: ProcessExecutionAssertion = ProcessExecutionAssertion()) -> StoredOAuthTokenSource {
		return StoredOAuthTokenSource(provider: .box, account: userID, persistence: oauth, legacyDecoder: BoxLegacyToken.decode, refresher: { token in
			try await endpoint.refresh(token)
		}, revoke: { token in
			try await endpoint.revoke(token)
		}, assertion: assertion)
	}

	/**
	 Exchanges the authorization code of a login for a token, and stores the token with the account's name under its user ID.

	 Nothing is stored if the exchange or the user request fails, or the task was cancelled meanwhile.

	 - Throws: `BoxCredentialError.missingUserID` if Box returned no user ID, and otherwise what the code exchange, the user request or saving the token throws.
	 */
	@concurrent
	@_spi(Authentication) public static func completeAuthentication(authorizationCode: String, setup: BoxSetup) async throws -> BoxCredential {
		let endpoint = BoxOAuthEndpoint(setup: setup)
		return try await completeAuthentication(authorizationCode: authorizationCode, endpoint: endpoint, makeClient: { BoxClient.foreground(tokenSource: $0) }, makeTokenSource: { userID in
			makeTokenSource(userID: userID, oauth: setup.oauth, endpoint: endpoint)
		})
	}

	static func completeAuthentication(authorizationCode: String, endpoint: BoxOAuthEndpoint, makeClient: (any OAuthTokenSource) -> BoxClient, makeTokenSource: (_ userID: String) -> StoredOAuthTokenSource) async throws -> BoxCredential {
		let token = try await endpoint.exchange(authorizationCode: authorizationCode)
		let user = try await makeClient(StaticOAuthTokenSource(token: token.accessToken)).user()
		guard !user.id.isEmpty else {
			throw BoxCredentialError.missingUserID
		}
		// A user request that was under way when the task was cancelled still completes.
		try Task.checkCancellation()
		let tokenSource = makeTokenSource(user.id)
		try await tokenSource.replace(with: OAuthToken(accessToken: token.accessToken, refreshToken: token.refreshToken, expiresAt: token.expiresAt, username: user.name))
		return BoxCredential(userID: user.id, tokenSource: tokenSource)
	}

	/**
	 Returns the account's name that was stored with the login, without a request.

	 - Returns: `nil` if no name was stored yet, e.g., for a login that the Box SDK stored, until `getUsername()` stores one.
	 */
	public func cachedUsername() throws -> String? {
		return try tokenSource.storedUsername()
	}

	/// Asks Box for the account's name, and stores it with the login if it changed.
	@concurrent
	public func getUsername() async throws -> String {
		return try await getUsername(client: .foreground(tokenSource: tokenSource))
	}

	func getUsername(client: BoxClient) async throws -> String {
		guard let name = try await client.user().name else {
			throw BoxCredentialError.noUsername
		}
		await tokenSource.storeUsernameIfChanged(name)
		return name
	}

	/// Deletes the stored token and revokes it. The token is deleted also if the revocation fails.
	@concurrent
	public func deauthenticate() async throws {
		try await tokenSource.deauthenticate()
	}
}
