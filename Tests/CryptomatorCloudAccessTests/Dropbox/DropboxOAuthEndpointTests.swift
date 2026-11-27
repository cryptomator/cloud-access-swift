//
//  DropboxOAuthEndpointTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct DropboxOAuthEndpointTests {
		private static let now = Date(timeIntervalSince1970: 1_792_000_000)
		private static let exchangeResponse = #"{"access_token":"SECRET-ACCESS","expires_in":14400,"token_type":"bearer","refresh_token":"SECRET-REFRESH","scope":"files.metadata.read","uid":"12345","account_id":"dbid:ACCOUNT"}"#
		private static let refreshResponse = #"{"access_token":"SECRET-REFRESHED-ACCESS","expires_in":14400,"token_type":"bearer"}"#

		init() {
			URLProtocolMock.requestHandler = []
		}

		@Test
		func exchangePostsCodeAndVerifierAndReturnsUserID() async throws {
			let recorder = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxOAuthEndpointTests.exchangeResponse, onRequest: recorder.record)]

			let (token, userID) = try await DropboxOAuthEndpoint.mocked().exchange(code: "SECRET-CODE", codeVerifier: "SECRET-VERIFIER")

			#expect(userID == "12345")
			#expect(OAuthToken(accessToken: "SECRET-ACCESS", refreshToken: "SECRET-REFRESH", expiresAt: DropboxOAuthEndpointTests.now.addingTimeInterval(14400)) == token)
			let request = try #require(recorder.requests.first)
			#expect(request.httpMethod == "POST")
			#expect(request.url?.absoluteString == "https://api.dropboxapi.com/oauth2/token")
			#expect(try URLProtocolMock.formParameters(of: request) == ["grant_type": "authorization_code", "code": "SECRET-CODE", "code_verifier": "SECRET-VERIFIER", "client_id": "APP-KEY", "redirect_uri": "db-APP-KEY://2/token"])
		}

		@Test
		func exchangeWithoutUserIDOrRefreshTokenThrows() async throws {
			let cases: [(body: String, isExpectedError: @Sendable (Error) -> Bool)] = [
				(#"{"access_token":"SECRET-ACCESS","expires_in":14400,"refresh_token":"SECRET-REFRESH"}"#, { $0 as? DropboxCredentialError == .missingUserID }),
				(#"{"access_token":"SECRET-ACCESS","expires_in":14400,"refresh_token":"SECRET-REFRESH","uid":""}"#, { $0 as? DropboxCredentialError == .missingUserID }),
				(#"{"access_token":"SECRET-ACCESS","expires_in":14400,"uid":"12345"}"#, { $0 as? DropboxError == .unexpectedContent })
			]
			for (body, isExpectedError) in cases {
				URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: body)]

				let error = try await #require(throws: (any Error).self) { try await DropboxOAuthEndpoint.mocked().exchange(code: "SECRET-CODE", codeVerifier: "SECRET-VERIFIER") }
				#expect(isExpectedError(error), "\(body): unexpected error \(error)")
			}
		}

		@Test
		func refreshPostsRefreshGrantAndKeepsRefreshToken() async throws {
			let recorder = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxOAuthEndpointTests.refreshResponse, onRequest: recorder.record)]

			let token = try await DropboxOAuthEndpoint.mocked().refresh(OAuthToken(accessToken: "OLD", refreshToken: "SECRET-REFRESH", expiresAt: nil))

			#expect(OAuthToken(accessToken: "SECRET-REFRESHED-ACCESS", refreshToken: "SECRET-REFRESH", expiresAt: DropboxOAuthEndpointTests.now.addingTimeInterval(14400)) == token)
			let request = try #require(recorder.requests.first)
			#expect(request.url?.absoluteString == "https://api.dropboxapi.com/oauth2/token")
			#expect(try URLProtocolMock.formParameters(of: request) == ["grant_type": "refresh_token", "refresh_token": "SECRET-REFRESH", "client_id": "APP-KEY"])
		}

		/// Dropbox may answer an expired access token with `expired_access_token`, so the revocation sends a fresh one, whatever the stored expiry says.
		@Test
		func revokeRefreshesFirstAndRevokesRefreshedAccessToken() async throws {
			let recorder = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: DropboxOAuthEndpointTests.refreshResponse, onRequest: recorder.record),
				URLProtocolMock.handler(body: "null", onRequest: recorder.record)
			]

			try await DropboxOAuthEndpoint.mocked().revoke(OAuthToken(accessToken: "SECRET-ACCESS", refreshToken: "SECRET-REFRESH", expiresAt: .distantFuture))

			let sentRequests = recorder.requests
			#expect(sentRequests.map { $0.url?.absoluteString } == ["https://api.dropboxapi.com/oauth2/token", "https://api.dropboxapi.com/2/auth/token/revoke"])
			let revocation = try #require(sentRequests.last)
			#expect(revocation.httpMethod == "POST")
			#expect(revocation.value(forHTTPHeaderField: "Authorization") == "Bearer SECRET-REFRESHED-ACCESS")
			#expect(revocation.value(forHTTPHeaderField: "Content-Type") == "application/json")
			#expect(Data("null".utf8) == revocation.httpBody)
		}

		@Test
		func revokeOfRevokedGrantSendsNoRevocation() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 400, body: #"{"error":"invalid_grant"}"#),
				URLProtocolMock.handler(body: "null")
			]

			try await DropboxOAuthEndpoint.mocked().revoke(OAuthToken(accessToken: "SECRET-ACCESS", refreshToken: "SECRET-REFRESH", expiresAt: nil))

			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func revokeOfLongLivedTokenSendsItWithoutRefresh() async throws {
			let recorder = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: "null", onRequest: recorder.record)]

			try await DropboxOAuthEndpoint.mocked().revoke(OAuthToken(accessToken: "SECRET-LONG-LIVED", refreshToken: nil, expiresAt: nil))

			let request = try #require(recorder.requests.first)
			#expect(request.url?.absoluteString == "https://api.dropboxapi.com/2/auth/token/revoke")
			#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer SECRET-LONG-LIVED")
		}

		@Test
		func revocationResponseOverMetadataLimitFails() async throws {
			URLProtocolMock.requestHandler = [{ request in
				(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(count: HTTPClientSupport.maxMetadataBodyLength + 1))
			}]

			let error = try await #require(throws: (any Error).self) { try await DropboxOAuthEndpoint.mocked().revoke(OAuthToken(accessToken: "LONG-LIVED", refreshToken: nil, expiresAt: nil)) }
			guard case SplitURLSessionError.responseBodyTooLarge = error else {
				Issue.record("Unexpected error: \(error)")
				return
			}
		}

		@Test
		func revokeTreatsRejectedTokenAsRevokedAndThrowsOtherFailures() async throws {
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

				await #expect(throws: expectedError) { try await DropboxOAuthEndpoint.mocked().revoke(token) }
			}
		}

		@Test
		func tokenRequestsLeaveNoBodiesInLog() async throws {
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
			#expect(log.contains("/oauth2/token"), "\(log)")
			#expect(log.contains("/2/auth/token/revoke"), "\(log)")
			#expect(!log.contains("SECRET"), "\(log)")
		}
	}
}

extension DropboxOAuthEndpoint {
	static func mocked() -> DropboxOAuthEndpoint {
		return DropboxOAuthEndpoint(appKey: "APP-KEY", configuration: URLProtocolMock.configuration(), now: { Date(timeIntervalSince1970: 1_792_000_000) })
	}
}
