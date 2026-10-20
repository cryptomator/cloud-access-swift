//
//  BoxCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 19.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum BoxCredentialErrors: Error {
	case noUsername
	case missingUserID
	/// `BoxSetup.constants` isn't set.
	case missingSetup
}

/// The login of a Box account, whose token the app's `OAuthTokenStorage` keeps under the user ID. Persist the user ID to re-create the credential later.
public final class BoxCredential: Sendable {
	public let userID: String
	let tokenSource: any BoxTokenSource

	init(userID: String, tokenSource: any BoxTokenSource) {
		self.userID = userID
		self.tokenSource = tokenSource
	}

	/**
	 Creates the credential of a login that `BoxAuthenticator` stored in `tokenStorage`. It reads nothing until the first request.

	 - Throws: `BoxCredentialErrors.missingUserID` for an empty user ID, and `BoxCredentialErrors.missingSetup` if `BoxSetup.constants` isn't set.
	 */
	public convenience init(userID: String, tokenStorage: any OAuthTokenStorage) throws {
		guard !userID.isEmpty else {
			throw BoxCredentialErrors.missingUserID
		}
		guard let setup = BoxSetup.constants else {
			throw BoxCredentialErrors.missingSetup
		}
		self.init(userID: userID, tokenSource: BoxOAuthTokenSource(userID: userID, tokenStorage: tokenStorage, lockDirectory: setup.tokenLockDirectory, endpoint: BoxOAuthEndpoint(setup: setup)))
	}

	/**
	 Exchanges the authorization code of a login for a token, and stores the token in `tokenStorage` under the user ID of the account.

	 - Throws: `BoxCredentialErrors.missingSetup` if `BoxSetup.constants` isn't set, `BoxCredentialErrors.missingUserID` if Box returned no user ID, and otherwise what the code exchange, the user request or saving the token throws.
	 */
	@concurrent
	public static func completeAuthentication(authorizationCode: String, tokenStorage: any OAuthTokenStorage) async throws -> BoxCredential {
		guard let setup = BoxSetup.constants else {
			throw BoxCredentialErrors.missingSetup
		}
		let endpoint = BoxOAuthEndpoint(setup: setup)
		return try await completeAuthentication(authorizationCode: authorizationCode, endpoint: endpoint, makeClient: { BoxClient.foreground(tokenSource: $0) }, makeTokenSource: { userID in
			BoxOAuthTokenSource(userID: userID, tokenStorage: tokenStorage, lockDirectory: setup.tokenLockDirectory, endpoint: endpoint)
		})
	}

	static func completeAuthentication(authorizationCode: String, endpoint: BoxOAuthEndpoint, makeClient: (any BoxTokenSource) -> BoxClient, makeTokenSource: (_ userID: String) -> BoxOAuthTokenSource) async throws -> BoxCredential {
		let token = try await endpoint.exchange(authorizationCode: authorizationCode)
		let user = try await makeClient(BoxStaticTokenSource(token: token.accessToken)).user()
		guard !user.id.isEmpty else {
			throw BoxCredentialErrors.missingUserID
		}
		let tokenSource = makeTokenSource(user.id)
		try await tokenSource.replace(with: token)
		return BoxCredential(userID: user.id, tokenSource: tokenSource)
	}

	@concurrent
	public func getUsername() async throws -> String {
		return try await getUsername(client: .foreground(tokenSource: tokenSource))
	}

	func getUsername(client: BoxClient) async throws -> String {
		guard let name = try await client.user().name else {
			throw BoxCredentialErrors.noUsername
		}
		return name
	}

	/// Deletes the stored token and revokes it. The token is deleted also if the revocation fails.
	@concurrent
	public func deauthenticate() async throws {
		try await tokenSource.deauthenticate()
	}
}
