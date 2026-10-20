//
//  BoxCredentialMock.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Majid Achhoud on 15.04.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

extension BoxCredential {
	static func integrationTest() -> BoxCredential {
		return BoxCredential(userID: "IntegrationTest", tokenSource: BoxCCGTokenSource())
	}

	static func integrationTestInvalid() -> BoxCredential {
		return BoxCredential(userID: "IntegrationTest-Invalid", tokenSource: BoxInvalidTokenSource())
	}
}

/// Gets the tokens of the test enterprise's service account with Box's client credentials grant, so that the tests need no stored login. Concurrent requests for a new token share one token request.
actor BoxCCGTokenSource: BoxTokenSource {
	private var token: String?
	private var tokenRequest: Task<String, Error>?

	func accessToken() async throws -> String {
		if let token {
			return token
		}
		return try await requestToken()
	}

	func refresh(rejecting accessToken: String) async throws -> String {
		if let token, token != accessToken {
			return token
		}
		token = nil
		return try await requestToken()
	}

	func deauthenticate() async throws {
		token = nil
	}

	private func requestToken() async throws -> String {
		if let tokenRequest {
			return try await tokenRequest.value
		}
		let tokenRequest = Task {
			try await BoxCCGTokenSource.fetchToken()
		}
		self.tokenRequest = tokenRequest
		defer {
			self.tokenRequest = nil
		}
		let token = try await tokenRequest.value
		self.token = token
		return token
	}

	/// - Throws: `BoxError.apiError` for an unsuccessful response, so that a server error counts as transient.
	private static func fetchToken() async throws -> String {
		let endpoint = BoxOAuthEndpoint(clientId: IntegrationTestSecrets.boxClientId, clientSecret: IntegrationTestSecrets.boxClientSecret)
		return try await endpoint.token(for: [("grant_type", "client_credentials"), ("box_subject_type", "enterprise"), ("box_subject_id", IntegrationTestSecrets.boxEnterpriseId)]).accessToken
	}
}

/// Always sends an invalid token, so that every request ends in `CloudProviderError.unauthorized`.
struct BoxInvalidTokenSource: BoxTokenSource {
	func accessToken() async throws -> String {
		return "invalid"
	}

	func refresh(rejecting accessToken: String) async throws -> String {
		return "invalid"
	}

	func deauthenticate() async throws {}
}
