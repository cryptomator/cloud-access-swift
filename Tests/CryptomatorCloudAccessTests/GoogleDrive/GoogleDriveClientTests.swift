//
//  GoogleDriveClientTests.swift
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

class GoogleDriveClientTests: XCTestCase {
	private var tokenSource: OAuthTokenSourceStub!
	private var sleeps: SleepRecorder!
	private var client: GoogleDriveClient!
	private var requests: RequestRecorder!
	private var tmpDirURL: URL!

	override func setUpWithError() throws {
		tokenSource = OAuthTokenSourceStub()
		sleeps = SleepRecorder()
		client = GoogleDriveClient.mocked(tokenSource: tokenSource, sleeps: sleeps)
		requests = RequestRecorder()
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - Requests

	func testRequestShapes() async throws {
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
		XCTAssertEqual(["GET", "GET", "POST", "DELETE", "PATCH"], sent.map(\.httpMethod))
		XCTAssertEqual(["/drive/v3/files/a%2Fb", "/drive/v3/files", "/drive/v3/files", "/drive/v3/files/F", "/drive/v3/files/F"], sent.map { $0.url.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? nil })
		XCTAssertTrue(sent.allSatisfy { $0.url?.host == "www.googleapis.com" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN" })
		XCTAssertEqual([
			["supportsAllDrives": "true", "fields": "name,modifiedTime,size,mimeType"],
			["q": "'P' in parents and trashed = false", "supportsAllDrives": "true", "includeItemsFromAllDrives": "true", "pageSize": "100", "pageToken": "T+1", "fields": "nextPageToken,files(id)"],
			["supportsAllDrives": "true"],
			["supportsAllDrives": "true"],
			["supportsAllDrives": "true", "addParents": "NEW", "removeParents": "OLD", "fields": "id,name"]
		], sent.map(GoogleDriveClientTests.queryParameters))
		XCTAssertEqual(["name": "folder", "parents": ["P"], "mimeType": "application/vnd.google-apps.folder"] as NSDictionary, try JSONSerialization.jsonObject(with: URLProtocolMock.body(of: sent[2])) as? NSDictionary)
		XCTAssertEqual(["name": "renamed.txt"] as NSDictionary, try JSONSerialization.jsonObject(with: URLProtocolMock.body(of: sent[4])) as? NSDictionary)
	}

	func testNameQueryEscapesBackslashesAndQuotes() {
		XCTAssertEqual(#"'P' in parents and name contains 'it\'s a \\ name' and trashed = false"#, GoogleDriveClient.query(inFolder: "P", named: #"it's a \ name"#))
	}

	func testAboutRequestsEmailWithoutLoggingIt() async throws {
		let logCapture = LogCapture.start()
		defer {
			logCapture.stop()
		}
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"user":{"emailAddress":"secret@example.com"}}"#, onRequest: requests.record)]

		let about = try await client.about()

		XCTAssertEqual("secret@example.com", about.user?.emailAddress)
		let request = try XCTUnwrap(requests.requests.first)
		XCTAssertEqual("/drive/v3/about", request.url?.path)
		XCTAssertEqual(["fields": "user(emailAddress)"], GoogleDriveClientTests.queryParameters(of: request))
		XCTAssertFalse(logCapture.joinedMessages.contains("secret@example.com"), logCapture.joinedMessages)
	}

	// MARK: - Retries

	func testUnauthorizedRequestIsRefreshedOnce() async throws {
		let record = requests.record
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401, onRequest: record), URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]), onRequest: record)]

		_ = try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)")

		XCTAssertEqual(["Bearer TOKEN", "Bearer REFRESHED"], requests.requests.map { $0.value(forHTTPHeaderField: "Authorization") })
		XCTAssertEqual(["TOKEN"], tokenSource.rejectedTokens)
		XCTAssertTrue(sleeps.durations.isEmpty)
	}

	func testRefreshCountsAsAttempt() async throws {
		URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 503), count: 4) + [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))]

		await XCTAssertThrowsErrorAsync(try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)")) { error in
			XCTAssertEqual(.apiError(statusCode: 401, reason: nil, message: nil), error as? GoogleDriveError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
		XCTAssertTrue(tokenSource.rejectedTokens.isEmpty)
	}

	func testRateLimitIsRetriedButPermissionErrorIsNot() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 403, body: GoogleDriveMockResponse.error(status: 403, reason: "userRateLimitExceeded"), headerFields: ["Retry-After": "3"]),
			URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))
		]

		_ = try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)")

		XCTAssertEqual([.seconds(3)], sleeps.durations)

		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 403, body: GoogleDriveMockResponse.error(status: 403, reason: "insufficientFilePermissions")), URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))]

		await XCTAssertThrowsErrorAsync(try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)")) { error in
			XCTAssertEqual(.apiError(statusCode: 403, reason: "insufficientFilePermissions", message: "Error"), error as? GoogleDriveError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testTransportErrorIsRetriedOnlyForGet() async throws {
		URLProtocolMock.requestHandler = [{ _ in throw URLError(.networkConnectionLost) }, URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))]

		_ = try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)")

		XCTAssertEqual(1, sleeps.durations.count)

		URLProtocolMock.requestHandler = [{ _ in throw URLError(.networkConnectionLost) }, URLProtocolMock.handler(body: GoogleDriveMockResponse.folder(id: "D", name: "folder"))]

		await XCTAssertThrowsErrorAsync(try await client.createFolder(name: "folder", parentID: "P")) { error in
			XCTAssertEqual(.noInternetConnection, error as? CloudProviderError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
		XCTAssertEqual(1, sleeps.durations.count)
	}

	func testEveryRetryableStatusIsRetried() async throws {
		let responses = [408, 429, 500, 502, 503, 504].map { URLProtocolMock.handler(statusCode: $0) } + ["userRateLimitExceeded", "rateLimitExceeded"].map { URLProtocolMock.handler(statusCode: 403, body: GoogleDriveMockResponse.error(status: 403, reason: $0)) }
		for response in responses {
			URLProtocolMock.requestHandler = [response, URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))]

			_ = try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)")

			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
		}
		XCTAssertEqual(responses.count, sleeps.durations.count)
	}

	func testTransportErrorIsRetriedUntilFiveAttempts() async throws {
		URLProtocolMock.requestHandler = Array(repeating: { _ in throw URLError(.networkConnectionLost) }, count: 5) + [URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))]

		await XCTAssertThrowsErrorAsync(try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)")) { error in
			XCTAssertEqual(.noInternetConnection, error as? CloudProviderError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
		XCTAssertEqual(4, sleeps.durations.count)
	}

	// MARK: - Cancellation

	func testCancelledTaskGetsNoToken() async throws {
		let accessTokenCount = OSAllocatedUnfairLock(initialState: 0)
		let client = GoogleDriveClient.mocked(tokenSource: OAuthTokenSourceStub(onAccessToken: { accessTokenCount.withLock { $0 += 1 } }), sleeps: sleeps)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))]

		await XCTAssertThrowsErrorAsync(try await value(of: Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)")
		})) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(0, accessTokenCount.withLock { $0 })
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testCancellationWhileGettingTokenStopsFirstAttempt() async throws {
		let client = GoogleDriveClient.mocked(tokenSource: OAuthTokenSourceStub(onAccessToken: { withUnsafeCurrentTask { $0?.cancel() } }), sleeps: sleeps)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))]

		await XCTAssertThrowsErrorAsync(try await value(of: Task { try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)") })) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testCancellationDuringRefreshStopsRetry() async throws {
		let client = GoogleDriveClient.mocked(tokenSource: OAuthTokenSourceStub(onRefresh: { withUnsafeCurrentTask { $0?.cancel() } }), sleeps: sleeps)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: GoogleDriveMockResponse.files([]))]

		await XCTAssertThrowsErrorAsync(try await value(of: Task { try await client.files(query: "q", pageSize: nil, pageToken: nil, fields: "files(id)") })) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testCancellationDuringRefreshStopsUpload() async throws {
		let localURL = try makeLocalFile(content: "file content")
		let client = GoogleDriveClient.mocked(tokenSource: OAuthTokenSourceStub(onRefresh: { withUnsafeCurrentTask { $0?.cancel() } }), sleeps: sleeps)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401), GoogleDriveMockResponse.session(), URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12))]

		await XCTAssertThrowsErrorAsync(try await value(of: Task { try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil) })) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(2, URLProtocolMock.requestHandler.count)
	}

	// MARK: - Downloads

	func testRetriedDownloadHandsOverOneTask() async throws {
		for firstStatus in [503, 401] {
			let taskCount = OSAllocatedUnfairLock(initialState: 0)
			let stagingURL = tmpDirURL.appendingPathComponent("download-\(firstStatus)")
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: firstStatus, onRequest: requests.record), URLProtocolMock.handler(body: "content", onRequest: requests.record)]

			try await client.download(fileID: "F", to: stagingURL, progress: nil, onTaskCreation: { _ in
				taskCount.withLock { $0 += 1 }
			})

			XCTAssertEqual(Data("content".utf8), try Data(contentsOf: stagingURL), "\(firstStatus)")
			XCTAssertEqual(1, taskCount.withLock { $0 }, "\(firstStatus)")
		}
		let request = try XCTUnwrap(requests.requests.first)
		XCTAssertEqual("/download/drive/v3/files/F", request.url?.path)
		XCTAssertEqual(["alt": "media", "supportsAllDrives": "true"], GoogleDriveClientTests.queryParameters(of: request))
	}

	// MARK: - Uploads

	func testUploadCreatesSessionAndPutsFile() async throws {
		let localURL = try makeLocalFile(content: "file content")
		let record = requests.record
		URLProtocolMock.requestHandler = [
			GoogleDriveMockResponse.session(onRequest: record),
			URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12), onRequest: record)
		]

		let file = try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)

		XCTAssertEqual("F", file.id)
		let (sessionRequest, put) = try (XCTUnwrap(requests.requests.first), XCTUnwrap(requests.requests.last))
		XCTAssertEqual("POST", sessionRequest.httpMethod)
		XCTAssertEqual("/upload/drive/v3/files", sessionRequest.url?.path)
		XCTAssertEqual(["uploadType": "resumable", "supportsAllDrives": "true", "fields": "id,name,modifiedTime,size,mimeType"], GoogleDriveClientTests.queryParameters(of: sessionRequest))
		XCTAssertEqual("application/octet-stream", sessionRequest.value(forHTTPHeaderField: "X-Upload-Content-Type"))
		XCTAssertEqual("12", sessionRequest.value(forHTTPHeaderField: "X-Upload-Content-Length"))
		XCTAssertEqual(["name": "file.txt", "parents": ["P"]] as NSDictionary, try JSONSerialization.jsonObject(with: URLProtocolMock.body(of: sessionRequest)) as? NSDictionary)
		XCTAssertEqual("PUT", put.httpMethod)
		XCTAssertEqual(GoogleDriveMockResponse.sessionURL, put.url?.absoluteString)
		XCTAssertEqual("application/octet-stream", put.value(forHTTPHeaderField: "Content-Type"))
		XCTAssertEqual("Bearer TOKEN", put.value(forHTTPHeaderField: "Authorization"))
		XCTAssertEqual(Data("file content".utf8), URLProtocolMock.body(of: put))
	}

	func testUploadOfExistingFilePatchesIt() async throws {
		let localURL = try makeLocalFile(content: "file content")
		URLProtocolMock.requestHandler = [GoogleDriveMockResponse.session(onRequest: requests.record), URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12))]

		_ = try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: "F", progress: nil, onTaskCreation: nil)

		let sessionRequest = try XCTUnwrap(requests.requests.first)
		XCTAssertEqual("PATCH", sessionRequest.httpMethod)
		XCTAssertEqual("/upload/drive/v3/files/F", sessionRequest.url?.path)
		XCTAssertEqual([:] as NSDictionary, try JSONSerialization.jsonObject(with: URLProtocolMock.body(of: sessionRequest)) as? NSDictionary)
	}

	func testFailedPutIsSentAgainToSameSessionIfNoByteArrived() async throws {
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

		XCTAssertEqual("F", file.id)
		let sent = requests.requests
		XCTAssertEqual(["POST", "PUT", "PUT", "PUT"], sent.map(\.httpMethod))
		XCTAssertEqual("bytes */12", sent[2].value(forHTTPHeaderField: "Content-Range"))
		XCTAssertEqual(Data("file content".utf8), URLProtocolMock.body(of: sent[3]))
		XCTAssertEqual([.seconds(30)], sleeps.durations)
		XCTAssertEqual([GoogleDriveMockResponse.sessionURL], tasks.urls)
	}

	func testStatusQueryReturnsFileThatFailedPutCreated() async throws {
		let localURL = try makeLocalFile(content: "file content")
		URLProtocolMock.requestHandler = [
			GoogleDriveMockResponse.session(),
			URLProtocolMock.handler(statusCode: 503),
			URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12)),
			GoogleDriveMockResponse.session()
		]

		let file = try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)

		XCTAssertEqual("F", file.id)
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testTaskOfPutIsHandedOverAfterRetriedSessionRequest() async throws {
		let localURL = try makeLocalFile(content: "file content")
		let tasks = TaskRecorder()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 503),
			GoogleDriveMockResponse.session(),
			URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12))
		]

		_ = try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: tasks.record)

		XCTAssertEqual([GoogleDriveMockResponse.sessionURL], tasks.urls)
	}

	func testUploadStopsAfterFiveRequests() async throws {
		let localURL = try makeLocalFile(content: "file content")
		URLProtocolMock.requestHandler = [GoogleDriveMockResponse.session()] + Array(repeating: URLProtocolMock.handler(statusCode: 503, body: GoogleDriveMockResponse.error(status: 503, reason: "backendError")), count: 5)

		await XCTAssertThrowsErrorAsync(try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.apiError(statusCode: 503, reason: "backendError", message: "Error"), error as? GoogleDriveError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)

		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(statusCode: 401), GoogleDriveMockResponse.session()]

		await XCTAssertThrowsErrorAsync(try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.apiError(statusCode: 401, reason: nil, message: nil), error as? GoogleDriveError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
		XCTAssertEqual(["TOKEN"], tokenSource.rejectedTokens)
	}

	/// The session request is sent at most 4 times, so that the `PUT` has an attempt left. The upload doesn't wait before a request that it won't send.
	func testExhaustedSessionRequestFailsWithoutWaitingAgain() async throws {
		let localURL = try makeLocalFile(content: "file content")
		URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 503, body: GoogleDriveMockResponse.error(status: 503, reason: "backendError")), count: 4) + [GoogleDriveMockResponse.session()]

		await XCTAssertThrowsErrorAsync(try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.apiError(statusCode: 503, reason: "backendError", message: "Error"), error as? GoogleDriveError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
		XCTAssertEqual(3, sleeps.durations.count)
	}

	func testExhaustedSessionRequestFailsWithoutWaitingAfterTransportError() async throws {
		let localURL = try makeLocalFile(content: "file content")
		URLProtocolMock.requestHandler = Array(repeating: { _ in throw URLError(.networkConnectionLost) }, count: 4) + [GoogleDriveMockResponse.session()]

		await XCTAssertThrowsErrorAsync(try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.noInternetConnection, error as? CloudProviderError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
		XCTAssertEqual(3, sleeps.durations.count)
	}

	func testExhaustedSessionRequestIsNotRefreshed() async throws {
		let localURL = try makeLocalFile(content: "file content")
		URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 503), count: 3) + [URLProtocolMock.handler(statusCode: 401), GoogleDriveMockResponse.session()]

		await XCTAssertThrowsErrorAsync(try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.apiError(statusCode: 401, reason: nil, message: nil), error as? GoogleDriveError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
		XCTAssertTrue(tokenSource.rejectedTokens.isEmpty)
	}

	func testUnauthorizedLastPutIsNotRefreshed() async throws {
		let localURL = try makeLocalFile(content: "file content")
		URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 503), count: 3) + [GoogleDriveMockResponse.session(), URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(statusCode: 308)]

		await XCTAssertThrowsErrorAsync(try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.apiError(statusCode: 401, reason: nil, message: nil), error as? GoogleDriveError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
		XCTAssertTrue(tokenSource.rejectedTokens.isEmpty)
	}

	func testExhaustedUploadDoesNotWaitToSendFileAgain() async throws {
		let localURL = try makeLocalFile(content: "file content")
		URLProtocolMock.requestHandler = [
			GoogleDriveMockResponse.session(),
			URLProtocolMock.handler(statusCode: 503),
			URLProtocolMock.handler(statusCode: 308),
			URLProtocolMock.handler(statusCode: 503),
			URLProtocolMock.handler(statusCode: 308),
			URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12))
		]

		await XCTAssertThrowsErrorAsync(try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.apiError(statusCode: 503, reason: nil, message: nil), error as? GoogleDriveError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
		XCTAssertEqual(2, sleeps.durations.count)
	}

	func testExhaustedPutDoesNotWaitToQueryStatus() async throws {
		let localURL = try makeLocalFile(content: "file content")
		URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 503), count: 3) + [GoogleDriveMockResponse.session(), URLProtocolMock.handler(statusCode: 503), URLProtocolMock.handler(statusCode: 308)]

		await XCTAssertThrowsErrorAsync(try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.apiError(statusCode: 503, reason: nil, message: nil), error as? GoogleDriveError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
		XCTAssertEqual(3, sleeps.durations.count)
	}

	func testUnauthorizedPutIsRefreshedAndSentAgain() async throws {
		let localURL = try makeLocalFile(content: "file content")
		let record = requests.record
		URLProtocolMock.requestHandler = [
			GoogleDriveMockResponse.session(onRequest: record),
			URLProtocolMock.handler(statusCode: 401, onRequest: record),
			URLProtocolMock.handler(statusCode: 308, onRequest: record),
			URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12), onRequest: record)
		]

		let file = try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)

		XCTAssertEqual("F", file.id)
		XCTAssertEqual(["Bearer TOKEN", "Bearer TOKEN", "Bearer REFRESHED", "Bearer REFRESHED"], requests.requests.map { $0.value(forHTTPHeaderField: "Authorization") })
		XCTAssertEqual(["TOKEN"], tokenSource.rejectedTokens)
	}

	/// The session request and the status query create nothing, so a transport error doesn't end the upload.
	func testTransportErrorsOfRequestsThatCreateNothingAreRetried() async throws {
		let localURL = try makeLocalFile(content: "file content")
		URLProtocolMock.requestHandler = [
			{ _ in throw URLError(.networkConnectionLost) },
			GoogleDriveMockResponse.session(),
			URLProtocolMock.handler(statusCode: 503),
			{ _ in throw URLError(.networkConnectionLost) },
			URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12))
		]

		let file = try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)

		XCTAssertEqual("F", file.id)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testFailedStatusQueryEndsUpload() async throws {
		let localURL = try makeLocalFile(content: "file content")
		URLProtocolMock.requestHandler = [
			GoogleDriveMockResponse.session(),
			URLProtocolMock.handler(statusCode: 503),
			URLProtocolMock.handler(statusCode: 404, body: GoogleDriveMockResponse.error(status: 404, reason: "notFound")),
			GoogleDriveMockResponse.session()
		]

		await XCTAssertThrowsErrorAsync(try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.apiError(statusCode: 404, reason: "notFound", message: "Error"), error as? GoogleDriveError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testSessionURLOutsideGoogleIsRejected() async throws {
		let localURL = try makeLocalFile(content: "file content")
		for location in ["https://example.com/upload", "http://www.googleapis.com/upload", "https://evilgoogleapis.com/upload"] {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(headerFields: ["Location": location]), URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt"))]

			await XCTAssertThrowsErrorAsync(try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil), location) { error in
				XCTAssertEqual(.unexpectedContent, error as? GoogleDriveError, location)
			}
			XCTAssertEqual(1, URLProtocolMock.requestHandler.count, location)
		}
	}

	func testPartialUploadEndsWithoutNewSession() async throws {
		let localURL = try makeLocalFile(content: "file content")
		URLProtocolMock.requestHandler = [
			GoogleDriveMockResponse.session(),
			{ _ in throw URLError(.networkConnectionLost) },
			URLProtocolMock.handler(statusCode: 308, headerFields: ["Range": "bytes=0-4"]),
			GoogleDriveMockResponse.session()
		]

		await XCTAssertThrowsErrorAsync(try await client.upload(from: localURL, name: "file.txt", parentID: "P", existingFileID: nil, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.noInternetConnection, error as? CloudProviderError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testUploadLogsNeitherUploadIDNorItsHeader() async throws {
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
		XCTAssertTrue(log.contains("https://www.googleapis.com"), log)
		for secret in ["SECRET-UPLOAD-ID", "SECRET-HEADER-ID"] {
			XCTAssertFalse(log.contains(secret), "\(secret) in \(log)")
		}
	}

	// MARK: - Helpers

	private func makeLocalFile(content: String) throws -> URL {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		try Data(content.utf8).write(to: localURL)
		return localURL
	}

	private static func queryParameters(of request: URLRequest) -> [String: String] {
		return request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery }.map(PCloudMockResponse.parameters(inFormEncoded:)) ?? [:]
	}
}

/// Records the requests that reach `URLProtocolMock`, with their bodies.
final class RequestRecorder: Sendable {
	private let recordedRequests = OSAllocatedUnfairLock(initialState: [URLRequest]())

	var requests: [URLRequest] {
		return recordedRequests.withLock { $0 }
	}

	var record: @Sendable (URLRequest) -> Void {
		return { request in
			var recordedRequest = request
			recordedRequest.httpBody = URLProtocolMock.body(of: request)
			self.recordedRequests.withLock { [recordedRequest] in $0.append(recordedRequest) }
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
