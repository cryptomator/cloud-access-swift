//
//  BoxClientTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class BoxClientTests: XCTestCase {
	private var tokenSource: BoxTokenSourceStub!
	private var sleeps: SleepRecorder!
	private var client: BoxClient!
	private var tmpDirURL: URL!

	override func setUpWithError() throws {
		tokenSource = BoxTokenSourceStub()
		sleeps = SleepRecorder()
		client = BoxClient.mocked(tokenSource: tokenSource, sleeps: sleeps)
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - Retry Delay

	func testRetryDelay() throws {
		let now = try XCTUnwrap(Date.date(fromRFC822: "Tue, 20 Oct 2026 10:00:00 GMT"))
		let exactCases: [(String, Double)] = [
			("7", 7),
			(" 7 ", 7),
			("Tue, 20 Oct 2026 10:00:30 GMT", 30),
			("Tue, 20 Oct 2026 09:00:00 GMT", 0),
			("3600", 60),
			("1e30", 60)
		]
		for (retryAfter, expectedSeconds) in exactCases {
			let httpResponse = try response(retryAfter: retryAfter)
			XCTAssertEqual(.seconds(expectedSeconds), BoxClient.retryDelay(for: httpResponse, attempt: 3, now: now), retryAfter)
		}
		for retryAfter in ["abc", "inf", "nan", nil] {
			let httpResponse = try response(retryAfter: retryAfter)
			let delay = BoxClient.retryDelay(for: httpResponse, attempt: 3, now: now)
			XCTAssertTrue((Duration.zero ... .seconds(4)).contains(delay), "\(retryAfter ?? "nil"): \(delay)")
		}
	}

	// MARK: - Retries

	func testThrottledRequestWaitsForLowercaseRetryAfter() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 429, headerFields: ["retry-after": "2"]),
			URLProtocolMock.handler(body: BoxMockResponse.user)
		]

		_ = try await client.user()

		XCTAssertEqual([.seconds(2)], sleeps.durations)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testServerErrorsAreRetriedUntilFiveAttempts() async throws {
		URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 503), count: 4) + [URLProtocolMock.handler(body: BoxMockResponse.user)]

		_ = try await client.user()

		XCTAssertEqual(4, sleeps.durations.count)

		URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 503, body: #"{"code":"unavailable","message":"Unavailable"}"#), count: 6)

		await XCTAssertThrowsErrorAsync(try await client.user()) { error in
			XCTAssertEqual(.apiError(statusCode: 503, code: "unavailable", message: "Unavailable"), error as? BoxError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testUnauthorizedRequestIsRetriedOnceWithRefreshedToken() async throws {
		let authorizations = OSAllocatedUnfairLock(initialState: [String?]())
		let recordAuthorization: @Sendable (URLRequest) -> Void = { request in
			authorizations.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
		}
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 401, onRequest: recordAuthorization),
			URLProtocolMock.handler(body: BoxMockResponse.user, onRequest: recordAuthorization)
		]

		_ = try await client.user()

		XCTAssertEqual(["Bearer TOKEN", "Bearer REFRESHED"], authorizations.withLock { $0 })
		XCTAssertEqual(["TOKEN"], tokenSource.rejectedTokens)
		XCTAssertTrue(sleeps.durations.isEmpty)

		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: BoxMockResponse.user)]

		await XCTAssertThrowsErrorAsync(try await client.user()) { error in
			XCTAssertEqual(.apiError(statusCode: 401, code: nil, message: nil), error as? BoxError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testTransportErrorsAreNotRetried() async throws {
		URLProtocolMock.requestHandler = [{ _ in throw URLError(.timedOut) }, URLProtocolMock.handler(body: BoxMockResponse.user)]

		await XCTAssertThrowsErrorAsync(try await client.user()) { error in
			XCTAssertEqual(.timedOut, (error as? URLError)?.code)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)

		URLProtocolMock.requestHandler = [{ _ in throw URLError(.notConnectedToInternet) }]

		await XCTAssertThrowsErrorAsync(try await client.user()) { error in
			XCTAssertEqual(.noInternetConnection, error as? CloudProviderError)
		}
	}

	func testCancelledTaskGetsNoToken() async throws {
		let accessTokenCount = OSAllocatedUnfairLock(initialState: 0)
		let client = BoxClient.mocked(tokenSource: BoxTokenSourceStub(onAccessToken: { accessTokenCount.withLock { $0 += 1 } }), sleeps: sleeps)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: BoxMockResponse.user)]

		await XCTAssertThrowsErrorAsync(try await value(of: Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return try await client.user()
		})) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(0, accessTokenCount.withLock { $0 })
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testCancellationWhileGettingTokenStopsFirstAttempt() async throws {
		let client = BoxClient.mocked(tokenSource: BoxTokenSourceStub(onAccessToken: { withUnsafeCurrentTask { $0?.cancel() } }), sleeps: sleeps)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: BoxMockResponse.user)]

		await XCTAssertThrowsErrorAsync(try await value(of: Task { try await client.user() })) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testCancellationDuringRefreshStopsRetry() async throws {
		let client = BoxClient.mocked(tokenSource: BoxTokenSourceStub(onRefresh: { withUnsafeCurrentTask { $0?.cancel() } }), sleeps: sleeps)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: BoxMockResponse.user)]

		await XCTAssertThrowsErrorAsync(try await value(of: Task { try await client.user() })) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	// MARK: - Requests

	func testListingSendsFieldsAndEscapedMarker() async throws {
		let sentRequest = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"entries":[]}"#, onRequest: { request in
			sentRequest.withLock { $0 = request }
		})]

		_ = try await client.folderItems(id: "7", marker: "a+b c", limit: 100)

		let url = try XCTUnwrap(sentRequest.withLock { $0 }?.url)
		XCTAssertEqual("https", url.scheme)
		XCTAssertEqual("api.box.com", url.host)
		XCTAssertEqual("/2.0/folders/7/items", url.path)
		let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
		XCTAssertTrue(query.contains("marker=a%2Bb%20c"), query)
		XCTAssertEqual(["fields": "name,size,modified_at", "usemarker": "true", "marker": "a+b c", "limit": "100"], PCloudMockResponse.parameters(inFormEncoded: query))
	}

	func testUploadSessionURLOutsideBoxIsRejectedWithoutRequest() async throws {
		let partFileURL = tmpDirURL.appendingPathComponent("part")
		try Data("part".utf8).write(to: partFileURL)

		for url in ["https://evil.example/upload", "http://upload.box.com/api/2.0/files/upload_sessions/S", "https://evilbox.com/upload"] {
			await XCTAssertThrowsErrorAsync(try await client.uploadPart(url: url, from: partFileURL, range: 0 ... 3, fileSize: 4, digest: "sha=", progress: nil), url) { error in
				XCTAssertEqual(.unexpectedContent, error as? BoxError, url)
			}
		}
	}

	// MARK: - Logging

	func testDownloadLogsOnlyOriginsOfURLs() async throws {
		let logCapture = LogCapture.start()
		defer {
			logCapture.stop()
		}
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 302, headerFields: ["Location": "https://dl.boxcloud.com/d/1/SECRET-PATH/file.txt"]),
			URLProtocolMock.handler(body: "content")
		]
		let stagingURL = tmpDirURL.appendingPathComponent("download")

		try await client.download(fileID: "5", to: stagingURL, progress: nil, onTaskCreation: nil)

		XCTAssertEqual(Data("content".utf8), try Data(contentsOf: stagingURL))
		let log = logCapture.joinedMessages
		XCTAssertTrue(log.contains("https://api.box.com"), log)
		XCTAssertTrue(log.contains("https://dl.boxcloud.com"), log)
		for secret in ["SECRET-PATH", "/files/5/content", "TOKEN"] {
			XCTAssertFalse(log.contains(secret), "\(secret) in \(log)")
		}
	}

	// MARK: - Helpers

	private func response(retryAfter: String?) throws -> HTTPURLResponse {
		return try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(URL(string: "https://api.box.com/2.0/users/me")), statusCode: 503, httpVersion: "HTTP/1.1", headerFields: retryAfter.map { ["Retry-After": $0] }))
	}
}

