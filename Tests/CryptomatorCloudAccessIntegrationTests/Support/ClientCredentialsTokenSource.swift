//
//  ClientCredentialsTokenSource.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 19.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
@testable import CryptomatorCloudAccessCore

/// Gets its tokens with a client credentials grant, so that the tests need no stored login. Concurrent requests for a new token share one token request.
actor ClientCredentialsTokenSource: OAuthTokenSource {
	private let fetchToken: @Sendable () async throws -> String
	private var token: String?
	private var tokenRequest: Task<String, Error>?

	init(fetchToken: @escaping @Sendable () async throws -> String) {
		self.fetchToken = fetchToken
	}

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

	nonisolated func storedUsername() throws -> String? {
		return nil
	}

	nonisolated func hasStoredToken() throws -> Bool {
		return false
	}

	func updateUsername(_ username: String) async throws {}

	func deauthenticate() async throws {
		token = nil
	}

	private func requestToken() async throws -> String {
		if let tokenRequest {
			return try await tokenRequest.value
		}
		let tokenRequest = Task {
			try await fetchToken()
		}
		self.tokenRequest = tokenRequest
		defer {
			self.tokenRequest = nil
		}
		let token = try await tokenRequest.value
		self.token = token
		return token
	}
}
