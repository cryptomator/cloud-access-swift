//
//  GoogleDriveClientTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class GoogleDriveClientTests {
		private let tokenSource: OAuthTokenSourceStub
		private let sleeps: SleepRecorder
		private let client: GoogleDriveClient
		private let requests: RequestRecorder
		private let tmpDirURL: URL

		init() throws {
			URLProtocolMock.requestHandler = []
			self.tokenSource = OAuthTokenSourceStub()
			self.sleeps = SleepRecorder()
			self.client = GoogleDriveClient.mocked(tokenSource: tokenSource, sleeps: sleeps)
			self.requests = RequestRecorder()
			self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		// MARK: - Requests

		@Test
		func testBackgroundConfiguration() {
			let configuration = GoogleDriveClient.backgroundConfiguration(sessionIdentifier: "GoogleDriveClientTests", sharedContainerIdentifier: "group.test")

			#expect(configuration.identifier == "GoogleDriveClientTests")
			#expect(configuration.sharedContainerIdentifier == "group.test")
		}

		@Test
		func requestShapes() async throws {
			let record = requests.record
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt"), onRequest: record),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]), onRequest: record),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.folder(id: "D", name: "folder"), onRequest: record),
				URLProtocolMock.handler(statusCode: 204, onRequest: record),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "renamed.txt"), onRequest: record)
			]

			_ = try await client.file(id: "a/b", fields: "name,modifiedTime,size,mimeType")
			_ = try await client.files(query: GoogleDriveClient.query(inFolder: "P"), pageSize: 100, pageToken: "T+1", fields: "nextPageToken,files(id)")
			_ = try await client.createFolder(name: "folder", parentID: "P")
			try await client.delete(id: "F")
			_ = try await client.update(id: "F", name: "renamed.txt", addParents: "NEW", removeParents: "OLD", fields: "id,name")

			let sent = requests.requests
			#expect(sent.map(\.httpMethod) == ["GET", "GET", "POST", "DELETE", "PATCH"])
			#expect(sent.map { $0.url.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? nil } == ["/drive/v3/files/a%2Fb", "/drive/v3/files", "/drive/v3/files", "/drive/v3/files/F", "/drive/v3/files/F"])
			#expect(sent.allSatisfy { $0.url?.host == "www.googleapis.com" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN" })
			#expect(sent.map(GoogleDriveClientTests.queryParameters) == [
				["supportsAllDrives": "true", "fields": "name,modifiedTime,size,mimeType"],
				["q": "'P' in parents and trashed = false", "supportsAllDrives": "true", "includeItemsFromAllDrives": "true", "pageSize": "100", "pageToken": "T+1", "fields": "nextPageToken,files(id)"],
				["supportsAllDrives": "true"],
				["supportsAllDrives": "true"],
				["supportsAllDrives": "true", "addParents": "NEW", "removeParents": "OLD", "fields": "id,name"]
			])
			#expect(try (["name": "folder", "parents": ["P"], "mimeType": "application/vnd.google-apps.folder"] as NSDictionary) == (JSONSerialization.jsonObject(with: URLProtocolMock.body(of: sent[2])) as? NSDictionary))
			#expect(try (["name": "renamed.txt"] as NSDictionary) == (JSONSerialization.jsonObject(with: URLProtocolMock.body(of: sent[4])) as? NSDictionary))
		}

		@Test
		func nameQueryEscapesBackslashesAndQuotes() {
			#expect(GoogleDriveClient.query(inFolder: "P", named: #"it's a \ name"#) == #"'P' in parents and name contains 'it\'s a \\ name' and trashed = false"#)
		}

		@Test
		func aboutRequestsEmailWithoutLoggingIt() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"user":{"emailAddress":"secret@example.com"}}"#, onRequest: requests.record)]

			let about = try await client.about()

			#expect(about.user?.emailAddress == "secret@example.com")
			let request = try #require(requests.requests.first)
			#expect(request.url?.path == "/drive/v3/about")
			#expect(GoogleDriveClientTests.queryParameters(of: request) == ["fields": "user(emailAddress)"])
			#expect(!logCapture.joinedMessages.contains("secret@example.com"), "\(logCapture.joinedMessages)")
		}

		// MARK: - Retries

		@Test
		func unauthorizedRequestIsRefreshedOnce() async throws {
			let record = requests.record
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401, onRequest: record), URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]), onRequest: record)]

			_ = try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)")

			#expect(requests.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer TOKEN", "Bearer REFRESHED"])
			#expect(tokenSource.rejectedTokens == ["TOKEN"])
			#expect(sleeps.durations.isEmpty)
		}

		@Test
		func refreshCountsAsAttempt() async throws {
			URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 503), count: 4) + [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))]

			await #expect(throws: GoogleDriveError.apiError(statusCode: 401, reason: nil, message: nil)) { try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)") }
			#expect(URLProtocolMock.requestHandler.count == 1)
			#expect(tokenSource.rejectedTokens.isEmpty)
		}

		@Test
		func rateLimitIsRetriedButPermissionErrorIsNot() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 403, body: GoogleDriveMockResponse.error(status: 403, reason: "userRateLimitExceeded"), headerFields: ["Retry-After": "3"]),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))
			]

			_ = try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)")

			#expect([.seconds(3)] == sleeps.durations)

			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 403, body: GoogleDriveMockResponse.error(status: 403, reason: "insufficientFilePermissions")), URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))]

			await #expect(throws: GoogleDriveError.apiError(statusCode: 403, reason: "insufficientFilePermissions", message: "Error")) { try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)") }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func transportErrorIsRetriedOnlyForGet() async throws {
			URLProtocolMock.requestHandler = [{ _ in throw URLError(.networkConnectionLost) }, URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))]

			_ = try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)")

			#expect(sleeps.durations.count == 1)

			URLProtocolMock.requestHandler = [{ _ in throw URLError(.networkConnectionLost) }, URLProtocolMock.handler(body: GoogleDriveMockResponse.folder(id: "D", name: "folder"))]

			await #expect(throws: CloudProviderError.noInternetConnection) { try await client.createFolder(name: "folder", parentID: "P") }
			#expect(URLProtocolMock.requestHandler.count == 1)
			#expect(sleeps.durations.count == 1)
		}

		@Test
		func everyRetryableStatusIsRetried() async throws {
			let responses = [408, 429, 500, 502, 503, 504].map { URLProtocolMock.handler(statusCode: $0) } + ["userRateLimitExceeded", "rateLimitExceeded"].map { URLProtocolMock.handler(statusCode: 403, body: GoogleDriveMockResponse.error(status: 403, reason: $0)) }
			for response in responses {
				URLProtocolMock.requestHandler = [response, URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))]

				_ = try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)")

				#expect(URLProtocolMock.requestHandler.isEmpty)
			}
			#expect(responses.count == sleeps.durations.count)
		}

		@Test
		func transportErrorIsRetriedUntilFiveAttempts() async throws {
			URLProtocolMock.requestHandler = Array(repeating: { _ in throw URLError(.networkConnectionLost) }, count: 5) + [URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))]

			await #expect(throws: CloudProviderError.noInternetConnection) { try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)") }
			#expect(URLProtocolMock.requestHandler.count == 1)
			#expect(sleeps.durations.count == 4)
		}

		// MARK: - Cancellation

		@Test
		func metadataBodyOverLimitFails() async throws {
			URLProtocolMock.requestHandler = [{ request in
				(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(count: HTTPClientSupport.maxMetadataBodyLength + 1))
			}]

			let error = try await #require(throws: (any Error).self) { try await client.about() }
			guard case SplitURLSessionError.responseBodyTooLarge = error else {
				Issue.record("Unexpected error: \(error)")
				return
			}
		}

		@Test
		func cancelledTaskGetsNoToken() async throws {
			let accessTokenCount = OSAllocatedUnfairLock(initialState: 0)
			let client = GoogleDriveClient.mocked(tokenSource: OAuthTokenSourceStub(onAccessToken: { accessTokenCount.withLock { $0 += 1 } }), sleeps: sleeps)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))]

			await #expect(throws: CancellationError.self) {
				try await cancellingValue(of: Task {
					withUnsafeCurrentTask { $0?.cancel() }
					return try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)")
				})
			}
			#expect(accessTokenCount.withLock { $0 } == 0)
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func cancellationWhileGettingTokenStopsFirstAttempt() async throws {
			let client = GoogleDriveClient.mocked(tokenSource: OAuthTokenSourceStub(onAccessToken: { withUnsafeCurrentTask { $0?.cancel() } }), sleeps: sleeps)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))]

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: Task { try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)") }) }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func cancellationDuringRefreshStopsRetry() async throws {
			let client = GoogleDriveClient.mocked(tokenSource: OAuthTokenSourceStub(onRefresh: { withUnsafeCurrentTask { $0?.cancel() } }), sleeps: sleeps)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))]

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: Task { try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)") }) }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func cancellationDuringRefreshStopsUpload() async throws {
			let localURL = try makeLocalFile(content: "file content")
			let client = GoogleDriveClient.mocked(tokenSource: OAuthTokenSourceStub(onRefresh: { withUnsafeCurrentTask { $0?.cancel() } }), sleeps: sleeps)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401), GoogleDriveMockResponse.session(), URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12))]

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: Task { try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil) }) }
			#expect(URLProtocolMock.requestHandler.count == 2)
		}

		@Test
		func taskCancelledDuringAttemptIsNotRefreshed() async throws {
			let refreshCount = OSAllocatedUnfairLock(initialState: 0)
			let client = GoogleDriveClient.mocked(tokenSource: OAuthTokenSourceStub(onRefresh: { refreshCount.withLock { $0 += 1 } }), sleeps: sleeps)
			let canceller = TaskCanceller<Void>()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401, onRequest: { _ in
				canceller.cancel()
			}), URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))]

			let task = canceller.start {
				_ = try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)")
			}

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: task) }
			#expect(refreshCount.withLock { $0 } == 0)
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func uploadCancelledDuringAttemptIsNotRefreshed() async throws {
			let localURL = try makeLocalFile(content: "file content")
			let refreshCount = OSAllocatedUnfairLock(initialState: 0)
			let client = GoogleDriveClient.mocked(tokenSource: OAuthTokenSourceStub(onRefresh: { refreshCount.withLock { $0 += 1 } }), sleeps: sleeps)
			let canceller = TaskCanceller<Void>()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401, onRequest: { _ in
				canceller.cancel()
			}), GoogleDriveMockResponse.session(), URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12))]

			let task = canceller.start {
				_ = try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)
			}

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: task) }
			#expect(refreshCount.withLock { $0 } == 0)
			#expect(URLProtocolMock.requestHandler.count == 2)
		}

		// MARK: - Downloads

		@Test
		func retriedDownloadHandsOverOneTask() async throws {
			for firstStatus in [503, 401] {
				let taskCount = OSAllocatedUnfairLock(initialState: 0)
				let stagingURL = tmpDirURL.appendingPathComponent("download-\(firstStatus)")
				URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: firstStatus, onRequest: requests.record), URLProtocolMock.handler(body: "content", onRequest: requests.record)]

				try await client.download(fileID: "F", to: stagingURL, progress: nil, onTaskCreation: { _ in
					taskCount.withLock { $0 += 1 }
				})

				#expect(try Data("content".utf8) == Data(contentsOf: stagingURL), "\(firstStatus)")
				#expect(taskCount.withLock { $0 } == 1, "\(firstStatus)")
			}
			let request = try #require(requests.requests.first)
			#expect(request.url?.path == "/download/drive/v3/files/F")
			#expect(GoogleDriveClientTests.queryParameters(of: request) == ["alt": "media", "supportsAllDrives": "true"])
		}

		@Test
		func downloadLogsAPIPathAndOnlyOriginOfRedirectTarget() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 302, headerFields: ["Location": "https://drive.usercontent.google.com/SECRET-PATH/download"]),
				URLProtocolMock.handler(body: "content")
			]

			try await client.download(fileID: "F", to: tmpDirURL.appendingPathComponent("download"), progress: nil, onTaskCreation: nil)

			let log = logCapture.joinedMessages
			#expect(logCapture.messages.contains("--> GET https://www.googleapis.com/download/drive/v3/files/F?alt=<redacted>&supportsAllDrives=<redacted>"), "\(log)")
			#expect(logCapture.messages.contains("<-- 200 no error https://drive.usercontent.google.com/<redacted>"), "\(log)")
			#expect(!log.contains("SECRET"), "\(log)")
		}

		@Test
		func bodiesOfDownloadsAreNotLogged() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 302, headerFields: ["Location": "https://drive.usercontent.google.com/download?id=F&token=TOKEN"]),
				URLProtocolMock.handler(statusCode: 404, body: "<html>https://drive.usercontent.google.com/download?id=F&token=SECRET-TOKEN</html>")
			]

			await #expect(throws: GoogleDriveError.apiError(statusCode: 404, reason: nil, message: nil)) { try await client.download(fileID: "F", to: tmpDirURL.appendingPathComponent("download"), progress: nil, onTaskCreation: nil) }

			#expect(logCapture.messages.contains { $0.hasPrefix("<-- 404 ") && $0.contains("https://drive.usercontent.google.com") }, "\(logCapture.joinedMessages)")
			#expect(!logCapture.joinedMessages.contains("SECRET"), "\(logCapture.joinedMessages)")
		}

		@Test
		func errorMessageFromAnotherOriginIsDropped() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 302, headerFields: ["Location": "https://drive.usercontent.google.com/download?id=F&token=TOKEN"]),
				URLProtocolMock.handler(statusCode: 404, body: #"{"error":{"code":404,"message":"https://drive.usercontent.google.com/download?id=F&token=SECRET-TOKEN","errors":[{"reason":"notFound"}]}}"#)
			]

			await #expect(throws: GoogleDriveError.apiError(statusCode: 404, reason: "notFound", message: nil)) { try await client.download(fileID: "F", to: tmpDirURL.appendingPathComponent("download"), progress: nil, onTaskCreation: nil) }
		}

		// MARK: - Uploads

		@Test
		func uploadCreatesSessionAndPutsFile() async throws {
			let localURL = try makeLocalFile(content: "file content")
			let record = requests.record
			URLProtocolMock.requestHandler = [
				GoogleDriveMockResponse.session(onRequest: record),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12), onRequest: record)
			]

			let file = try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)

			#expect(file.id == "F")
			let (sessionRequest, put) = try (#require(requests.requests.first), #require(requests.requests.last))
			#expect(sessionRequest.httpMethod == "POST")
			#expect(sessionRequest.url?.path == "/upload/drive/v3/files")
			#expect(GoogleDriveClientTests.queryParameters(of: sessionRequest) == ["uploadType": "resumable", "supportsAllDrives": "true", "fields": "id,name,modifiedTime,size,mimeType"])
			#expect(sessionRequest.value(forHTTPHeaderField: "X-Upload-Content-Type") == "application/octet-stream")
			#expect(sessionRequest.value(forHTTPHeaderField: "X-Upload-Content-Length") == "12")
			#expect(try (["name": "file.txt", "parents": ["P"]] as NSDictionary) == (JSONSerialization.jsonObject(with: URLProtocolMock.body(of: sessionRequest)) as? NSDictionary))
			#expect(put.httpMethod == "PUT")
			#expect(GoogleDriveMockResponse.sessionURL == put.url?.absoluteString)
			#expect(put.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
			#expect(put.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN")
			#expect(Data("file content".utf8) == URLProtocolMock.body(of: put))
		}

		@Test
		func uploadOfExistingFilePatchesIt() async throws {
			let localURL = try makeLocalFile(content: "file content")
			URLProtocolMock.requestHandler = [GoogleDriveMockResponse.session(onRequest: requests.record), URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12))]

			_ = try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: "F", progress: nil, onTaskCreation: nil)

			let sessionRequest = try #require(requests.requests.first)
			#expect(sessionRequest.httpMethod == "PATCH")
			#expect(sessionRequest.url?.path == "/upload/drive/v3/files/F")
			#expect(try ([:] as NSDictionary) == (JSONSerialization.jsonObject(with: URLProtocolMock.body(of: sessionRequest)) as? NSDictionary))
		}

		@Test
		func failedPutIsSentAgainToSameSessionIfNoByteArrived() async throws {
			let localURL = try makeLocalFile(content: "file content")
			let record = requests.record
			let tasks = TaskRecorder()
			URLProtocolMock.requestHandler = [
				GoogleDriveMockResponse.session(onRequest: record),
				URLProtocolMock.handler(statusCode: 503, headerFields: ["Retry-After": "30"], onRequest: record),
				URLProtocolMock.handler(statusCode: 308, onRequest: record),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12), onRequest: record)
			]

			let file = try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: tasks.record)

			#expect(file.id == "F")
			let sent = requests.requests
			#expect(sent.map(\.httpMethod) == ["POST", "PUT", "PUT", "PUT"])
			#expect(sent[2].value(forHTTPHeaderField: "Content-Range") == "bytes */12")
			#expect(Data("file content".utf8) == URLProtocolMock.body(of: sent[3]))
			#expect([.seconds(30)] == sleeps.durations)
			#expect([GoogleDriveMockResponse.sessionURL] == tasks.urls)
		}

		@Test
		func statusQueryReturnsFileThatFailedPutCreated() async throws {
			let localURL = try makeLocalFile(content: "file content")
			URLProtocolMock.requestHandler = [
				GoogleDriveMockResponse.session(),
				URLProtocolMock.handler(statusCode: 503),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12)),
				GoogleDriveMockResponse.session()
			]

			let file = try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)

			#expect(file.id == "F")
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func taskOfPutIsHandedOverAfterRetriedSessionRequest() async throws {
			let localURL = try makeLocalFile(content: "file content")
			let tasks = TaskRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 503),
				GoogleDriveMockResponse.session(),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12))
			]

			_ = try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: tasks.record)

			#expect([GoogleDriveMockResponse.sessionURL] == tasks.urls)
		}

		@Test
		func uploadStopsAfterFiveRequests() async throws {
			let localURL = try makeLocalFile(content: "file content")
			URLProtocolMock.requestHandler = [GoogleDriveMockResponse.session()] + Array(repeating: URLProtocolMock.handler(statusCode: 503, body: GoogleDriveMockResponse.error(status: 503, reason: "backendError")), count: 5)

			await #expect(throws: GoogleDriveError.apiError(statusCode: 503, reason: "backendError", message: "Error")) { try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.count == 1)

			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(statusCode: 401), GoogleDriveMockResponse.session()]

			await #expect(throws: GoogleDriveError.apiError(statusCode: 401, reason: nil, message: nil)) { try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.count == 1)
			#expect(tokenSource.rejectedTokens == ["TOKEN"])
		}

		/// The session request is sent at most 4 times, so that the `PUT` has an attempt left. The upload doesn't wait before a request that it won't send.
		@Test
		func exhaustedSessionRequestFailsWithoutWaitingAgain() async throws {
			let localURL = try makeLocalFile(content: "file content")
			URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 503, body: GoogleDriveMockResponse.error(status: 503, reason: "backendError")), count: 4) + [GoogleDriveMockResponse.session()]

			await #expect(throws: GoogleDriveError.apiError(statusCode: 503, reason: "backendError", message: "Error")) { try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.count == 1)
			#expect(sleeps.durations.count == 3)
		}

		@Test
		func exhaustedSessionRequestFailsWithoutWaitingAfterTransportError() async throws {
			let localURL = try makeLocalFile(content: "file content")
			URLProtocolMock.requestHandler = Array(repeating: { _ in throw URLError(.networkConnectionLost) }, count: 4) + [GoogleDriveMockResponse.session()]

			await #expect(throws: CloudProviderError.noInternetConnection) { try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.count == 1)
			#expect(sleeps.durations.count == 3)
		}

		@Test
		func exhaustedSessionRequestIsNotRefreshed() async throws {
			let localURL = try makeLocalFile(content: "file content")
			URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 503), count: 3) + [URLProtocolMock.handler(statusCode: 401), GoogleDriveMockResponse.session()]

			await #expect(throws: GoogleDriveError.apiError(statusCode: 401, reason: nil, message: nil)) { try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.count == 1)
			#expect(tokenSource.rejectedTokens.isEmpty)
		}

		@Test
		func unauthorizedLastPutIsNotRefreshed() async throws {
			let localURL = try makeLocalFile(content: "file content")
			URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 503), count: 3) + [GoogleDriveMockResponse.session(), URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(statusCode: 308)]

			await #expect(throws: GoogleDriveError.apiError(statusCode: 401, reason: nil, message: nil)) { try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.count == 1)
			#expect(tokenSource.rejectedTokens.isEmpty)
		}

		@Test
		func exhaustedUploadDoesNotWaitToSendFileAgain() async throws {
			let localURL = try makeLocalFile(content: "file content")
			URLProtocolMock.requestHandler = [
				GoogleDriveMockResponse.session(),
				URLProtocolMock.handler(statusCode: 503),
				URLProtocolMock.handler(statusCode: 308),
				URLProtocolMock.handler(statusCode: 503),
				URLProtocolMock.handler(statusCode: 308),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12))
			]

			await #expect(throws: GoogleDriveError.apiError(statusCode: 503, reason: nil, message: nil)) { try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.count == 1)
			#expect(sleeps.durations.count == 2)
		}

		@Test
		func exhaustedPutDoesNotWaitToQueryStatus() async throws {
			let localURL = try makeLocalFile(content: "file content")
			URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 503), count: 3) + [GoogleDriveMockResponse.session(), URLProtocolMock.handler(statusCode: 503), URLProtocolMock.handler(statusCode: 308)]

			await #expect(throws: GoogleDriveError.apiError(statusCode: 503, reason: nil, message: nil)) { try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.count == 1)
			#expect(sleeps.durations.count == 3)
		}

		@Test
		func unauthorizedPutIsRefreshedAndSentAgain() async throws {
			let localURL = try makeLocalFile(content: "file content")
			let record = requests.record
			URLProtocolMock.requestHandler = [
				GoogleDriveMockResponse.session(onRequest: record),
				URLProtocolMock.handler(statusCode: 401, onRequest: record),
				URLProtocolMock.handler(statusCode: 308, onRequest: record),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12), onRequest: record)
			]

			let file = try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)

			#expect(file.id == "F")
			#expect(requests.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer TOKEN", "Bearer TOKEN", "Bearer REFRESHED", "Bearer REFRESHED"])
			#expect(tokenSource.rejectedTokens == ["TOKEN"])
		}

		/// The session request and the status query create nothing, so a transport error doesn't end the upload.
		@Test
		func transportErrorsOfRequestsThatCreateNothingAreRetried() async throws {
			let localURL = try makeLocalFile(content: "file content")
			URLProtocolMock.requestHandler = [
				{ _ in throw URLError(.networkConnectionLost) },
				GoogleDriveMockResponse.session(),
				URLProtocolMock.handler(statusCode: 503),
				{ _ in throw URLError(.networkConnectionLost) },
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12))
			]

			let file = try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)

			#expect(file.id == "F")
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func failedStatusQueryEndsUpload() async throws {
			let localURL = try makeLocalFile(content: "file content")
			URLProtocolMock.requestHandler = [
				GoogleDriveMockResponse.session(),
				URLProtocolMock.handler(statusCode: 503),
				URLProtocolMock.handler(statusCode: 404, body: GoogleDriveMockResponse.error(status: 404, reason: "notFound")),
				GoogleDriveMockResponse.session()
			]

			await #expect(throws: GoogleDriveError.apiError(statusCode: 404, reason: "notFound", message: "Error")) { try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func sessionURLOutsideGoogleIsRejected() async throws {
			let localURL = try makeLocalFile(content: "file content")
			for location in ["https://example.com/upload", "http://www.googleapis.com/upload", "https://evilgoogleapis.com/upload"] {
				URLProtocolMock.requestHandler = [URLProtocolMock.handler(headerFields: ["Location": location]), URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt"))]

				await #expect(throws: GoogleDriveError.unexpectedContent, "\(location)") { try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil) }
				#expect(URLProtocolMock.requestHandler.count == 1, "\(location)")
			}
		}

		@Test
		func partialUploadEndsWithoutNewSession() async throws {
			let localURL = try makeLocalFile(content: "file content")
			URLProtocolMock.requestHandler = [
				GoogleDriveMockResponse.session(),
				{ _ in throw URLError(.networkConnectionLost) },
				URLProtocolMock.handler(statusCode: 308, headerFields: ["Range": "bytes=0-4"]),
				GoogleDriveMockResponse.session()
			]

			await #expect(throws: CloudProviderError.noInternetConnection) { try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func uploadLogsNeitherUploadIDNorItsHeader() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			let localURL = try makeLocalFile(content: "file content")
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(headerFields: ["Location": GoogleDriveMockResponse.sessionURL, "X-GUploader-UploadID": "SECRET-HEADER-ID"]),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12), headerFields: ["X-GUploader-UploadID": "SECRET-HEADER-ID"])
			]

			_ = try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)

			let log = logCapture.joinedMessages
			#expect(log.contains("https://www.googleapis.com"), "\(log)")
			for secret in ["SECRET-UPLOAD-ID", "SECRET-HEADER-ID"] {
				#expect(!log.contains(secret), "\(secret) in \(log)")
			}
		}

		// MARK: - Helpers

		private func makeLocalFile(content: String) throws -> URL {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
			try Data(content.utf8).write(to: localURL)
			return localURL
		}

		private static func queryParameters(of request: URLRequest) -> [String: String] {
			return request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery }.map(URLProtocolMock.parameters(inFormEncoded:)) ?? [:]
		}
	}
}

