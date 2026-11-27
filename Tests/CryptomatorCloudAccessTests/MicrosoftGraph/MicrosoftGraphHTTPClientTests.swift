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
		private let address = MicrosoftGraphAPI.ItemAddress(driveIdentifier: nil, itemIdentifier: "1")
		private let driveItem = #"{"id":"1","name":"a"}"#
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
			self.tmpDirURL = try makeTemporaryDirectory()
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
				URLProtocolMock.handler(body: driveItem, onRequest: recordAuthorization)
			]

			let item = try await client.item(at: address)

			#expect(item.id == "1")
			#expect(authorizations.withLock { $0 } == ["Bearer TOKEN", "Bearer TOKEN"])
			#expect([.seconds(0)] == sleeps.durations)
		}

		@Test
		func transportErrorOfGETIsRetried() async throws {
			URLProtocolMock.requestHandler = [{ _ in throw URLError(.networkConnectionLost) }, URLProtocolMock.handler(body: driveItem)]

			let item = try await client.item(at: address)

			#expect(item.id == "1")
			#expect(sleeps.durations.count == 1)
		}

		@Test
		func serverErrorsAreRetriedUntilFiveAttempts() async throws {
			URLProtocolMock.requestHandler = [500, 502, 503, 504].map { URLProtocolMock.handler(statusCode: $0) } + [URLProtocolMock.handler(statusCode: 503), URLProtocolMock.handler(body: driveItem)]

			let error = try await #require(throws: (any Error).self) { try await client.item(at: address) }

			expectStatusCode(503, of: error)
			#expect(URLProtocolMock.requestHandler.count == 1)
			#expect(sleeps.durations.count == 4)
		}

		@Test
		func serverErrorsOfMutationsAreNotRetried() async throws {
			let client: MicrosoftGraphHTTPClient = client
			let address = address
			let mutations: [(method: String, operation: @Sendable () async throws -> Void)] = [
				("POST", { _ = try await client.createFolder(named: "folder", in: address) }),
				("PATCH", { _ = try await client.move(address, named: "a", toParentID: "2", parentDriveID: nil) }),
				("DELETE", { try await client.delete(address) })
			]
			for (method, operation) in mutations {
				for statusCode in [500, 502] {
					URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: statusCode), URLProtocolMock.handler(body: driveItem)]

					let error = try await #require(throws: (any Error).self, "\(method)") { try await operation() }

					expectStatusCode(statusCode, of: error)
					#expect(URLProtocolMock.requestHandler.count == 1, "\(method)")
				}
			}
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 503), URLProtocolMock.handler(statusCode: 204)]

			try await client.delete(address)

			#expect(sleeps.durations.count == 1)
		}

		@Test
		func unauthorizedRequestIsRefreshedOnce() async throws {
			let authorizations = OSAllocatedUnfairLock(initialState: [String?]())
			let recordAuthorization: @Sendable (URLRequest) -> Void = { request in
				authorizations.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
			}
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401, onRequest: recordAuthorization), URLProtocolMock.handler(body: driveItem, onRequest: recordAuthorization)]

			_ = try await client.item(at: address)

			#expect(authorizations.withLock { $0 } == ["Bearer TOKEN", "Bearer REFRESHED"])
			#expect(tokenSource.rejectedTokens == ["TOKEN"])

			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: driveItem)]

			await #expect(throws: CloudProviderError.unauthorized) { try await client.item(at: address) }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func metadataBodyOverLimitFails() async throws {
			URLProtocolMock.requestHandler = [{ request in
				(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(count: HTTPClientSupport.maxMetadataBodyLength + 1))
			}]

			let error = try await #require(throws: (any Error).self) { try await client.item(at: address) }
			guard case SplitURLSessionError.responseBodyTooLarge = error else {
				Issue.record("Unexpected error: \(error)")
				return
			}
		}

		// MARK: - Uploads

		@Test
		func uploadIsSentWithoutAuthorization() async throws {
			let fileURL = try makeLocalFile(in: tmpDirURL, named: "chunk", content: "chunk")
			let authorizations = OSAllocatedUnfairLock(initialState: [String?]())
			let recordAuthorization: @Sendable (URLRequest) -> Void = { request in
				authorizations.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
			}
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 503, onRequest: recordAuthorization), URLProtocolMock.handler(statusCode: 401, onRequest: recordAuthorization), URLProtocolMock.handler(statusCode: 202)]

			let error = try await #require(throws: (any Error).self) { try await uploadChunk(from: fileURL) }

			expectStatusCode(401, of: error)
			#expect(authorizations.withLock { $0 } == [nil, nil])
			#expect(tokenSource.rejectedTokens.isEmpty)
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func serverErrorOfUploadIsRetried() async throws {
			let fileURL = try makeLocalFile(in: tmpDirURL, named: "chunk", content: "chunk")
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 500), URLProtocolMock.handler(statusCode: 502), URLProtocolMock.handler(statusCode: 201, body: driveItem)]

			let item = try await uploadChunk(from: fileURL)

			#expect(item?.id == "1")
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// Each attempt adds the progress of its task, so a retried chunk takes half of the transfer's share instead of pushing it past complete.
		@Test
		func retriedUploadSharesProgressWithFirstAttempt() async throws {
			let fileURL = try makeLocalFile(in: tmpDirURL, named: "chunk", content: "chunk")
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let fractionAtRetry = OSAllocatedUnfairLock<Double?>(initialState: nil)
			let client = MicrosoftGraphHTTPClient.mocked(sleeps: sleeps, hooks: .recordingTransferProgress(of: progress, into: fractions))
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 503),
				URLProtocolMock.handler(statusCode: 202, onRequest: { _ in
					fractionAtRetry.withLock { $0 = progress.fractionCompleted }
				})
			]

			_ = try await client.uploadChunk(to: uploadURL, fromFile: fileURL, offset: 0, length: 5, totalLength: 5, progress: progress, onTaskCreation: nil)

			try assertRetryHalvesProgress(fractions.withLock { $0 }, fractionAtRetry: fractionAtRetry.withLock { $0 })
		}

		@Test
		func retriedTransfersHandOverOneTask() async throws {
			let fileURL = try makeLocalFile(in: tmpDirURL, named: "chunk", content: "chunk")
			let downloadTaskCount = OSAllocatedUnfairLock(initialState: 0)
			let uploadTaskCount = OSAllocatedUnfairLock(initialState: 0)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 503), URLProtocolMock.handler(body: "content"), URLProtocolMock.handler(statusCode: 503), URLProtocolMock.handler(statusCode: 202)]

			try await client.downloadContent(of: address, to: tmpDirURL.appending(component: "download", directoryHint: .notDirectory), progress: nil, onTaskCreation: { _ in
				downloadTaskCount.withLock { $0 += 1 }
			})
			_ = try await client.uploadChunk(to: uploadURL, fromFile: fileURL, offset: 0, length: 5, totalLength: 10, progress: nil, onTaskCreation: { _ in
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
			let fileURL = try makeLocalFile(in: tmpDirURL, named: "chunk", content: "chunk")
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 503), { _ in throw URLError(.timedOut) }]

			let error = try await #require(throws: (any Error).self) { try await uploadChunk(from: fileURL) }
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
			let fileURL = try makeLocalFile(in: tmpDirURL, named: "chunk", content: "chunk")
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: #"{"value":[{"id":"1","@microsoft.graph.downloadUrl":"https://content.example.com/a?tempauth=SECRET-LISTED","createdBy":{"user":{"email":"lister@example.com"}}}]}"#),
				URLProtocolMock.handler(statusCode: 201, body: #"{"id":"2","@content.downloadUrl":"https://content.example.com/b?tempauth=SECRET-UPLOADED","createdBy":{"user":{"email":"uploader@example.com"}}}"#)
			]

			_ = try await client.children(of: address, pageSize: 10)
			_ = try await uploadChunk(from: fileURL)

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
			let stagingURL = tmpDirURL.appending(component: "download", directoryHint: .notDirectory)

			try await client.downloadContent(of: address, to: stagingURL, progress: nil, onTaskCreation: nil)

			#expect(try Data("content".utf8) == Data(contentsOf: stagingURL))
			let log = logCapture.joinedMessages
			#expect(logCapture.messages.contains { $0.hasPrefix("MicrosoftGraphHTTPClient: GET https://graph.microsoft.com/v1.0/me/drive/items/1/content") }, "\(log)")
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

			_ = try await client.download(fromDownloadURL: downloadURL, to: tmpDirURL.appending(component: "download", directoryHint: .notDirectory), progress: nil, onTaskCreation: nil)

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
			let errorBody = #"{"error":"https://content.example.com/dl/SECRET-PATH"}"#
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 404, body: errorBody)]

			await #expect(throws: CloudProviderError.itemNotFound) { try await client.downloadContent(of: address, to: tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory), progress: nil, onTaskCreation: nil) }

			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 404, body: errorBody)]
			let downloadURL = try #require(URL(string: "https://content.example.com/dl/PATH"))

			let response = try await client.download(fromDownloadURL: downloadURL, to: tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory), progress: nil, onTaskCreation: nil)

			#expect(response.statusCode == 404)
			#expect(logCapture.messages.count { $0.hasPrefix("--> GET https://content.example.com") } == 1, "\(logCapture.joinedMessages)")
			#expect(!logCapture.joinedMessages.contains("SECRET"), "\(logCapture.joinedMessages)")
		}

		// MARK: - Helpers

		private func uploadChunk(from fileURL: URL) async throws -> MicrosoftGraphAPI.DriveItem? {
			return try await client.uploadChunk(to: uploadURL, fromFile: fileURL, offset: 0, length: 5, totalLength: 5, progress: nil, onTaskCreation: nil)
		}

		private func expectStatusCode(_ statusCode: Int, of error: Error, sourceLocation: SourceLocation = #_sourceLocation) {
			guard case let MicrosoftGraphError.unexpectedHTTPStatusCode(code) = error, code == statusCode else {
				Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
				return
			}
		}
	}
}

extension MicrosoftGraphHTTPClient {
	static func mocked(tokenSource: any BearerTokenSource = OAuthTokenSourceStub(), sleeps: SleepRecorder = SleepRecorder(), hooks: SplitURLSession.Hooks = SplitURLSession.Hooks()) -> MicrosoftGraphHTTPClient {
		return MicrosoftGraphHTTPClient(tokenSource: tokenSource, configuration: URLProtocolMock.configuration(), metadataConfiguration: nil, hooks: hooks, sleep: { sleeps.sleep(for: $0) })
	}
}
