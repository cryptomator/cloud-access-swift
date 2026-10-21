//
//  GoogleDriveCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 22.09.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

@preconcurrency import AppAuthCore
import Foundation

public enum GoogleDriveCredentialError: Error {
	case noUsername
	case missingUserID
	/// `GoogleDriveSetup.constants` isn't set.
	case missingSetup
}

/// The login of a Google account, which `GoogleDriveSetup.constants.oauth` keeps under the user ID, the `sub` of the login's ID token. Persist the user ID to re-create the credential later.
public final class GoogleDriveCredential: Sendable {
	public let userID: String
	let tokenSource: any OAuthTokenSource

	init(userID: String, tokenSource: any OAuthTokenSource) {
		self.userID = userID
		self.tokenSource = tokenSource
	}

	/**
	 Creates the credential of a login that `GoogleDriveAuthenticator` stored, or that GTMAppAuth stored for this user ID. It reads nothing until the first request.

	 - Throws: `GoogleDriveCredentialError.missingUserID` for an empty user ID, and `GoogleDriveCredentialError.missingSetup` if `GoogleDriveSetup.constants` isn't set.
	 */
	public convenience init(userID: String) throws {
		guard !userID.isEmpty else {
			throw GoogleDriveCredentialError.missingUserID
		}
		guard let setup = GoogleDriveSetup.constants else {
			throw GoogleDriveCredentialError.missingSetup
		}
		self.init(userID: userID, tokenSource: GoogleDriveCredential.makeTokenSource(userID: userID, oauth: setup.oauth, endpoint: GoogleDriveOAuthEndpoint(setup: setup)))
	}

	/// Deauthenticating the token source only deletes the stored token, because Google revokes a token for every device and client of the app's project.
	static func makeTokenSource(userID: String, oauth: OAuthPersistence, endpoint: GoogleDriveOAuthEndpoint, assertion: ProcessExecutionAssertion = ProcessExecutionAssertion()) -> StoredOAuthTokenSource {
		return StoredOAuthTokenSource(provider: .googleDrive, account: userID, persistence: oauth, legacyDecoder: GoogleDriveLegacyToken.decode, refresher: { token in
			try await endpoint.refresh(token)
		}, revoke: { _ in }, assertion: assertion)
	}

	/**
	 Stores the token of a login with the account's email, under the `sub` of its ID token.

	 - Parameter idToken: The ID token of the token response, which names the account.
	 - Throws: `GoogleDriveCredentialError.missingSetup` if `GoogleDriveSetup.constants` isn't set, `GoogleDriveCredentialError.missingUserID` if the ID token can't be read or has no `sub`, and otherwise what saving the token throws.
	 */
	@concurrent
	public static func completeAuthentication(accessToken: String, refreshToken: String, expiresAt: Date?, idToken: String) async throws -> GoogleDriveCredential {
		guard let setup = GoogleDriveSetup.constants else {
			throw GoogleDriveCredentialError.missingSetup
		}
		let endpoint = GoogleDriveOAuthEndpoint(setup: setup)
		return try await completeAuthentication(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, idToken: idToken, makeTokenSource: { userID in
			makeTokenSource(userID: userID, oauth: setup.oauth, endpoint: endpoint)
		})
	}

	static func completeAuthentication(accessToken: String, refreshToken: String, expiresAt: Date?, idToken: String, makeTokenSource: (_ userID: String) -> StoredOAuthTokenSource) async throws -> GoogleDriveCredential {
		guard let token = OIDIDToken(idTokenString: idToken), !token.subject.isEmpty else {
			throw GoogleDriveCredentialError.missingUserID
		}
		let tokenSource = makeTokenSource(token.subject)
		try await tokenSource.replace(with: OAuthToken(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, username: token.claims["email"] as? String))
		return GoogleDriveCredential(userID: token.subject, tokenSource: tokenSource)
	}

	/// Returns the account's email that was stored with the login, without a request.
	public func cachedUsername() throws -> String? {
		return try tokenSource.storedUsername()
	}

	/// Asks Google for the account's email, and stores it with the login if it changed.
	@concurrent
	public func getUsername() async throws -> String {
		return try await getUsername(client: .foreground(tokenSource: tokenSource))
	}

	func getUsername(client: GoogleDriveClient) async throws -> String {
		guard let email = try await client.about().user?.emailAddress else {
			throw GoogleDriveCredentialError.noUsername
		}
		await tokenSource.storeUsernameIfChanged(email)
		return email
	}

	/// Deletes the stored token without revoking it, so that the account stays signed in on the user's other devices and in other clients.
	@concurrent
	public func deauthenticate() async throws {
		try await tokenSource.deauthenticate()
	}
}
