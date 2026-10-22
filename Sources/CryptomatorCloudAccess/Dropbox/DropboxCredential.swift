//
//  DropboxCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 23.09.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum DropboxCredentialErrors: Error {
	case noUsername
	case missingUserID
	/// `DropboxSetup.constants` isn't set.
	case missingSetup
}

/// The login of a Dropbox account, which `DropboxSetup.constants.oauth` keeps under the user ID, the account's `uid`. Persist the user ID to re-create the credential later.
public final class DropboxCredential: Sendable {
	public let userID: String
	let tokenSource: any OAuthTokenSource

	init(userID: String, tokenSource: any OAuthTokenSource) {
		self.userID = userID
		self.tokenSource = tokenSource
	}

	/**
	 Creates the credential of a login that `DropboxAuthenticator` or a Dropbox SDK stored. It reads nothing until the first request.

	 - Throws: `DropboxCredentialErrors.missingUserID` for an empty user ID, and `DropboxCredentialErrors.missingSetup` if `DropboxSetup.constants` isn't set.
	 */
	public convenience init(userID: String) throws {
		guard !userID.isEmpty else {
			throw DropboxCredentialErrors.missingUserID
		}
		guard let setup = DropboxSetup.constants else {
			throw DropboxCredentialErrors.missingSetup
		}
		self.init(userID: userID, tokenSource: DropboxCredential.makeTokenSource(userID: userID, oauth: setup.oauth, endpoint: DropboxOAuthEndpoint(setup: setup)))
	}

	static func makeTokenSource(userID: String, oauth: OAuthPersistence, endpoint: DropboxOAuthEndpoint, assertion: ProcessExecutionAssertion = ProcessExecutionAssertion()) -> StoredOAuthTokenSource {
		return StoredOAuthTokenSource(provider: .dropbox, account: userID, persistence: oauth, legacyDecoder: DropboxLegacyToken.decode, refresher: { token in
			try await endpoint.refresh(token)
		}, revoke: { token in
			try await endpoint.revoke(token)
		}, assertion: assertion)
	}

	/**
	 Exchanges the authorization code of a login for a token, and stores the token with the account's email under its `uid`.

	 Nothing is stored if the exchange or the account request fails, or the task was cancelled meanwhile.

	 - Parameter codeVerifier: The PKCE code verifier of the login's authorize request.
	 - Throws: `DropboxCredentialErrors.missingSetup` if `DropboxSetup.constants` isn't set, `DropboxCredentialErrors.missingUserID` if Dropbox returned no `uid`, and otherwise what the code exchange, the account request or saving the token throws.
	 */
	@concurrent
	public static func completeAuthentication(authorizationCode: String, codeVerifier: String) async throws -> DropboxCredential {
		guard let setup = DropboxSetup.constants else {
			throw DropboxCredentialErrors.missingSetup
		}
		let endpoint = DropboxOAuthEndpoint(setup: setup)
		return try await completeAuthentication(authorizationCode: authorizationCode, codeVerifier: codeVerifier, endpoint: endpoint, makeClient: { DropboxClient.foreground(tokenSource: $0) }, makeTokenSource: { userID in
			makeTokenSource(userID: userID, oauth: setup.oauth, endpoint: endpoint)
		})
	}

	static func completeAuthentication(authorizationCode: String, codeVerifier: String, endpoint: DropboxOAuthEndpoint, makeClient: (any OAuthTokenSource) -> DropboxClient, makeTokenSource: (_ userID: String) -> StoredOAuthTokenSource) async throws -> DropboxCredential {
		let (token, userID) = try await endpoint.exchange(code: authorizationCode, codeVerifier: codeVerifier)
		let account = try await makeClient(StaticOAuthTokenSource(token: token.accessToken)).currentAccount()
		// An account request that was under way when the task was cancelled still completes.
		try Task.checkCancellation()
		let tokenSource = makeTokenSource(userID)
		try await tokenSource.replace(with: OAuthToken(accessToken: token.accessToken, refreshToken: token.refreshToken, expiresAt: token.expiresAt, username: account.email))
		return DropboxCredential(userID: userID, tokenSource: tokenSource)
	}

	/**
	 Returns the account's email that was stored with the login, without a request.

	 - Returns: `nil` if no email was stored yet, e.g., for a login that a Dropbox SDK stored, until `getUsername()` stores one.
	 */
	public func cachedUsername() throws -> String? {
		return try tokenSource.storedUsername()
	}

	/// Asks Dropbox for the account's email, and stores it with the login if it changed.
	@concurrent
	public func getUsername() async throws -> String {
		return try await getUsername(client: .foreground(tokenSource: tokenSource))
	}

	func getUsername(client: DropboxClient) async throws -> String {
		guard let email = try await client.currentAccount().email, !email.isEmpty else {
			throw DropboxCredentialErrors.noUsername
		}
		await tokenSource.storeUsernameIfChanged(email)
		return email
	}

	/// Deletes the stored token and then revokes the tokens of this login only, so that the account stays signed in on the user's other devices. The token is deleted also if the revocation, or the refresh before it, fails.
	@concurrent
	public func deauthenticate() async throws {
		try await tokenSource.deauthenticate()
	}
}
