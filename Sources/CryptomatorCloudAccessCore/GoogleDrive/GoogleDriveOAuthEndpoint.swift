//
//  GoogleDriveOAuthEndpoint.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Sends the refresh grant to Google's token endpoint. An iOS client has no client secret.

 Its bodies carry the tokens, so they are never logged. Its timeouts bound how long a refresh holds the token lock.
 */
struct GoogleDriveOAuthEndpoint: Sendable {
	private let clientID: String
	private let session: SplitURLSession
	private let now: @Sendable () -> Date

	init(clientID: String, configuration: URLSessionConfiguration = HTTPClientSupport.tokenEndpointConfiguration(), now: @escaping @Sendable () -> Date = Date.init) {
		self.clientID = clientID
		self.session = SplitURLSession(configuration: configuration)
		self.now = now
	}

	init(setup: GoogleDriveSetup) {
		self.init(clientID: setup.clientID)
	}

	/**
	 Returns the refreshed token. Google usually leaves the refresh token out of the response, and then the refreshed token keeps the old one.

	 - Throws: `CloudProviderError.unauthorized` if the token has no refresh token or Google rejected it, and `OAuthTokenEndpointError` for any other unsuccessful response.
	 */
	func refresh(_ token: OAuthToken) async throws -> OAuthToken {
		guard let refreshToken = token.refreshToken else {
			throw CloudProviderError.unauthorized
		}
		let body = try await OAuthTokenEndpoint.post([("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientID)], host: "oauth2.googleapis.com", path: "/token", on: session)
		return try GoogleDriveJSON.decode(OAuthTokenResponse.self, from: body).token(now: now(), fallbackRefreshToken: refreshToken)
	}
}