/// Records the URLs of the tasks that `onTaskCreation` gets.
final class TaskRecorder: Sendable {
	private let recordedURLs = OSAllocatedUnfairLock(initialState: [String?]())

	var urls: [String?] {
		return recordedURLs.withLock { $0 }
	}

	var record: @concurrent @Sendable (URLSessionTask) async -> Void {
		return { task in
			let url = task.originalRequest?.url?.absoluteString
			self.recordedURLs.withLock { $0.append(url) }
		}
	}
}

extension GoogleDriveClient {
	static func mocked(tokenSource: any OAuthTokenSource = OAuthTokenSourceStub(), sleeps: SleepRecorder = SleepRecorder(), hooks: SplitURLSession.Hooks = SplitURLSession.Hooks()) -> GoogleDriveClient {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		return GoogleDriveClient(tokenSource: tokenSource, configuration: configuration, metadataConfiguration: nil, hooks: hooks, sleep: { sleeps.sleep(for: $0) })
	}
}

enum GoogleDriveMockResponse {
	static let modifiedTime = "2026-10-20T11:05:00.123Z"
	static let sessionURL = "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=SECRET-UPLOAD-ID"

	static func file(id: String, name: String, size: Int = 7) -> String {
		return #"{"id":"\#(id)","name":"\#(name)","mimeType":"text/plain","modifiedTime":"\#(modifiedTime)","size":"\#(size)"}"#
	}

