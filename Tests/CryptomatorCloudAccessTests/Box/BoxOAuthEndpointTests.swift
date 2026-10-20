//
//  BoxOAuthEndpointTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class BoxOAuthEndpointTests: XCTestCase {
	private static let now = Date(timeIntervalSince1970: 1_792_000_000)
	private static let tokenResponse = #"{"access_token":"SECRET-ACCESS","expires_in":3600,"token_type":"bearer","refresh_token":"SECRET-NEW-REFRESH","restricted_to":[]}"#

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
	}

	func testRefreshPostsRefreshGrantAndMapsToken() async throws {
		let sentRequest = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: BoxOAuthEndpointTests.tokenResponse, onRequest: { request in
			sentRequest.withLock { $0 = request }
		})]

		let token = try await BoxOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: "SECRET-REFRESH", expiresAt: nil))

		XCTAssertEqual(OAuthToken(accessToken: "SECRET-ACCESS", refreshToken: "SECRET-NEW-REFRESH", expiresAt: BoxOAuthEndpointTests.now.addingTimeInterval(3600)), token)
		let request = try XCTUnwrap(sentRequest.withLock { $0 })
		XCTAssertEqual("POST", request.httpMethod)
		XCTAssertEqual("https://api.box.com/oauth2/token", request.url?.absoluteString)
		XCTAssertEqual("application/x-www-form-urlencoded", request.value(forHTTPHeaderField: "Content-Type"))
		XCTAssertEqual(["grant_type": "refresh_token", "refresh_token": "SECRET-REFRESH", "client_id": "CLIENT-ID", "client_secret": "SECRET-CLIENT"], PCloudMockResponse.formParameters(of: request))
	}

	func testInvalidGrantIsUnauthorized() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 400, body: #"{"error":"invalid_grant","error_description":"Refresh token has expired"}"#)]

		await XCTAssertThrowsErrorAsync(try await BoxOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: "RT", expiresAt: nil))) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
	}

	/// Only a rejected grant means that the user must log in again, so only it maps to `CloudProviderError.unauthorized`.
	func testOtherFailuresAreNotUnauthorized() async throws {
		let cases = [
			TokenErrorCase(name: "invalid client", response: URLProtocolMock.handler(statusCode: 400, body: #"{"error":"invalid_client","error_description":"The client credentials are invalid"}"#), expectedError: BoxError.apiError(statusCode: 400, code: "invalid_client", message: "The client credentials are invalid")),
			TokenErrorCase(name: "server error", response: URLProtocolMock.handler(statusCode: 503, body: #"{"error":"temporarily_unavailable"}"#), expectedError: BoxError.apiError(statusCode: 503, code: "temporarily_unavailable", message: nil)),
			TokenErrorCase(name: "offline", response: { _ in throw URLError(.notConnectedToInternet) }, expectedError: CloudProviderError.noInternetConnection)
		]
		for testCase in cases {
			URLProtocolMock.requestHandler = [testCase.response]

			await XCTAssertThrowsErrorAsync(try await BoxOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: "RT", expiresAt: nil)), testCase.name) { error in
				XCTAssertEqual(String(describing: testCase.expectedError), String(describing: error), testCase.name)
			}
		}
	}

	func testRevokePostsAccessToken() async throws {
		let sentRequest = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(onRequest: { request in
			sentRequest.withLock { $0 = request }
		})]

		try await BoxOAuthEndpoint.mocked().revoke(OAuthToken(accessToken: "SECRET-ACCESS", refreshToken: "SECRET-REFRESH", expiresAt: nil))

		let request = try XCTUnwrap(sentRequest.withLock { $0 })
		XCTAssertEqual("https://api.box.com/oauth2/revoke", request.url?.absoluteString)
		XCTAssertEqual(["client_id": "CLIENT-ID", "client_secret": "SECRET-CLIENT", "token": "SECRET-ACCESS"], PCloudMockResponse.formParameters(of: request))
	}

	func testTokenRequestsLeaveNoBodiesInLog() async throws {
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
		XCTAssertTrue(log.contains("/oauth2/token"), log)
		XCTAssertFalse(log.contains("SECRET"), log)
	}
}

extension BoxOAuthEndpoint {
	static func mocked() -> BoxOAuthEndpoint {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		return BoxOAuthEndpoint(clientId: "CLIENT-ID", clientSecret: "SECRET-CLIENT", configuration: configuration, now: { Date(timeIntervalSince1970: 1_792_000_000) })
	}
}

private struct TokenErrorCase {
	let name: String
	let response: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)
	let expectedError: Error
}
