//
//  OAuthTokenEndpointTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct OAuthTokenEndpointTests {
		private let session: SplitURLSession

		init() {
			URLProtocolMock.requestHandler = []
			URLProtocolSequenceMock.steps = []
			let configuration = URLSessionConfiguration.default
			configuration.protocolClasses = [URLProtocolMock.self]
			self.session = SplitURLSession(configuration: configuration)
		}

		@Test
		func rejectedGrantIsUnauthorized() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 400, body: #"{"error":"invalid_grant","error_description":"Refresh token has expired"}"#)]

			await #expect(throws: CloudProviderError.unauthorized) { try await post() }
		}

		/// Only a rejected grant, a 400 with `invalid_grant`, means that the user must log in again, so only it maps to `CloudProviderError.unauthorized`.
		@Test
		func otherUnsuccessfulResponsesAreNotUnauthorized() async throws {
			let cases = [
				TokenErrorCase(statusCode: 500, body: #"{"error":"invalid_grant","error_description":"Try again"}"#, expectedError: .unsuccessfulResponse(statusCode: 500, error: "invalid_grant", errorDescription: "Try again")),
				TokenErrorCase(statusCode: 400, body: #"{"error":"invalid_client","error_description":"The client credentials are invalid"}"#, expectedError: .unsuccessfulResponse(statusCode: 400, error: "invalid_client", errorDescription: "The client credentials are invalid")),
				TokenErrorCase(statusCode: 503, body: #"{"error":"temporarily_unavailable"}"#, expectedError: .unsuccessfulResponse(statusCode: 503, error: "temporarily_unavailable", errorDescription: nil))
			]
			for testCase in cases {
				URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: testCase.statusCode, body: testCase.body)]

				await #expect(throws: testCase.expectedError, "\(testCase.statusCode)") { try await post() }
			}
		}

		@Test
		func offlineRequestThrowsNoInternetConnection() async throws {
			URLProtocolMock.requestHandler = [{ _ in throw URLError(.notConnectedToInternet) }]

			await #expect(throws: CloudProviderError.noInternetConnection) { try await post() }
		}

		@Test
		func otherTransportErrorIsThrownWithoutURL() async throws {
			let failingURL = try #require(URL(string: "https://auth.example.com/SENTINEL"))
			URLProtocolMock.requestHandler = [{ _ in throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: failingURL]) }]

			let error = try await #require(throws: URLError.self) { try await post() }
			#expect(error.code == .timedOut)
			#expect(!"\(error.userInfo)".contains("SENTINEL"), "\(error.userInfo)")
			#expect(error.failingURL == nil)
		}

		/// `SplitURLSession` strips the URLs from a challenge handler's recorded failure but keeps the rest of its user info and its underlying error.
		@Test
		func otherErrorKeepsItsDetailsWithoutURLs() async throws {
			let failingURL = try #require(URL(string: "https://auth.example.com/SENTINEL"))
			let underlyingError = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: failingURL])
			let failure = NSError(domain: "OAuthTokenEndpointTests", code: 42, userInfo: ["Detail": "kept", NSURLErrorFailingURLErrorKey: failingURL, NSUnderlyingErrorKey: underlyingError])
			let configuration = URLSessionConfiguration.default
			configuration.protocolClasses = [URLProtocolSequenceMock.self]
			let session = SplitURLSession(configuration: configuration, challengeHandler: FailingChallengeHandler(failure: failure))
			let failureResponse = try #require(HTTPURLResponse(url: failingURL, statusCode: 401, httpVersion: nil, headerFields: nil))
			URLProtocolSequenceMock.steps = [.authChallenge(URLAuthenticationChallengeMock(previousFailureCount: 0, failureResponse: failureResponse))]

			let error = try await #require(throws: (any Error).self) { try await post(on: session) } as NSError
			#expect(error.domain == "OAuthTokenEndpointTests")
			#expect(error.code == 42)
			#expect(error.userInfo["Detail"] as? String == "kept")
			#expect(error.userInfo[NSURLErrorFailingURLErrorKey] == nil)
			let sanitizedUnderlyingError = try #require(error.userInfo[NSUnderlyingErrorKey] as? URLError)
			#expect(sanitizedUnderlyingError.code == .timedOut)
			#expect(sanitizedUnderlyingError.failingURL == nil)
		}

		@Test
		func cancelledRequestThrowsCancellationError() async throws {
			URLProtocolMock.requestHandler = [{ _ in throw URLError(.cancelled) }]

			await #expect(throws: CancellationError.self) { try await post() }
		}

		@Test
		func responseOverMetadataLimitFails() async throws {
			URLProtocolMock.requestHandler = [{ request in
				(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(count: HTTPClientSupport.maxMetadataBodyLength + 1))
			}]

			let error = try await #require(throws: (any Error).self) { try await post() }
			guard case SplitURLSessionError.responseBodyTooLarge = error else {
				Issue.record("Unexpected error: \(error)")
				return
			}
		}

		@Test
		func bodiesAreNotLogged() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"access_token":"SECRET-ACCESS","refresh_token":"SECRET-NEW-REFRESH"}"#)]

			_ = try await post()

			let log = logCapture.joinedMessages
			#expect(log.contains("https://auth.example.com"), "\(log)")
			#expect(!log.contains("SECRET"), "\(log)")
		}

		private func post(on session: SplitURLSession? = nil) async throws -> Data {
			return try await OAuthTokenEndpoint.post([("grant_type", "refresh_token"), ("refresh_token", "SECRET-REFRESH")], host: "auth.example.com", path: "/token", on: session ?? self.session)
		}
	}
}

private struct TokenErrorCase {
	let statusCode: Int
	let body: String
	let expectedError: OAuthTokenEndpointError
}
