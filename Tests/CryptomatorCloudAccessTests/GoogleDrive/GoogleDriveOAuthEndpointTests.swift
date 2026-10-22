//
//  GoogleDriveOAuthEndpointTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class GoogleDriveOAuthEndpointTests: XCTestCase {
	private static let now = Date(timeIntervalSince1970: 1_792_000_000)

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
	}

	func testRefreshPostsRefreshGrantWithoutLoggingBodies() async throws {
		let logCapture = LogCapture.start()
		defer {
			logCapture.stop()
		}
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"access_token":"SECRET-ACCESS","expires_in":3599,"token_type":"Bearer"}"#, onRequest: requests.record)]

		let token = try await GoogleDriveOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: "SECRET-REFRESH", expiresAt: nil))

		XCTAssertEqual(OAuthToken(accessToken: "SECRET-ACCESS", refreshToken: "SECRET-REFRESH", expiresAt: GoogleDriveOAuthEndpointTests.now.addingTimeInterval(3599)), token)
		let request = try XCTUnwrap(requests.requests.first)
		XCTAssertEqual("POST", request.httpMethod)
		XCTAssertEqual("https://oauth2.googleapis.com/token", request.url?.absoluteString)
		XCTAssertEqual("application/x-www-form-urlencoded", request.value(forHTTPHeaderField: "Content-Type"))
		XCTAssertEqual(["grant_type": "refresh_token", "refresh_token": "SECRET-REFRESH", "client_id": "CLIENT-ID"], URLProtocolMock.formParameters(of: request))
		let log = logCapture.joinedMessages
		for secret in ["SECRET-ACCESS", "SECRET-REFRESH"] {
			XCTAssertFalse(log.contains(secret), "\(secret) in \(log)")
		}
	}

	func testRotatedRefreshTokenReplacesStoredOne() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"access_token":"ACCESS","refresh_token":"NEW-REFRESH"}"#)]

		let token = try await GoogleDriveOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: "REFRESH", expiresAt: nil))

		XCTAssertEqual("NEW-REFRESH", token.refreshToken)
	}

	func testRejectedRefreshTokenThrowsUnauthorized() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 400, body: #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#)]

		await XCTAssertThrowsErrorAsync(try await GoogleDriveOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: "REFRESH", expiresAt: nil))) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}

		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 500, body: #"{"error":"internal_failure"}"#)]

		await XCTAssertThrowsErrorAsync(try await GoogleDriveOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: "REFRESH", expiresAt: nil))) { error in
			XCTAssertEqual(.unsuccessfulResponse(statusCode: 500, error: "internal_failure", errorDescription: nil), error as? OAuthTokenEndpointError)
		}
	}

	func testTokenWithoutRefreshTokenThrowsUnauthorizedWithoutRequest() async throws {
		await XCTAssertThrowsErrorAsync(try await GoogleDriveOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: nil, expiresAt: nil))) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
	}
}

extension GoogleDriveOAuthEndpoint {
	static func mocked() -> GoogleDriveOAuthEndpoint {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		return GoogleDriveOAuthEndpoint(clientId: "CLIENT-ID", configuration: configuration, now: { Date(timeIntervalSince1970: 1_792_000_000) })
	}
}
