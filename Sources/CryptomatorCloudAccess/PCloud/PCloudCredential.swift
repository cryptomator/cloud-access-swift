//
//  PCloudCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 15.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum PCloudCredentialError: Error {
	case missingUserID
}

/// The access token of a pCloud login and the host of the API that it is valid for.
struct PCloudLogin: Sendable, Equatable {
	let accessToken: String
	let apiHost: String
}

protocol PCloudTokenSource: Sendable {
	/// - Throws: `CloudProviderError.unauthorized` if no login is stored or it has no API host.
	func login() throws -> PCloudLogin
}

/// Reads the stored token on every request rather than a token that this process cached, because a pCloud token never expires and can't be revoked. A login that another process deleted, e.g., the app when the user signed out, thus ends at once in every process.
extension StoredOAuthTokenSource: PCloudTokenSource {
	func login() throws -> PCloudLogin {
		let token = try storedToken()
		guard let apiHost = token.apiHost else {
			throw CloudProviderError.unauthorized
		}
		return PCloudLogin(accessToken: token.accessToken, apiHost: apiHost)
	}
}

extension StaticOAuthTokenSource: PCloudTokenSource {
	func login() throws -> PCloudLogin {
		guard let apiHost else {
			throw CloudProviderError.unauthorized
		}
		return PCloudLogin(accessToken: token, apiHost: apiHost)
	}
}

/// The login of a pCloud account, which the `oauth` of its `PCloudSetup` keeps under the user ID. Persist the user ID to re-create the credential later.
public final class PCloudCredential: Sendable {
	private static let hostNameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")

	public let userID: String
	let tokenSource: any OAuthTokenSource & PCloudTokenSource

	init(userID: String, tokenSource: any OAuthTokenSource & PCloudTokenSource) {
		self.userID = userID
		self.tokenSource = tokenSource
	}

	/**
	 Creates the credential of a login that `PCloudAuthenticator` or the pCloud SDK stored. It reads nothing until the first request.

	 - Throws: `PCloudCredentialError.missingUserID` for an empty user ID.
	 */
	public convenience init(userID: String, setup: PCloudSetup) throws {
		guard !userID.isEmpty else {
			throw PCloudCredentialError.missingUserID
		}
		self.init(userID: userID, tokenSource: PCloudCredential.makeTokenSource(userID: userID, oauth: setup.oauth))
	}

	/// pCloud tokens have no refresh token, so the store never refreshes them, and pCloud offers no revocation, so `revoke` does nothing.
	static func makeTokenSource(userID: String, oauth: OAuthPersistence, assertion: ProcessExecutionAssertion = ProcessExecutionAssertion(), coordinator: OAuthTokenCoordinator = .shared) -> StoredOAuthTokenSource {
		return StoredOAuthTokenSource(provider: .pCloud, account: userID, persistence: oauth, legacyDecoder: PCloudLegacyToken.decode, refresher: { _ in
			throw CloudProviderError.unauthorized
		}, revoke: { _ in }, assertion: assertion, coordinator: coordinator)
	}

	/**
	 Stores the token of a login with the account's email under its user ID.

	 Nothing is stored if the account request fails, or the task was cancelled meanwhile.

	 - Parameter apiHostName: The host of the account's API, e.g., `eapi.pcloud.com`, which the login's redirect names.
	 - Throws: `PCloudCredentialError.missingUserID` for an empty user ID, `URLError(.badURL)` if `apiHostName` isn't a host name of pCloud, and otherwise what the account request or saving the token throws.
	 */
	@concurrent
	@_spi(Authentication) public static func completeAuthentication(accessToken: String, userID: String, apiHostName: String, setup: PCloudSetup) async throws -> PCloudCredential {
		return try await completeAuthentication(accessToken: accessToken, userID: userID, apiHostName: apiHostName, makeClient: { PCloudClient.foreground(tokenSource: $0) }, makeTokenSource: { userID in
			makeTokenSource(userID: userID, oauth: setup.oauth)
		})
	}

	static func completeAuthentication(accessToken: String, userID: String, apiHostName: String, makeClient: (StaticOAuthTokenSource) -> PCloudClient, makeTokenSource: (_ userID: String) -> StoredOAuthTokenSource) async throws -> PCloudCredential {
		guard !userID.isEmpty else {
			throw PCloudCredentialError.missingUserID
		}
		guard let apiHost = PCloudCredential.apiHost(apiHostName) else {
			throw URLError(.badURL)
		}
		let email = try await makeClient(StaticOAuthTokenSource(token: accessToken, apiHost: apiHost)).userInfoEmail()
		// An account request that was under way when the task was cancelled still completes.
		try Task.checkCancellation()
		let tokenSource = makeTokenSource(userID)
		try await tokenSource.replace(with: OAuthToken(accessToken: accessToken, refreshToken: nil, expiresAt: nil, username: email, apiHost: apiHost))
		return PCloudCredential(userID: userID, tokenSource: tokenSource)
	}

	/**
	 Returns the account's email that was stored with the login, without a request.

	 - Returns: `nil` if no email was stored yet, e.g., for a login that the pCloud SDK stored, until `getUsername()` stores one.
	 */
	public func cachedUsername() throws -> String? {
		return try tokenSource.storedUsername()
	}

	/// Asks pCloud for the account's email, and stores it with the login if it changed.
	@concurrent
	public func getUsername() async throws -> String {
		return try await getUsername(client: .foreground(tokenSource: tokenSource))
	}

	func getUsername(client: PCloudClient) async throws -> String {
		let email = try await client.userInfoEmail()
		await tokenSource.storeUsernameIfChanged(email)
		return email
	}

	/// Deletes the stored token. It stays valid at pCloud, which offers no revocation of an OAuth token.
	@concurrent
	public func deauthenticate() async throws {
		try await tokenSource.deauthenticate()
	}

	/// Returns the lowercased host if it is a bare host name in pCloud's domain, and `nil` otherwise. Rejecting a path, query, fragment, user info, port or IPv6 literal ensures that every request goes to that host.
	static func apiHost(_ hostName: String) -> String? {
		let hostName = hostName.lowercased()
		guard hostName == "pcloud.com" || hostName.hasSuffix(".pcloud.com"), hostName.unicodeScalars.allSatisfy(hostNameCharacters.contains), !hostName.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty) else {
			return nil
		}
		var components = URLComponents()
		components.scheme = "https"
		components.host = hostName
		return components.url?.host == hostName ? hostName : nil
	}
}
