//
//  DropboxCredentialMock.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 04.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

enum DropboxCredentialMock {
	/**
	 Creates a credential over an in-memory login with the test account's refresh token. Its access token has expired, so the first request refreshes it.

	 Deauthenticating it doesn't revoke the token, so that no test can revoke the refresh token of the test account.
	 */
	static func generateAuthorizedCredential(userID: String = "IntegrationTest") throws -> DropboxCredential {
		let storage = MemoryOAuthTokenStorage()
		try storage.save(OAuthTokenEncoding.encode(OAuthToken(accessToken: "", refreshToken: IntegrationTestSecrets.dropboxRefreshToken, expiresAt: .distantPast)), for: OAuthAccountKey(provider: .dropbox, account: userID))
		let lockDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("DropboxTokenLocks", isDirectory: true)
		let oauth = try OAuthPersistence.custom(storage: storage, tokenLockDirectory: lockDirectory)
		let endpoint = DropboxOAuthEndpoint(appKey: IntegrationTestSecrets.dropboxAppKey)
		let tokenSource = StoredOAuthTokenSource(provider: .dropbox, account: userID, persistence: oauth, legacyDecoder: DropboxLegacyToken.decode, refresher: { token in
			try await endpoint.refresh(token)
		}, revoke: { _ in })
		return DropboxCredential(userID: userID, tokenSource: tokenSource)
	}
}
