//
//  GoogleDriveAuthenticatorMock.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 02.10.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

enum GoogleDriveAuthenticatorMock {
	/// Creates a credential over an in-memory login with the test account's refresh token. Its access token has expired, so the first request refreshes it.
	static func generateAuthorizedCredential(withRefreshToken refreshToken: String, tokenUID: String) throws -> GoogleDriveCredential {
		let storage = MemoryOAuthTokenStorage()
		try storage.save(OAuthTokenEncoding.encode(OAuthToken(accessToken: "", refreshToken: refreshToken, expiresAt: .distantPast)), for: OAuthAccountKey(provider: .googleDrive, account: tokenUID))
		let lockDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("GoogleDriveTokenLocks", isDirectory: true)
		let oauth = try OAuthPersistence.custom(storage: storage, tokenLockDirectory: lockDirectory)
		let endpoint = GoogleDriveOAuthEndpoint(clientID: IntegrationTestSecrets.googleDriveClientId)
		return GoogleDriveCredential(userID: tokenUID, tokenSource: GoogleDriveCredential.makeTokenSource(userID: tokenUID, oauth: oauth, endpoint: endpoint))
	}
}
