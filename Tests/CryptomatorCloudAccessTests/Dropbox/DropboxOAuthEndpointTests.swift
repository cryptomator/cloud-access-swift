//
//  DropboxOAuthEndpointTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class DropboxOAuthEndpointTests: XCTestCase {
	private static let now = Date(timeIntervalSince1970: 1_792_000_000)
	private static let exchangeResponse = #"{"access_token":"SECRET-ACCESS","expires_in":14400,"token_type":"bearer","refresh_token":"SECRET-REFRESH","scope":"files.metadata.read","uid":"12345","account_id":"dbid:ACCOUNT"}"#
	private static let refreshResponse = #"{"access_token":"SECRET-REFRESHED-ACCESS","expires_in":14400,"token_type":"bearer"}"#

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
	}

	func testExchangePostsCodeAndVerifierAndReturnsUserID() async throws {
		let sentRequest = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxOAuthEndpointTests.exchangeResponse, onRequest: { request in
			sentRequest.withLock { $0 = request }
		})]

		let (token, userID) = try await DropboxOAuthEndpoint.mocked().exchange(code: "SECRET-CODE", codeVerifier: "SECRET-VERIFIER")

		XCTAssertEqual("12345", userID)
		XCTAssertEqual(OAuthToken(accessToken: "SECRET-ACCESS", refreshToken: "SECRET-REFRESH", expiresAt: DropboxOAuthEndpointTests.now.addingTimeInterval(14400)), token)
		let request = try XCTUnwrap(sentRequest.withLock { $0 })
		XCTAssertEqual("POST", request.httpMethod)
		XCTAssertEqual("https://api.dropboxapi.com/oauth2/token", request.url?.absoluteString)
		XCTAssertEqual(["grant_type": "authorization_code", "code": "SECRET-CODE", "code_verifier": "SECRET-VERIFIER", "client_id": "APP-KEY", "redirect_uri": "db-APP-KEY://2/token"], URLProtocolMock.formParameters(of: request))
	}

	func testExchangeWithoutUserIDOrRefreshTokenThrows() async throws {
		let cases: [(body: String, isExpectedError: @Sendable (Error) -> Bool)] = [
			(#"{"access_token":"SECRET-ACCESS","expires_in":14400,"refresh_token":"SECRET-REFRESH"}"#, { $0 as? DropboxCredentialError == .missingUserID }),
			(#"{"access_token":"SECRET-ACCESS","expires_in":14400,"refresh_token":"SECRET-REFRESH","uid":""}"#, { $0 as? DropboxCredentialError == .missingUserID }),
			(#"{"access_token":"SECRET-ACCESS","expires_in":14400,"uid":"12345"}"#, { $0 as? DropboxError == .unexpectedContent })
		]
		for (body, isExpectedError) in cases {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: body)]

			await XCTAssertThrowsErrorAsync(try await DropboxOAuthEndpoint.mocked().exchange(code: "SECRET-CODE", codeVerifier: "SECRET-VERIFIER")) { error in
				XCTAssertTrue(isExpectedError(error), "\(body): unexpected error \(error)")
			}
		}
	}

	func testRefreshPostsRefreshGrantAndKeepsRefreshToken() async throws {
		let sentRequest = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxOAuthEndpointTests.refreshResponse, onRequest: { request in
			sentRequest.withLock { $0 = request }
		})]

		let token = try await DropboxOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: "SECRET-REFRESH", expiresAt: nil))

		XCTAssertEqual(OAuthToken(accessToken: "SECRET-REFRESHED-ACCESS", refreshToken: "SECRET-REFRESH", expiresAt: DropboxOAuthEndpointTests.now.addingTimeInterval(14400)), token)
		let request = try XCTUnwrap(sentRequest.withLock { $0 })
		XCTAssertEqual("https://api.dropboxapi.com/oauth2/token", request.url?.absoluteString)
		XCTAssertEqual(["grant_type": "refresh_token", "refresh_token": "SECRET-REFRESH", "client_id": "APP-KEY"], URLProtocolMock.formParameters(of: request))
	}

	func testInvalidGrantIsUnauthorized() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 400, body: #"{"error":"invalid_grant","error_description":"refresh token is invalid or revoked"}"#)]

		await XCTAssertThrowsErrorAsync(try await DropboxOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: "RT", expiresAt: nil))) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
	}

	/// Dropbox may answer an expired access token with `expired_access_token`, so the revocation sends a fresh one, whatever the stored expiry says.
	func testRevokeRefreshesFirstAndRevokesRefreshedAccessToken() async throws {
		let recorder = RequestRecorder()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: DropboxOAuthEndpointTests.refreshResponse, onRequest: recorder.record),
			URLProtocolMock.handler(body: "null", onRequest: recorder.record)
		]

		try await DropboxOAuthEndpoint.mocked().revoke(OAuthToken(accessToken: "SECRET-ACCESS", refreshToken: "SECRET-REFRESH", expiresAt: .distantFuture))

		let sentRequests = recorder.requests
		XCTAssertEqual(["https://api.dropboxapi.com/oauth2/token", "https://api.dropboxapi.com/2/auth/token/revoke"], sentRequests.map { $0.url?.absoluteString })
		let revocation = try XCTUnwrap(sentRequests.last)
		XCTAssertEqual("POST", revocation.httpMethod)
		XCTAssertEqual("Bearer SECRET-REFRESHED-ACCESS", revocation.value(forHTTPHeaderField: "Authorization"))
		XCTAssertEqual("application/json", revocation.value(forHTTPHeaderField: "Content-Type"))
		XCTAssertEqual(Data("null".utf8), revocation.httpBody)
	}

	func testRevokeOfRevokedGrantSendsNoRevocation() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 400, body: #"{"error":"invalid_grant"}"#),
			URLProtocolMock.handler(body: "null")
		]

		try await DropboxOAuthEndpoint.mocked().revoke(OAuthToken(accessToken: "SECRET-ACCESS", refreshToken: "SECRET-REFRESH", expiresAt: nil))

		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testRevokeOfLongLivedTokenSendsItWithoutRefresh() async throws {
		let sentRequest = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: "null", onRequest: { request in
			sentRequest.withLock { $0 = request }
		})]

		try await DropboxOAuthEndpoint.mocked().revoke(OAuthToken(accessToken: "SECRET-LONG-LIVED", refreshToken: nil, expiresAt: nil))

		let request = try XCTUnwrap(sentRequest.withLock { $0 })
		XCTAssertEqual("https://api.dropboxapi.com/2/auth/token/revoke", request.url?.absoluteString)
		XCTAssertEqual("Bearer SECRET-LONG-LIVED", request.value(forHTTPHeaderField: "Authorization"))
	}

	func testRevocationResponseOverMetadataLimitFails() async throws {
		URLProtocolMock.requestHandler = [{ request in
			(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(count: HTTPClientSupport.maxMetadataBodyLength + 1))
		}]

		await XCTAssertThrowsErrorAsync(try await DropboxOAuthEndpoint.mocked().revoke(OAuthToken(accessToken: "LONG-LIVED", refreshToken: nil, expiresAt: nil))) { error in
			guard case SplitURLSessionError.responseBodyTooLarge = error else {
				return XCTFail("Unexpected error: \(error)")
			}
		}
	}

	func testRevokeTreatsRejectedTokenAsRevokedAndThrowsOtherFailures() async throws {
		let token = OAuthToken(accessToken: "SECRET-LONG-LIVED", refreshToken: nil, expiresAt: nil)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401, body: #"{"error_summary":"invalid_access_token/.."}"#)]

		try await DropboxOAuthEndpoint.mocked().revoke(token)

		// Only an invalid access token means that the login is revoked already.
		let failures: [(handler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?), error: DropboxError)] = [
			(URLProtocolMock.handler(statusCode: 401, body: #"{"error_summary":"expired_access_token/..","error":{".tag":"expired_access_token"}}"#), .apiError(statusCode: 401, summary: "expired_access_token/..")),
			(URLProtocolMock.handler(statusCode: 401, body: #"{"error_summary":"user_suspended/..","error":{".tag":"user_suspended"}}"#), .apiError(statusCode: 401, summary: "user_suspended/..")),
			(URLProtocolMock.handler(statusCode: 401, body: "Unauthorized"), .apiError(statusCode: 401, summary: nil)),
			(URLProtocolMock.handler(statusCode: 500, body: "Internal Server Error"), .apiError(statusCode: 500, summary: nil))
		]
		for (handler, expectedError) in failures {
			URLProtocolMock.requestHandler = [handler]

			await XCTAssertThrowsErrorAsync(try await DropboxOAuthEndpoint.mocked().revoke(token)) { error in
				XCTAssertEqual(expectedError, error as? DropboxError)
			}
		}
	}

	func testTokenRequestsLeaveNoBodiesInLog() async throws {
		let logCapture = LogCapture.start()
		defer {
			logCapture.stop()
		}
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: DropboxOAuthEndpointTests.exchangeResponse),
			URLProtocolMock.handler(body: DropboxOAuthEndpointTests.refreshResponse),
			URLProtocolMock.handler(body: #"{"secret":"SECRET-REVOKE-RESPONSE"}"#)
		]
		let endpoint = DropboxOAuthEndpoint.mocked()

		_ = try await endpoint.exchange(code: "SECRET-CODE", codeVerifier: "SECRET-VERIFIER")
		_ = try await endpoint.refresh(OAuthToken(accessToken: "OLD", refreshToken: "SECRET-REFRESH", expiresAt: nil))
		try await endpoint.revoke(OAuthToken(accessToken: "SECRET-ACCESS", refreshToken: nil, expiresAt: nil))

		let log = logCapture.joinedMessages
		XCTAssertTrue(log.contains("/oauth2/token"), log)
		XCTAssertTrue(log.contains("/2/auth/token/revoke"), log)
		XCTAssertFalse(log.contains("SECRET"), log)
	}
}

extension DropboxOAuthEndpoint {
	static func mocked() -> DropboxOAuthEndpoint {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		return DropboxOAuthEndpoint(appKey: "APP-KEY", configuration: configuration, now: { Date(timeIntervalSince1970: 1_792_000_000) })
	}
}
