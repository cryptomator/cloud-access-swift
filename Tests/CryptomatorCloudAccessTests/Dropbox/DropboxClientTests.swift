//
//  DropboxClientTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 10.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class DropboxClientTests: XCTestCase {
	private var tokenSource: OAuthTokenSourceStub!
	private var sleeps: SleepRecorder!
	private var client: DropboxClient!
	private var tmpDirURL: URL!

	override func setUpWithError() throws {
		tokenSource = OAuthTokenSourceStub()
		sleeps = SleepRecorder()
		client = DropboxClient.mocked(tokenSource: tokenSource, sleeps: sleeps)
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - Requests

	func testRPCRoutesSendJSONArguments() async throws {
		let client: DropboxClient = client
		let cases = [
			RouteCase(name: "metadata", response: DropboxMockResponse.file(name: "a.txt"), expectedRoute: "files/get_metadata", expectedArgument: ["path": "/a.txt", "include_media_info": false, "include_deleted": false, "include_has_explicit_shared_members": false]) {
				_ = try await client.metadata(path: "/a.txt")
			},
			RouteCase(name: "listing", response: DropboxMockResponse.listing([]), expectedRoute: "files/list_folder", expectedArgument: ["path": "", "limit": 100, "recursive": false, "include_mounted_folders": true, "include_non_downloadable_files": true]) {
				_ = try await client.listFolder(path: "", limit: 100)
			},
			RouteCase(name: "next page", response: DropboxMockResponse.listing([]), expectedRoute: "files/list_folder/continue", expectedArgument: ["cursor": "CURSOR"]) {
				_ = try await client.listFolderContinue(cursor: "CURSOR")
			},
			RouteCase(name: "create folder", response: "{}", expectedRoute: "files/create_folder_v2", expectedArgument: ["path": "/folder", "autorename": false]) {
				try await client.createFolder(path: "/folder")
			},
			RouteCase(name: "delete", response: "{}", expectedRoute: "files/delete_v2", expectedArgument: ["path": "/a.txt"]) {
				try await client.delete(path: "/a.txt")
			},
			RouteCase(name: "move", response: "{}", expectedRoute: "files/move_v2", expectedArgument: ["from_path": "/a.txt", "to_path": "/b.txt", "allow_shared_folder": false, "autorename": false, "allow_ownership_transfer": false]) {
				try await client.move(from: "/a.txt", to: "/b.txt")
			},
			RouteCase(name: "account", response: #"{"email":"user@example.com"}"#, expectedRoute: "users/get_current_account", expectedArgument: nil) {
				_ = try await client.currentAccount()
			}
		]
		for routeCase in cases {
			let log = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: routeCase.response, onRequest: log.record)]

			try await routeCase.operation()

			let request = try XCTUnwrap(log.requests.first, routeCase.name)
			XCTAssertEqual("POST", request.httpMethod, routeCase.name)
			XCTAssertEqual("https://api.dropboxapi.com/2/\(routeCase.expectedRoute)", request.url?.absoluteString, routeCase.name)
			XCTAssertEqual("application/json", request.value(forHTTPHeaderField: "Content-Type"), routeCase.name)
			XCTAssertEqual("Bearer TOKEN", request.value(forHTTPHeaderField: "Authorization"), routeCase.name)
			XCTAssertNil(request.value(forHTTPHeaderField: "Dropbox-API-Arg"), routeCase.name)
			let body = try XCTUnwrap(request.httpBody, routeCase.name)
			if let expectedArgument = routeCase.expectedArgument {
				XCTAssertEqual(expectedArgument as NSDictionary, try JSONSerialization.jsonObject(with: body) as? NSDictionary, routeCase.name)
			} else {
				XCTAssertEqual("null", String(data: body, encoding: .utf8), routeCase.name)
			}
		}
	}

	func testContentRoutesSendArgumentHeaders() async throws {
		let client: DropboxClient = client
		let fileURL = tmpDirURL.appendingPathComponent("file")
		try Data("content".utf8).write(to: fileURL)
		let stagingURL = tmpDirURL.appendingPathComponent("download")
		let cases = [
			RouteCase(name: "download", response: "content", headerFields: ["Dropbox-API-Result": DropboxMockResponse.file(name: "a.txt", tagged: false)], expectedRoute: "files/download", expectedArgument: ["path": "/a.txt"], expectedContentType: nil, expectedBody: nil) {
				_ = try await client.download(path: "/a.txt", to: stagingURL, progress: nil, onTaskCreation: nil)
			},
			RouteCase(name: "upload", response: DropboxMockResponse.file(name: "a.txt", tagged: false), expectedRoute: "files/upload", expectedArgument: ["path": "/a.txt", "mode": "overwrite", "autorename": false, "mute": false, "strict_conflict": true], expectedContentType: "application/octet-stream", expectedBody: "content") {
				_ = try await client.upload(from: fileURL, path: "/a.txt", mode: .overwrite, progress: nil, onTaskCreation: nil)
			},
			RouteCase(name: "start", response: #"{"session_id":"SESSION"}"#, expectedRoute: "files/upload_session/start", expectedArgument: ["close": false], expectedContentType: "application/octet-stream", expectedBody: "") {
				let sessionID = try await client.startUploadSession()
				XCTAssertEqual("SESSION", sessionID)
			},
			RouteCase(name: "append", response: "null", expectedRoute: "files/upload_session/append_v2", expectedArgument: ["cursor": ["session_id": "SESSION", "offset": 4], "close": false], expectedContentType: "application/octet-stream", expectedBody: "content") {
				let correctOffset = try await client.appendToUploadSession(sessionID: "SESSION", offset: 4, from: fileURL, progress: nil)
				XCTAssertNil(correctOffset)
			},
			RouteCase(name: "finish", response: DropboxMockResponse.file(name: "a.txt", tagged: false), expectedRoute: "files/upload_session/finish", expectedArgument: ["cursor": ["session_id": "SESSION", "offset": 11], "commit": ["path": "/a.txt", "mode": "add", "autorename": false, "mute": false, "strict_conflict": true]], expectedContentType: "application/octet-stream", expectedBody: "") {
				_ = try await client.finishUploadSession(sessionID: "SESSION", offset: 11, path: "/a.txt", mode: .add)
			}
		]
		for routeCase in cases {
			let log = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: routeCase.response, headerFields: routeCase.headerFields, onRequest: log.record)]

			try await routeCase.operation()

			let request = try XCTUnwrap(log.requests.first, routeCase.name)
			XCTAssertEqual("POST", request.httpMethod, routeCase.name)
			XCTAssertEqual("https://content.dropboxapi.com/2/\(routeCase.expectedRoute)", request.url?.absoluteString, routeCase.name)
			XCTAssertEqual(routeCase.expectedContentType, request.value(forHTTPHeaderField: "Content-Type"), routeCase.name)
			let argument = try XCTUnwrap(request.value(forHTTPHeaderField: "Dropbox-API-Arg"), routeCase.name)
			XCTAssertEqual(routeCase.expectedArgument as NSDictionary?, try JSONSerialization.jsonObject(with: Data(argument.utf8)) as? NSDictionary, routeCase.name)
			XCTAssertEqual(routeCase.expectedBody ?? "", String(bytes: request.httpBody ?? Data(), encoding: .utf8), routeCase.name)
		}
	}

	func testDownloadReturnsMetadataOfResultHeader() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: "content", headerFields: ["Dropbox-API-Result": #"{"name":"fö.txt","size":7,"server_modified":"2026-10-21T08:15:38Z"}"#])]
		let stagingURL = tmpDirURL.appendingPathComponent("download")

		let metadata = try await client.download(path: "/fö.txt", to: stagingURL, progress: nil, onTaskCreation: nil)

		XCTAssertEqual("fö.txt", metadata.name)
		XCTAssertEqual(7, metadata.size)
		XCTAssertEqual(.file, try metadata.cloudItemType(untaggedAs: .file))
		XCTAssertEqual(Data("content".utf8), try Data(contentsOf: stagingURL))
	}

	func testUnparseableBodyOfSuccessfulMutationIsIgnored() async throws {
		URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(body: "not json"), count: 3)

		try await client.createFolder(path: "/folder")
		try await client.delete(path: "/folder")
		try await client.move(from: "/a", to: "/b")

		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testIncorrectOffsetReturnsCorrectOffset() async throws {
		let chunkURL = tmpDirURL.appendingPathComponent("chunk")
		try Data("0123".utf8).write(to: chunkURL)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 409, body: #"{"error_summary":"incorrect_offset/..","error":{".tag":"incorrect_offset","correct_offset":8}}"#)]

		let correctOffset = try await client.appendToUploadSession(sessionID: "SESSION", offset: 4, from: chunkURL, progress: nil)

		XCTAssertEqual(8, correctOffset)
	}

	// MARK: - Retries

	func testUnauthorizedRequestIsRetriedOnceWithRefreshedToken() async throws {
		let log = RequestRecorder()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 401, body: #"{"error_summary":"expired_access_token/.."}"#, onRequest: log.record),
			URLProtocolMock.handler(body: DropboxMockResponse.file(name: "a.txt"), onRequest: log.record)
		]

		_ = try await client.metadata(path: "/a.txt")

		XCTAssertEqual(["Bearer TOKEN", "Bearer REFRESHED"], log.requests.map { $0.value(forHTTPHeaderField: "Authorization") })
		XCTAssertEqual(["TOKEN"], tokenSource.rejectedTokens)

		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: DropboxMockResponse.file(name: "a.txt"))]

		await XCTAssertThrowsErrorAsync(try await client.metadata(path: "/a.txt")) { error in
			XCTAssertEqual(.apiError(statusCode: 401, summary: nil), error as? DropboxError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testRefreshCountsAmongFiveAttempts() async throws {
		URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 503), count: 4) + [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: DropboxMockResponse.file(name: "a.txt"))]

		await XCTAssertThrowsErrorAsync(try await client.metadata(path: "/a.txt")) { error in
			XCTAssertEqual(.apiError(statusCode: 401, summary: nil), error as? DropboxError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
		XCTAssertEqual(4, sleeps.durations.count)
		XCTAssertTrue(tokenSource.rejectedTokens.isEmpty)
	}

	func testThrottledRequestWaitsForRetryAfter() async throws {
		let cases: [(response: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?), expectedWait: Duration)] = [
			(URLProtocolMock.handler(statusCode: 429, body: #"{"error_summary":"too_many_requests/..","error":{"reason":{".tag":"too_many_requests"},"retry_after":3}}"#), .seconds(3)),
			(URLProtocolMock.handler(statusCode: 429, body: #"{"error_summary":"too_many_requests/..","error":{"reason":{".tag":"too_many_requests"},"retry_after":300}}"#), .seconds(60)),
			(URLProtocolMock.handler(statusCode: 429, headerFields: ["Retry-After": "2"]), .seconds(2))
		]
		for (response, expectedWait) in cases {
			let sleeps = SleepRecorder()
			let client = DropboxClient.mocked(sleeps: sleeps)
			URLProtocolMock.requestHandler = [response, URLProtocolMock.handler(body: DropboxMockResponse.file(name: "a.txt"))]

			_ = try await client.metadata(path: "/a.txt")

			XCTAssertEqual([expectedWait], sleeps.durations)
		}
	}

	func testTooManyWriteOperationsAreRetried() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 409, body: #"{"error_summary":"path_write/too_many_write_operations/..","error":{}}"#),
			URLProtocolMock.handler(statusCode: 409, body: #"{"error_summary":"too_many_write_operations/..","error":{}}"#),
			URLProtocolMock.handler(body: "{}")
		]

		try await client.delete(path: "/a.txt")

		XCTAssertEqual(2, sleeps.durations.count)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testTransportErrorsAreRetriedOnlyForRepeatableRequests() async throws {
		let fileURL = tmpDirURL.appendingPathComponent("file")
		try Data("content".utf8).write(to: fileURL)
		URLProtocolMock.requestHandler = [{ _ in throw URLError(.networkConnectionLost) }, URLProtocolMock.handler(body: DropboxMockResponse.file(name: "a.txt"))]

		_ = try await client.metadata(path: "/a.txt")

		URLProtocolMock.requestHandler = [{ _ in throw URLError(.networkConnectionLost) }, URLProtocolMock.handler(body: #"{"session_id":"SESSION"}"#)]

		_ = try await client.startUploadSession()

		XCTAssertEqual(2, sleeps.durations.count)

		let writes: [(name: String, operation: @Sendable (DropboxClient) async throws -> Void)] = [
			("create folder", { try await $0.createFolder(path: "/folder") }),
			("delete", { try await $0.delete(path: "/a.txt") }),
			("move", { try await $0.move(from: "/a.txt", to: "/b.txt") }),
			("upload", { _ = try await $0.upload(from: fileURL, path: "/a.txt", mode: .add, progress: nil, onTaskCreation: nil) }),
			("finish", { _ = try await $0.finishUploadSession(sessionID: "SESSION", offset: 7, path: "/a.txt", mode: .add) })
		]
		for (name, operation) in writes {
			URLProtocolMock.requestHandler = [{ _ in throw URLError(.networkConnectionLost) }, URLProtocolMock.handler(body: DropboxMockResponse.file(name: "a.txt"))]

			await XCTAssertThrowsErrorAsync(try await operation(client), name) { error in
				XCTAssertEqual(.noInternetConnection, error as? CloudProviderError, name)
			}
			XCTAssertEqual(1, URLProtocolMock.requestHandler.count, name)
		}
	}

	func testCancellationDuringRetryWaitSendsNoFurtherAttempt() async throws {
		let waiting = XCTestExpectation(description: "waiting for the retry")
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		let client = DropboxClient(tokenSource: OAuthTokenSourceStub(), configuration: configuration, metadataConfiguration: nil, sleep: { duration in
			waiting.fulfill()
			try await Task.sleep(for: duration)
		})
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 429, body: #"{"error_summary":"too_many_requests/..","error":{"retry_after":60}}"#),
			URLProtocolMock.handler(body: DropboxMockResponse.file(name: "a.txt"))
		]

		let request = Task {
			try await client.metadata(path: "/a.txt")
		}
		await fulfillment(of: [waiting], timeout: testWaitTimeout)
		request.cancel()

		await XCTAssertThrowsErrorAsync(try await value(of: request)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testCancelledTaskGetsNoToken() async throws {
		let accessTokenCount = OSAllocatedUnfairLock(initialState: 0)
		let client = DropboxClient.mocked(tokenSource: OAuthTokenSourceStub(onAccessToken: { accessTokenCount.withLock { $0 += 1 } }), sleeps: sleeps)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxMockResponse.file(name: "a.txt"))]

		await XCTAssertThrowsErrorAsync(try await value(of: cancelledTask {
			try await client.metadata(path: "/a.txt")
		})) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(0, accessTokenCount.withLock { $0 })
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testCancellationWhileGettingTokenStopsFirstAttempt() async throws {
		let client = DropboxClient.mocked(tokenSource: OAuthTokenSourceStub(onAccessToken: { withUnsafeCurrentTask { $0?.cancel() } }), sleeps: sleeps)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxMockResponse.file(name: "a.txt"))]

		await XCTAssertThrowsErrorAsync(try await value(of: Task { try await client.metadata(path: "/a.txt") })) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testCancellationDuringRefreshStopsRetry() async throws {
		let client = DropboxClient.mocked(tokenSource: OAuthTokenSourceStub(onRefresh: { withUnsafeCurrentTask { $0?.cancel() } }), sleeps: sleeps)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: DropboxMockResponse.file(name: "a.txt"))]

		await XCTAssertThrowsErrorAsync(try await value(of: Task { try await client.metadata(path: "/a.txt") })) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testRetriedDownloadHandsOverOneTask() async throws {
		let taskCount = OSAllocatedUnfairLock(initialState: 0)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 503),
			URLProtocolMock.handler(body: "content", headerFields: ["Dropbox-API-Result": DropboxMockResponse.file(name: "a.txt", tagged: false)])
		]

		_ = try await client.download(path: "/a.txt", to: tmpDirURL.appendingPathComponent("download"), progress: nil, onTaskCreation: { _ in
			taskCount.withLock { $0 += 1 }
		})

		XCTAssertEqual(1, taskCount.withLock { $0 })
	}

	// MARK: - Logging

	func testCurrentAccountIsRequestedWithoutLoggingIt() async throws {
		let logCapture = LogCapture.start()
		defer {
			logCapture.stop()
		}
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"email":"secret@example.com","name":{"display_name":"Secret Name"}}"#)]

		let account = try await client.currentAccount()

		XCTAssertEqual("secret@example.com", account.email)
		let log = logCapture.joinedMessages
		XCTAssertTrue(log.contains("https://api.dropboxapi.com"), log)
		XCTAssertFalse(log.contains("secret@example.com"), log)
		XCTAssertFalse(log.contains("Secret Name"), log)
	}
}

