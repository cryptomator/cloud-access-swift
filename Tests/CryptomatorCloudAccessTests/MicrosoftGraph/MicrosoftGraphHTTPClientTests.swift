//
//  MicrosoftGraphHTTPClientTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 14.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class MicrosoftGraphHTTPClientTests: XCTestCase {
	private let url = URL(string: "https://graph.microsoft.com/v1.0/me/drive/root")!
	private let uploadURL = URL(string: "https://upload.example.com/up/SECRET-PATH-TOKEN?tempauth=SECRET-TEMPAUTH")!
	private var tokenSource: OAuthTokenSourceStub!
	private var sleeps: SleepRecorder!
	private var client: MicrosoftGraphHTTPClient!
	private var tmpDirURL: URL!

	override func setUpWithError() throws {
		tokenSource = OAuthTokenSourceStub()
		sleeps = SleepRecorder()
		client = MicrosoftGraphHTTPClient.mocked(tokenSource: tokenSource, sleeps: sleeps)
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - Retries

	func testThrottledRequestIsRetried() async throws {
		let authorizations = OSAllocatedUnfairLock(initialState: [String?]())
		let recordAuthorization: @Sendable (URLRequest) -> Void = { request in
			authorizations.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
		}
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 429, headerFields: ["Retry-After": "0"], onRequest: recordAuthorization),
			URLProtocolMock.handler(body: "{}", onRequest: recordAuthorization)
		]

		let (response, data) = try await client.data(URLRequest(url: url))

		XCTAssertEqual(200, response.statusCode)
		XCTAssertEqual(Data("{}".utf8), data)
		XCTAssertEqual(["Bearer TOKEN", "Bearer TOKEN"], authorizations.withLock { $0 })
		XCTAssertEqual([.seconds(0)], sleeps.durations)
	}

	func testServerErrorsAreRetriedUntilFiveAttempts() async throws {
		URLProtocolMock.requestHandler = [500, 502, 503, 504].map { URLProtocolMock.handler(statusCode: $0) } + [URLProtocolMock.handler(statusCode: 503), URLProtocolMock.handler(body: "{}")]

		let (response, _) = try await client.data(URLRequest(url: url))

		XCTAssertEqual(503, response.statusCode)
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
		XCTAssertEqual(4, sleeps.durations.count)
	}

	func testServerErrorsOfMutationsAreNotRetried() async throws {
		for method in ["POST", "PATCH", "DELETE"] {
			for statusCode in [500, 502] {
				var request = URLRequest(url: url)
				request.httpMethod = method
				URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: statusCode), URLProtocolMock.handler(body: "{}")]

				let (response, _) = try await client.data(request)

				XCTAssertEqual(statusCode, response.statusCode, method)
				XCTAssertEqual(1, URLProtocolMock.requestHandler.count, method)
			}
		}
		var request = URLRequest(url: url)
		request.httpMethod = "DELETE"
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 503), URLProtocolMock.handler(statusCode: 204)]

		let (response, _) = try await client.data(request)

		XCTAssertEqual(204, response.statusCode)
		XCTAssertEqual(1, sleeps.durations.count)
	}

	func testRetryAfterIsCappedAtOneMinute() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 429, headerFields: ["Retry-After": "3600"]), URLProtocolMock.handler(body: "{}")]

		_ = try await client.data(URLRequest(url: url))

		XCTAssertEqual([.seconds(60)], sleeps.durations)
	}

	func testUnauthorizedRequestIsRefreshedOnce() async throws {
		let authorizations = OSAllocatedUnfairLock(initialState: [String?]())
		let recordAuthorization: @Sendable (URLRequest) -> Void = { request in
			authorizations.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
		}
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401, onRequest: recordAuthorization), URLProtocolMock.handler(body: "{}", onRequest: recordAuthorization)]

		_ = try await client.dataExpectingOK(URLRequest(url: url))

		XCTAssertEqual(["Bearer TOKEN", "Bearer REFRESHED"], authorizations.withLock { $0 })
		XCTAssertEqual(["TOKEN"], tokenSource.rejectedTokens)

		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: "{}")]

		await XCTAssertThrowsErrorAsync(try await client.dataExpectingOK(URLRequest(url: url))) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testMetadataBodyOverLimitFails() async throws {
		URLProtocolMock.requestHandler = [{ request in
			(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(count: HTTPClientSupport.maxMetadataBodyLength + 1))
		}]

		await XCTAssertThrowsErrorAsync(try await client.data(URLRequest(url: url))) { error in
			guard case SplitURLSessionError.responseBodyTooLarge = error else {
				return XCTFail("Unexpected error: \(error)")
			}
		}
	}

	// MARK: - Uploads

	func testUploadIsSentWithoutAuthorization() async throws {
		let fileURL = tmpDirURL.appendingPathComponent("chunk")
		try Data("chunk".utf8).write(to: fileURL)
		let authorizations = OSAllocatedUnfairLock(initialState: [String?]())
		let recordAuthorization: @Sendable (URLRequest) -> Void = { request in
			authorizations.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
		}
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 503, onRequest: recordAuthorization), URLProtocolMock.handler(statusCode: 401, onRequest: recordAuthorization), URLProtocolMock.handler(statusCode: 202)]

		let (response, _) = try await client.upload(putRequest(), fromFile: fileURL, progress: nil, onTaskCreation: nil)

		XCTAssertEqual(401, response.statusCode)
		XCTAssertEqual([nil, nil], authorizations.withLock { $0 })
		XCTAssertTrue(tokenSource.rejectedTokens.isEmpty)
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testServerErrorOfUploadIsRetried() async throws {
		let fileURL = tmpDirURL.appendingPathComponent("chunk")
		try Data("chunk".utf8).write(to: fileURL)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 500), URLProtocolMock.handler(statusCode: 502), URLProtocolMock.handler(statusCode: 201)]

		let (response, _) = try await client.upload(putRequest(), fromFile: fileURL, progress: nil, onTaskCreation: nil)

		XCTAssertEqual(201, response.statusCode)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testRetriedTransfersHandOverOneTask() async throws {
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

		XCTAssertEqual(1, downloadTaskCount.withLock { $0 })
		XCTAssertEqual(1, uploadTaskCount.withLock { $0 })
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testFailedAndRetriedUploadLogsOnlyOriginOfURL() async throws {
		let logCapture = LogCapture.start()
		defer {
			logCapture.stop()
		}
		let fileURL = tmpDirURL.appendingPathComponent("chunk")
		try Data("chunk".utf8).write(to: fileURL)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 503), { _ in throw URLError(.timedOut) }]

		await XCTAssertThrowsErrorAsync(try await client.upload(putRequest(), fromFile: fileURL, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.timedOut, (error as? URLError)?.code)
		}

		let failureLines = logCapture.messages.filter { $0.hasPrefix("MicrosoftGraphHTTPClient: PUT") }
		XCTAssertEqual(2, failureLines.count, logCapture.joinedMessages)
		XCTAssertTrue(failureLines.allSatisfy { $0.contains("https://upload.example.com/<redacted>") }, logCapture.joinedMessages)
		XCTAssertFalse(logCapture.joinedMessages.contains("SECRET"), logCapture.joinedMessages)
	}

	// MARK: - Logging

	func testResponseBodiesAreNotLogged() async throws {
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
		XCTAssertTrue(log.contains("https://graph.microsoft.com"), log)
		for secret in ["SECRET", "lister@example.com", "uploader@example.com"] {
			XCTAssertFalse(log.contains(secret), "\(secret) in \(log)")
		}
	}

	func testRetriedDownloadLogsOnlyOriginsOfURLs() async throws {
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

		XCTAssertEqual(200, response.statusCode)
		XCTAssertEqual(Data("content".utf8), try Data(contentsOf: stagingURL))
		let log = logCapture.joinedMessages
		XCTAssertTrue(log.contains("https://graph.microsoft.com"), log)
		XCTAssertTrue(log.contains("https://content.example.com"), log)
		XCTAssertTrue(logCapture.messages.contains { $0.hasPrefix("MicrosoftGraphHTTPClient: GET https://graph.microsoft.com/<redacted>") }, log)
		for secret in ["SECRET-ACCOUNT", "/me/drive/root", "TEMPAUTH"] {
			XCTAssertFalse(log.contains(secret), "\(secret) in \(log)")
		}
	}

	// MARK: - Discovery

	func testDiscoveryMapsForbiddenToUnauthorized() async throws {
		let discovery = MicrosoftGraphDiscovery(client: client)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 403)]

		await XCTAssertThrowsErrorAsync(try await discovery.fetchDrive(for: "DRIVE")) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
	}

	// MARK: - Configurations

	func testBackgroundConfiguration() {
		let configuration = MicrosoftGraphHTTPClient.backgroundConfiguration(sessionIdentifier: "MicrosoftGraphHTTPClientTests", sharedContainerIdentifier: "group.test")

		XCTAssertEqual("MicrosoftGraphHTTPClientTests", configuration.identifier)
		XCTAssertEqual("group.test", configuration.sharedContainerIdentifier)
	}

	func testConfigurationsAreHardened() {
		for configuration in [MicrosoftGraphHTTPClient.foregroundConfiguration(), MicrosoftGraphHTTPClient.backgroundConfiguration(sessionIdentifier: "MicrosoftGraphHTTPClientTests", sharedContainerIdentifier: nil)] {
			XCTAssertNil(configuration.urlCache)
			XCTAssertNil(configuration.urlCredentialStorage)
			XCTAssertNotNil(configuration.httpCookieStorage)
			XCTAssertFalse(configuration.httpCookieStorage === HTTPCookieStorage.shared)
		}
	}

	// MARK: - Helpers

	private func putRequest() -> URLRequest {
		var request = URLRequest(url: uploadURL)
		request.httpMethod = "PUT"
		return request
	}
}

extension MicrosoftGraphHTTPClient {
	static func mocked(tokenSource: any BearerTokenSource = OAuthTokenSourceStub(), sleeps: SleepRecorder = SleepRecorder(), hooks: SplitURLSession.Hooks = SplitURLSession.Hooks()) -> MicrosoftGraphHTTPClient {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		return MicrosoftGraphHTTPClient(tokenSource: tokenSource, configuration: configuration, metadataConfiguration: nil, hooks: hooks, sleep: { sleeps.sleep(for: $0) })
	}
}