	static func folder(id: String, name: String) -> String {
		return #"{"id":"\#(id)","name":"\#(name)","mimeType":"application/vnd.google-apps.folder","modifiedTime":"\#(modifiedTime)"}"#
	}

	static func shortcut(id: String, name: String, targetID: String, targetMimeType: String) -> String {
		return #"{"id":"\#(id)","name":"\#(name)","mimeType":"application/vnd.google-apps.shortcut","modifiedTime":"\#(modifiedTime)","shortcutDetails":{"targetId":"\#(targetID)","targetMimeType":"\#(targetMimeType)"}}"#
	}

	static func files(_ files: [String], nextPageToken: String? = nil) -> String {
		return #"{"files":[\#(files.joined(separator: ","))]\#(nextPageToken.map { #","nextPageToken":"\#($0)""# } ?? "")}"#
	}

	static func error(status: Int, reason: String) -> String {
		return #"{"error":{"code":\#(status),"message":"Error","errors":[{"domain":"global","reason":"\#(reason)","message":"Error"}]}}"#
	}

	/// The response of a session request, with the session URL in `Location`.
	static func session(onRequest: @escaping @Sendable (URLRequest) -> Void = { _ in }) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) {
		return URLProtocolMock.handler(headerFields: ["Location": sessionURL], onRequest: onRequest)
	}
}
