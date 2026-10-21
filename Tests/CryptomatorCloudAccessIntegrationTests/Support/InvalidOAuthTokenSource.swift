//
//  InvalidOAuthTokenSource.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

/// Always hands out an invalid token, so that every request ends in `CloudProviderError.unauthorized`.
struct InvalidOAuthTokenSource: OAuthTokenSource {
	func accessToken() async throws -> String {
		return "invalid"
	}

	func refresh(rejecting accessToken: String) async throws -> String {
		return "invalid"
	}

	func storedUsername() throws -> String? {
		return nil
	}

	func updateUsername(_ username: String) async throws {}

	func deauthenticate() async throws {}
}