extension DropboxClient {
	static func mocked(tokenSource: any OAuthTokenSource = OAuthTokenSourceStub(), sleeps: SleepRecorder = SleepRecorder(), hooks: SplitURLSession.Hooks = SplitURLSession.Hooks()) -> DropboxClient {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		return DropboxClient(tokenSource: tokenSource, configuration: configuration, metadataConfiguration: nil, hooks: hooks, sleep: { sleeps.sleep(for: $0) })
	}
}

enum DropboxMockResponse {
	static let serverModified = "2026-10-21T08:15:38Z"

	static func file(name: String, size: Int = 7, tagged: Bool = true) -> String {
		return #"{\#(tagged ? #"".tag":"file","# : "")"name":"\#(name)","id":"id:\#(name)","size":\#(size),"server_modified":"\#(serverModified)","client_modified":"\#(serverModified)","rev":"0123456789abcdef"}"#
	}

	static func folder(name: String) -> String {
		return #"{".tag":"folder","name":"\#(name)","id":"id:\#(name)"}"#
	}

	static func listing(_ entries: [String], cursor: String = "CURSOR", hasMore: Bool = false) -> String {
		return #"{"entries":[\#(entries.joined(separator: ","))],"cursor":"\#(cursor)","has_more":\#(hasMore)}"#
	}

	static func error(_ summary: String) -> String {
		return #"{"error_summary":"\#(summary)","error":{}}"#
	}
}

private struct RouteCase {
	let name: String
	let response: String
	var headerFields: [String: String]?
	let expectedRoute: String
	let expectedArgument: [String: Any]?
	var expectedContentType: String?
	var expectedBody: String?
	let operation: () async throws -> Void

	init(name: String, response: String, headerFields: [String: String]? = nil, expectedRoute: String, expectedArgument: [String: Any]?, expectedContentType: String? = "application/json", expectedBody: String? = nil, operation: @escaping () async throws -> Void) {
		self.name = name
		self.response = response
		self.headerFields = headerFields
		self.expectedRoute = expectedRoute
		self.expectedArgument = expectedArgument
		self.expectedContentType = expectedContentType
		self.expectedBody = expectedBody
		self.operation = operation
	}
}
