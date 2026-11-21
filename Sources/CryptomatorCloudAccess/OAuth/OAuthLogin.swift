//
//  OAuthLogin.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 21.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

enum OAuthLogin {
	/**
	 Stores the token of a new login under the user ID, replacing any stored token, and returns the login's token source.

	 A cancellation stores nothing if it is observed before the replacement starts. It is checked here, after any request that read the account, because such a request completes even if the task was cancelled meanwhile. A later cancellation doesn't reach the replacement, which runs in the task of its execution assertion (`ExecutionAssertion.perform`), so the token is saved anyway.
	 */
	static func store(_ token: OAuthToken, userID: String, makeTokenSource: (_ userID: String) -> StoredOAuthTokenSource) async throws -> StoredOAuthTokenSource {
		try Task.checkCancellation()
		let tokenSource = makeTokenSource(userID)
		try await tokenSource.replace(with: token)
		return tokenSource
	}
}
