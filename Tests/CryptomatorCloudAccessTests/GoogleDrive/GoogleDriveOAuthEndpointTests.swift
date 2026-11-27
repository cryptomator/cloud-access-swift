//
//  GoogleDriveOAuthEndpointTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct GoogleDriveOAuthEndpointTests {
		private static let now = Date(timeIntervalSince1970: 1_792_000_000)

		init() {
			URLProtocolMock.requestHandler = []
		}

		@Test
		func refreshPostsRefreshGrant() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"access_token":"SECRET-ACCESS","expires_in":3599,"token_type":"Bearer"}"#, onRequest: requests.record)]

			let token = try await GoogleDriveOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: "SECRET-REFRESH", expiresAt: nil))

			#expect(OAuthToken(accessToken: "SECRET-ACCESS", refreshToken: "SECRET-REFRESH", expiresAt: GoogleDriveOAuthEndpointTests.now.addingTimeInterval(3599)) == token)
			let request = try #require(requests.requests.first)
			#expect(request.httpMethod == "POST")
			#expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
			#expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
			#expect(try URLProtocolMock.formParameters(of: request) == ["grant_type": "refresh_token", "refresh_token": "SECRET-REFRESH", "client_id": "CLIENT-ID"])
		}

		@Test
		func rotatedRefreshTokenReplacesStoredOne() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"access_token":"ACCESS","refresh_token":"NEW-REFRESH"}"#)]

			let token = try await GoogleDriveOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: "REFRESH", expiresAt: nil))

			#expect(token.refreshToken == "NEW-REFRESH")
		}

		@Test
		func tokenWithoutRefreshTokenThrowsUnauthorizedWithoutRequest() async throws {
			await #expect(throws: CloudProviderError.unauthorized) { try await GoogleDriveOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: nil, expiresAt: nil)) }
		}
	}
}

extension GoogleDriveOAuthEndpoint {
	static func mocked() -> GoogleDriveOAuthEndpoint {
		return GoogleDriveOAuthEndpoint(clientID: "CLIENT-ID", configuration: URLProtocolMock.configuration(), now: { Date(timeIntervalSince1970: 1_792_000_000) })
	}
}
