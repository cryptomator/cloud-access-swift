//
//  MicrosoftGraphCredentialMock.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 20.05.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
@testable import CryptomatorCloudAccessCore

extension MicrosoftGraphCredential {
	static func oneDriveIntegrationTest() throws -> MicrosoftGraphCredential {
		return try MicrosoftGraphCredential(identifier: "IntegrationTests", scopes: MicrosoftGraphType.oneDrive.scopes, tokenSource: oneDriveIntegrationTestTokenSource(), clientApplication: MSALPublicClientApplicationStub())
	}

	static func oneDriveIntegrationTestInvalid() -> MicrosoftGraphCredential {
		return MicrosoftGraphCredential(identifier: "IntegrationTests-Invalid", scopes: MicrosoftGraphType.oneDrive.scopes, tokenSource: StaticOAuthTokenSource(token: "InvalidToken"), clientApplication: MSALPublicClientApplicationStub())
	}

	/// A token source over an in-memory login with the test account's refresh token. Its access token has expired, so the first request refreshes it.
	private static func oneDriveIntegrationTestTokenSource() throws -> StoredOAuthTokenSource {
		let account = "IntegrationTest"
		let storage = MemoryOAuthTokenStorage()
		try storage.save(OAuthTokenEncoding.encode(OAuthToken(accessToken: "", refreshToken: IntegrationTestSecrets.microsoftGraphRefreshToken, expiresAt: .distantPast)), for: OAuthAccountKey(provider: .microsoftGraph, account: account))
		let lockDirectory = FileManager.default.temporaryDirectory.appending(component: "MicrosoftGraphTokenLocks", directoryHint: .isDirectory)
		let oauth = try OAuthPersistence.custom(storage: storage, tokenLockDirectory: lockDirectory)
		let clientID = try IntegrationTestSecrets.microsoftGraphClientId
		let redirectURI = try IntegrationTestSecrets.microsoftGraphRedirectUri
		let session = SplitURLSession(configuration: HTTPClientSupport.tokenEndpointConfiguration())
		return StoredOAuthTokenSource(provider: .microsoftGraph, account: account, persistence: oauth, legacyDecoder: { _ in
			throw CocoaError(.coderReadCorrupt)
		}, refresher: { token in
			guard let refreshToken = token.refreshToken else {
				throw CloudProviderError.unauthorized
			}
			let body = try await OAuthTokenEndpoint.post([
				("client_id", clientID),
				("scope", "https://graph.microsoft.com/Files.ReadWrite"),
				("refresh_token", refreshToken),
				("redirect_uri", redirectURI),
				("grant_type", "refresh_token")
			], host: "login.microsoftonline.com", path: "/common/oauth2/v2.0/token", on: session)
			return try JSONDecoder().decode(OAuthTokenResponse.self, from: body).token(now: Date(), fallbackRefreshToken: refreshToken)
		}, revoke: { _ in })
	}
}

private extension OAuthProvider {
	static let microsoftGraph = OAuthProvider(rawValue: "microsoftgraph")
}
