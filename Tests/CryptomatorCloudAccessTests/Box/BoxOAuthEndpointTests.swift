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
		func tokenResponseOverMetadataLimitFails() async throws {
			URLProtocolMock.requestHandler = [{ request in
				(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(count: HTTPClientSupport.maxMetadataBodyLength + 1))
			}]

			let error = try await #require(throws: (any Error).self) { try await BoxOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: "RT", expiresAt: nil)) }
			guard case SplitURLSessionError.responseBodyTooLarge = error else {
				Issue.record("Unexpected error: \(error)")
				return
			}
		}

		@Test
		func invalidGrantIsUnauthorized() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 400, body: #"{"error":"invalid_grant","error_description":"Refresh token has expired"}"#)]

			await #expect(throws: CloudProviderError.unauthorized) { try await BoxOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: "RT", expiresAt: nil)) }
		}

		/// Only a rejected grant means that the user must log in again, so only it maps to `CloudProviderError.unauthorized`.
		@Test
		func otherFailuresAreNotUnauthorized() async throws {
			let cases = [
				TokenErrorCase(name: "invalid client", response: URLProtocolMock.handler(statusCode: 400, body: #"{"error":"invalid_client","error_description":"The client credentials are invalid"}"#), expectedError: OAuthTokenEndpointError.unsuccessfulResponse(statusCode: 400, error: "invalid_client", errorDescription: "The client credentials are invalid")),
				TokenErrorCase(name: "server error", response: URLProtocolMock.handler(statusCode: 503, body: #"{"error":"temporarily_unavailable"}"#), expectedError: OAuthTokenEndpointError.unsuccessfulResponse(statusCode: 503, error: "temporarily_unavailable", errorDescription: nil)),
				TokenErrorCase(name: "offline", response: { _ in throw URLError(.notConnectedToInternet) }, expectedError: CloudProviderError.noInternetConnection)
			]
			for testCase in cases {
				URLProtocolMock.requestHandler = [testCase.response]

				let error = try await #require(throws: (any Error).self, "\(testCase.name)") { try await BoxOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: "RT", expiresAt: nil)) }
				#expect(String(describing: testCase.expectedError) == String(describing: error), "\(testCase.name)")
			}
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

		@Test
		func tokenRequestsLeaveNoBodiesInLog() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxOAuthEndpointTests.tokenResponse),
				URLProtocolMock.handler(body: BoxOAuthEndpointTests.tokenResponse),
				URLProtocolMock.handler(body: #"{"secret":"SECRET-REVOKE-RESPONSE"}"#)
			]
			let endpoint = BoxOAuthEndpoint.mocked()

			_ = try await endpoint.exchange(authorizationCode: "SECRET-CODE")
			_ = try await endpoint.refresh(OAuthToken(accessToken: "OLD", refreshToken: "SECRET-REFRESH", expiresAt: nil))
			try await endpoint.revoke(OAuthToken(accessToken: "SECRET-ACCESS", refreshToken: nil, expiresAt: nil))

			let log = logCapture.joinedMessages
			#expect(log.contains("/oauth2/token"), "\(log)")
			#expect(!log.contains("SECRET"), "\(log)")
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

private struct TokenErrorCase {
	let name: String
	let response: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)
	let expectedError: Error
}