/// Hands out `TOKEN` until a refresh rejects it, and `REFRESHED` afterwards.
final class BoxTokenSourceStub: BoxTokenSource {
	private let state = OSAllocatedUnfairLock(initialState: (token: "TOKEN", rejectedTokens: [String]()))
	private let onAccessToken: @Sendable () async -> Void
	private let onRefresh: @Sendable () async -> Void

	init(onAccessToken: @escaping @Sendable () async -> Void = {}, onRefresh: @escaping @Sendable () async -> Void = {}) {
		self.onAccessToken = onAccessToken
		self.onRefresh = onRefresh
	}

	var rejectedTokens: [String] {
		return state.withLock { $0.rejectedTokens }
	}

	func accessToken() async throws -> String {
		await onAccessToken()
		return state.withLock { $0.token }
	}

	func refresh(rejecting accessToken: String) async throws -> String {
		state.withLock { $0.rejectedTokens.append(accessToken) }
		await onRefresh()
		return state.withLock { state in
			state.token = "REFRESHED"
			return state.token
		}
	}

	func deauthenticate() async throws {}
}

/// Records the waits before retries instead of waiting.
final class SleepRecorder: Sendable {
	private let recordedDurations = OSAllocatedUnfairLock(initialState: [Duration]())

	var durations: [Duration] {
		return recordedDurations.withLock { $0 }
	}

	func sleep(for duration: Duration) {
		recordedDurations.withLock { $0.append(duration) }
	}
}

extension BoxClient {
	static func mocked(tokenSource: any BoxTokenSource = BoxTokenSourceStub(), sleeps: SleepRecorder = SleepRecorder(), hooks: SplitURLSession.Hooks = SplitURLSession.Hooks()) -> BoxClient {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		return BoxClient(tokenSource: tokenSource, configuration: configuration, metadataConfiguration: nil, hooks: hooks, sleep: { sleeps.sleep(for: $0) })
	}
}

enum BoxMockResponse {
	static let user = #"{"type":"user","id":"USER-ID","name":"User"}"#
	static let modifiedAt = "2026-10-20T11:05:00-07:00"

	static func fileEntry(id: String, name: String, size: Int = 7, modifiedAt: String = modifiedAt) -> String {
		return #"{"type":"file","id":"\#(id)","name":"\#(name)","size":\#(size),"modified_at":"\#(modifiedAt)"}"#
	}

	static func folderEntry(id: String, name: String) -> String {
		return #"{"type":"folder","id":"\#(id)","name":"\#(name)","size":12,"modified_at":"\#(modifiedAt)"}"#
	}

	static func items(_ entries: [String], nextMarker: String? = nil) -> String {
		return #"{"entries":[\#(entries.joined(separator: ","))]\#(nextMarker.map { #","next_marker":"\#($0)""# } ?? "")}"#
	}

	static func files(_ entries: [String]) -> String {
		return #"{"total_count":\#(entries.count),"entries":[\#(entries.joined(separator: ","))]}"#
	}

	static func error(status: Int, code: String) -> String {
		return #"{"type":"error","status":\#(status),"code":"\#(code)"}"#
	}
}
