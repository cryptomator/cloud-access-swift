//
//  BoxOAuthEndpointTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct BoxOAuthEndpointTests {
		private static let now = Date(timeIntervalSince1970: 1_792_000_000)
		private static let tokenResponse = #"{"access_token":"SECRET-ACCESS","expires_in":3600,"token_type":"bearer","refresh_token":"SECRET-NEW-REFRESH","restricted_to":[]}"#

		init() {
			URLProtocolMock.requestHandler = []
		}

		@Test
		func refreshPostsRefreshGrantAndMapsToken() async throws {
			let sentRequest = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: BoxOAuthEndpointTests.tokenResponse, onRequest: { request in
				sentRequest.withLock { $0 = request }
			})]

			let token = try await BoxOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: "SECRET-REFRESH", expiresAt: nil))

			#expect(OAuthToken(accessToken: "SECRET-ACCESS", refreshToken: "SECRET-NEW-REFRESH", expiresAt: BoxOAuthEndpointTests.now.addingTimeInterval(3600)) == token)
			let request = try #require(sentRequest.withLock { $0 })
			#expect(request.httpMethod == "POST")
			#expect(request.url?.absoluteString == "https://api.box.com/oauth2/token")
			#expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
			#expect(URLProtocolMock.formParameters(of: request) == ["grant_type": "refresh_token", "refresh_token": "SECRET-REFRESH", "client_id": "CLIENT-ID", "client_secret": "SECRET-CLIENT"])
		}

		@Test
		func revokePostsAccessToken() async throws {
			let sentRequest = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(onRequest: { request in
				sentRequest.withLock { $0 = request }
			})]

			try await BoxOAuthEndpoint.mocked().revoke(OAuthToken(accessToken: "SECRET-ACCESS", refreshToken: "SECRET-REFRESH", expiresAt: nil))

			let request = try #require(sentRequest.withLock { $0 })
			#expect(request.url?.absoluteString == "https://api.box.com/oauth2/revoke")
			#expect(URLProtocolMock.formParameters(of: request) == ["client_id": "CLIENT-ID", "client_secret": "SECRET-CLIENT", "token": "SECRET-ACCESS"])
		}
	}
}

extension BoxOAuthEndpoint {
	static func mocked() -> BoxOAuthEndpoint {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		return BoxOAuthEndpoint(clientID: "CLIENT-ID", clientSecret: "SECRET-CLIENT", configuration: configuration, now: { Date(timeIntervalSince1970: 1_792_000_000) })
	}
}
