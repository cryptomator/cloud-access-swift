//
//  MicrosoftGraphHTTPClientTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 14.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class MicrosoftGraphHTTPClientTests {
		private let url = URL(string: "https://graph.microsoft.com/v1.0/me/drive/root")!
		private let uploadURL = URL(string: "https://upload.example.com/up/SECRET-PATH-TOKEN?tempauth=SECRET-TEMPAUTH")!
		private let tokenSource: OAuthTokenSourceStub
		private let sleeps: SleepRecorder
		private let client: MicrosoftGraphHTTPClient
		private let tmpDirURL: URL

		init() throws {
			URLProtocolMock.requestHandler = []
			self.tokenSource = OAuthTokenSourceStub()
			self.sleeps = SleepRecorder()
			self.client = MicrosoftGraphHTTPClient.mocked(tokenSource: tokenSource, sleeps: sleeps)
			self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		// MARK: - Retries

		@Test
		func throttledRequestIsRetried() async throws {
			let authorizations = OSAllocatedUnfairLock(initialState: [String?]())
			let recordAuthorization: @Sendable (URLRequest) -> Void = { request in
				authorizations.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
			}
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 429, headerFields: ["Retry-After": "0"], onRequest: recordAuthorization),
				URLProtocolMock.handler(body: "{}", onRequest: recordAuthorization)
			]

			let (response, data) = try await client.data(URLRequest(url: url))

			#expect(response.statusCode == 200)
			#expect(Data("{}".utf8) == data)
			#expect(authorizations.withLock { $0 } == ["Bearer TOKEN", "Bearer TOKEN"])
			#expect([.seconds(0)] == sleeps.durations)
		}

		@Test
		func serverErrorsAreRetriedUntilFiveAttempts() async throws {
			URLProtocolMock.requestHandler = [500, 502, 503, 504].map { URLProtocolMock.handler(statusCode: $0) } + [URLProtocolMock.handler(statusCode: 503), URLProtocolMock.handler(body: "{}")]

			let (response, _) = try await client.data(URLRequest(url: url))

			#expect(response.statusCode == 503)
			#expect(URLProtocolMock.requestHandler.count == 1)
			#expect(sleeps.durations.count == 4)
		}

		@Test
		func serverErrorsOfMutationsAreNotRetried() async throws {
			for method in ["POST", "PATCH", "DELETE"] {
				for statusCode in [500, 502] {
					var request = URLRequest(url: url)
					request.httpMethod = method
					URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: statusCode), URLProtocolMock.handler(body: "{}")]

					let (response, _) = try await client.data(request)

					#expect(statusCode == response.statusCode, "\(method)")
					#expect(URLProtocolMock.requestHandler.count == 1, "\(method)")
				}
			}
			var request = URLRequest(url: url)
			request.httpMethod = "DELETE"
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 503), URLProtocolMock.handler(statusCode: 204)]

			let (response, _) = try await client.data(request)

			#expect(response.statusCode == 204)
			#expect(sleeps.durations.count == 1)
		}

		@Test
		func retryAfterIsCappedAtOneMinute() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 429, headerFields: ["Retry-After": "3600"]), URLProtocolMock.handler(body: "{}")]

			_ = try await client.data(URLRequest(url: url))

			#expect([.seconds(60)] == sleeps.durations)
		}

		@Test
		func unauthorizedRequestIsRefreshedOnce() async throws {
			let authorizations = OSAllocatedUnfairLock(initialState: [String?]())
			let recordAuthorization: @Sendable (URLRequest) -> Void = { request in
				authorizations.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
			}
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401, onRequest: recordAuthorization), URLProtocolMock.handler(body: "{}", onRequest: recordAuthorization)]

			_ = try await client.dataExpectingOK(URLRequest(url: url))

			#expect(authorizations.withLock { $0 } == ["Bearer TOKEN", "Bearer REFRESHED"])
			#expect(tokenSource.rejectedTokens == ["TOKEN"])

			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: "{}")]

			await #expect(throws: CloudProviderError.unauthorized) { try await client.dataExpectingOK(URLRequest(url: url)) }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func metadataBodyOverLimitFails() async throws {
			URLProtocolMock.requestHandler = [{ request in
				(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(count: HTTPClientSupport.maxMetadataBodyLength + 1))
			}]

			let error = try await #require(throws: (any Error).self) { try await client.data(URLRequest(url: url)) }
			guard case SplitURLSessionError.responseBodyTooLarge = error else {
				Issue.record("Unexpected error: \(error)")
				return
			}
		}

		// MARK: - Uploads

		@Test
		func uploadIsSentWithoutAuthorization() async throws {
			let fileURL = tmpDirURL.appendingPathComponent("chunk")
			try Data("chunk".utf8).write(to: fileURL)
			let authorizations = OSAllocatedUnfairLock(initialState: [String?]())
			let recordAuthorization: @Sendable (URLRequest) -> Void = { request in
				authorizations.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
			}
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 503, onRequest: recordAuthorization), URLProtocolMock.handler(statusCode: 401, onRequest: recordAuthorization), URLProtocolMock.handler(statusCode: 202)]

			let (response, _) = try await client.upload(putRequest(), fromFile: fileURL, progress: nil, onTaskCreation: nil)

			#expect(response.statusCode == 401)
			#expect(authorizations.withLock { $0 } == [nil, nil])
			#expect(tokenSource.rejectedTokens.isEmpty)
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func serverErrorOfUploadIsRetried() async throws {
			let fileURL = tmpDirURL.appendingPathComponent("chunk")
			try Data("chunk".utf8).write(to: fileURL)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 500), URLProtocolMock.handler(statusCode: 502), URLProtocolMock.handler(statusCode: 201)]

			let (response, _) = try await client.upload(putRequest(), fromFile: fileURL, progress: nil, onTaskCreation: nil)

			#expect(response.statusCode == 201)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func retriedTransfersHandOverOneTask() async throws {
			let fileURL = tmpDirURL.appendingPathComponent("chunk")
			try Data("chunk".utf8).write(to: fileURL)
			let downloadTaskCount = OSAllocatedUnfairLock(initialState: 0)
			let uploadTaskCount = OSAllocatedUnfairLock(initialState: 0)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 503), URLProtocolMock.handler(body: "content"), URLProtocolMock.handler(statusCode: 503), URLProtocolMock.handler(statusCode: 201)]

			_ = try await client.download(URLRequest(url: url.appendingPathComponent("content")), to: tmpDirURL.appendingPathComponent("download"), progress: nil, onTaskCreation: { _ in
				downloadTaskCount.withLock { $0 += 1 }
			})
			_ = try await client.upload(putRequest(), fromFile: fileURL, progress: nil, onTaskCreation: { _ in
				uploadTaskCount.withLock { $0 += 1 }
			})

			#expect(downloadTaskCount.withLock { $0 } == 1)
			#expect(uploadTaskCount.withLock { $0 } == 1)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func failedAndRetriedUploadLogsOnlyOriginOfURL() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			let fileURL = tmpDirURL.appendingPathComponent("chunk")
			try Data("chunk".utf8).write(to: fileURL)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 503), { _ in throw URLError(.timedOut) }]

			let error = try await #require(throws: (any Error).self) { try await client.upload(putRequest(), fromFile: fileURL, progress: nil, onTaskCreation: nil) }
			#expect((error as? URLError)?.code == .timedOut)

			let failureLines = logCapture.messages.filter { $0.hasPrefix("MicrosoftGraphHTTPClient: PUT") }
			#expect(failureLines.count == 2, "\(logCapture.joinedMessages)")
			#expect(failureLines.allSatisfy { $0.contains("https://upload.example.com/<redacted>") }, "\(logCapture.joinedMessages)")
			#expect(!logCapture.joinedMessages.contains("SECRET"), "\(logCapture.joinedMessages)")
		}

		// MARK: - Logging

		@Test
		func responseBodiesAreNotLogged() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			let fileURL = tmpDirURL.appendingPathComponent("chunk")
			try Data("chunk".utf8).write(to: fileURL)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: #"{"value":[{"id":"1","@microsoft.graph.downloadUrl":"https://content.example.com/a?tempauth=SECRET-LISTED","createdBy":{"user":{"email":"lister@example.com"}}}]}"#),
				URLProtocolMock.handler(statusCode: 201, body: #"{"id":"2","@content.downloadUrl":"https://content.example.com/b?tempauth=SECRET-UPLOADED","createdBy":{"user":{"email":"uploader@example.com"}}}"#)
			]

			_ = try await client.dataExpectingOK(URLRequest(url: url))
			_ = try await client.upload(putRequest(), fromFile: fileURL, progress: nil, onTaskCreation: nil)

			let log = logCapture.joinedMessages
			#expect(log.contains("https://graph.microsoft.com"), "\(log)")
			for secret in ["SECRET", "lister@example.com", "uploader@example.com"] {
				#expect(!log.contains(secret), "\(secret) in \(log)")
			}
		}

		@Test
		func retriedDownloadLogsAPIPathAndOnlyOriginOfRedirectTarget() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 503),
				URLProtocolMock.handler(statusCode: 302, headerFields: ["Location": "https://content.example.com/personal/SECRET-ACCOUNT/download.aspx?tempauth=TEMPAUTH"]),
				URLProtocolMock.handler(body: "content")
			]
			let stagingURL = tmpDirURL.appendingPathComponent("download")

			let response = try await client.download(URLRequest(url: url.appendingPathComponent("content")), to: stagingURL, progress: nil, onTaskCreation: nil)

			#expect(response.statusCode == 200)
			#expect(try Data("content".utf8) == Data(contentsOf: stagingURL))
			let log = logCapture.joinedMessages
			#expect(logCapture.messages.contains { $0.hasPrefix("MicrosoftGraphHTTPClient: GET https://graph.microsoft.com/v1.0/me/drive/root/content") }, "\(log)")
			#expect(logCapture.messages.contains("<-- 200 no error https://content.example.com/<redacted>"), "\(log)")
			for secret in ["SECRET-ACCOUNT", "TEMPAUTH"] {
				#expect(!log.contains(secret), "\(secret) in \(log)")
			}
		}

		@Test
		func retriedPreAuthenticatedDownloadLogsOnlyOriginOfURL() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 503), URLProtocolMock.handler(body: "content")]
			let downloadURL = try #require(URL(string: "https://content.example.com/personal/SECRET-ACCOUNT/download.aspx"))

			_ = try await client.download(URLRequest(url: downloadURL), authorization: .none, to: tmpDirURL.appendingPathComponent("download"), progress: nil, onTaskCreation: nil)

			let log = logCapture.joinedMessages
			#expect(logCapture.messages.contains { $0.hasPrefix("MicrosoftGraphHTTPClient: GET https://content.example.com/<redacted>") }, "\(log)")
			#expect(logCapture.messages.contains("<-- 200 no error https://content.example.com/<redacted>"), "\(log)")
			#expect(!log.contains("SECRET"), "\(log)")
		}

		@Test
		func bodiesOfDownloadsAreNotLogged() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			let downloadURL = try #require(URL(string: "https://content.example.com/dl/PATH"))
			for authorization in [BearerRequestSender.Authorization.bearer, .none] {
				URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 404, body: #"{"error":"https://content.example.com/dl/SECRET-PATH"}"#)]

				let response = try await client.download(URLRequest(url: downloadURL), authorization: authorization, to: tmpDirURL.appendingPathComponent(UUID().uuidString), progress: nil, onTaskCreation: nil)

				#expect(response.statusCode == 404)
			}

			#expect(logCapture.messages.count { $0.hasPrefix("--> GET https://content.example.com") } == 2, "\(logCapture.joinedMessages)")
			#expect(!logCapture.joinedMessages.contains("SECRET"), "\(logCapture.joinedMessages)")
		}

		// MARK: - Configurations

		@Test
		func testBackgroundConfiguration() {
			let configuration = MicrosoftGraphHTTPClient.backgroundConfiguration(sessionIdentifier: "MicrosoftGraphHTTPClientTests", sharedContainerIdentifier: "group.test")

			#expect(configuration.identifier == "MicrosoftGraphHTTPClientTests")
			#expect(configuration.sharedContainerIdentifier == "group.test")
		}

		@Test
		func configurationsAreHardened() {
			for configuration in [MicrosoftGraphHTTPClient.foregroundConfiguration(), MicrosoftGraphHTTPClient.backgroundConfiguration(sessionIdentifier: "MicrosoftGraphHTTPClientTests", sharedContainerIdentifier: nil)] {
				#expect(configuration.urlCache == nil)
				#expect(configuration.urlCredentialStorage == nil)
				#expect(configuration.httpCookieStorage != nil)
				#expect(!(configuration.httpCookieStorage === HTTPCookieStorage.shared))
			}
		}

		// MARK: - Helpers

		private func putRequest() -> URLRequest {
			var request = URLRequest(url: uploadURL)
			request.httpMethod = "PUT"
			return request
		}
	}
}

extension MicrosoftGraphHTTPClient {
	static func mocked(tokenSource: any BearerTokenSource = OAuthTokenSourceStub(), sleeps: SleepRecorder = SleepRecorder(), hooks: SplitURLSession.Hooks = SplitURLSession.Hooks()) -> MicrosoftGraphHTTPClient {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		return MicrosoftGraphHTTPClient(tokenSource: tokenSource, configuration: configuration, metadataConfiguration: nil, hooks: hooks, sleep: { sleeps.sleep(for: $0) })
	}
}
