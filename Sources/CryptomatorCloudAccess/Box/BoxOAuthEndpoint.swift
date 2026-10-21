//
//  BoxOAuthEndpoint.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Sends the requests of Box's OAuth endpoints: the code exchange, the refresh grant and the revocation.

 Their bodies carry the client secret and the tokens, so they are never logged. Their timeouts bound how long a refresh holds the token lock.
 */
struct BoxOAuthEndpoint: Sendable {
	private let clientId: String
	private let clientSecret: String
	private let session: SplitURLSession
	private let now: @Sendable () -> Date

	init(clientId: String, clientSecret: String, configuration: URLSessionConfiguration = HTTPClientSupport.tokenEndpointConfiguration(), now: @escaping @Sendable () -> Date = Date.init) {
		self.clientId = clientId
		self.clientSecret = clientSecret
		self.session = SplitURLSession(configuration: configuration)
		self.now = now
	}

	init(setup: BoxSetup) {
		self.init(clientId: setup.clientId, clientSecret: setup.clientSecret)
	}

	func exchange(authorizationCode: String) async throws -> OAuthToken {
		return try await token(for: [("grant_type", "authorization_code"), ("code", authorizationCode)])
	}

	/// - Throws: `CloudProviderError.unauthorized` if the token has no refresh token, or Box rejected it.
	func refresh(_ token: OAuthToken) async throws -> OAuthToken {
		guard let refreshToken = token.refreshToken else {
			throw CloudProviderError.unauthorized
		}
		return try await self.token(for: [("grant_type", "refresh_token"), ("refresh_token", refreshToken)])
	}

	func revoke(_ token: OAuthToken) async throws {
		_ = try await OAuthTokenEndpoint.post([("client_id", clientId), ("client_secret", clientSecret), ("token", token.accessToken)], host: "api.box.com", path: "/oauth2/revoke", on: session)
	}

	func token(for grant: [(String, String)]) async throws -> OAuthToken {
		let body = try await OAuthTokenEndpoint.post(grant + [("client_id", clientId), ("client_secret", clientSecret)], host: "api.box.com", path: "/oauth2/token", on: session)
		return try BoxJSON.decode(OAuthTokenResponse.self, from: body).token(now: now())
	}
}
