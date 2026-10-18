//
//  SplitURLSessionTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

private struct ChallengeFailure: Error {}

private struct RejectingChallengeHandler: SplitURLSession.ChallengeHandler {
	func decision(for challenge: URLAuthenticationChallenge, task: URLSessionTask) -> SplitURLSession.ChallengeDecision {
		return SplitURLSession.ChallengeDecision(disposition: .cancelAuthenticationChallenge, credential: nil, failure: ChallengeFailure())
	}
}

class SplitURLSessionTests: XCTestCase {
	private let url = URL(string: "https://api.example.com/files/1/content")!
	private var session: SplitURLSession!
	private var tmpDirURL: URL!

	override func setUpWithError() throws {
		session = SplitURLSession(configuration: SplitURLSessionTests.mockConfiguration())
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		URLProtocolSequenceMock.steps = []
		session = nil
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - Routing

	func testRequestsRunOnTheSessionOfTheirRoute() async throws {
		let markedSession = SplitURLSession(configuration: URLProtocolMock.configuration(marker: "transfer"), metadataConfiguration: URLProtocolMock.configuration(marker: "metadata"))
		let markers = OSAllocatedUnfairLock(initialState: [String?]())
		URLProtocolMock.requestHandler = Array(repeating: { [url] request in
			markers.withLock { $0.append(request.value(forHTTPHeaderField: "X-Session")) }
			return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
		}, count: 4)
		let fileURL = tmpDirURL.appendingPathComponent("upload.txt")
		try Data("content".utf8).write(to: fileURL)

		_ = try await markedSession.data(URLRequest(url: url), bodyLimit: nil, bodyLogging: .logged)
		_ = try await markedSession.download(URLRequest(url: url), route: .metadata, handler: { _, _ in .none }, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)
		_ = try await markedSession.download(URLRequest(url: url), route: .transfer, handler: { _, _ in .none }, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)
		_ = try await markedSession.upload(URLRequest(url: url), fromFile: fileURL, bodyLimit: nil, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)

		XCTAssertEqual(["metadata", "metadata", "transfer", "transfer"], markers.withLock { $0 })
	}

	func testBackgroundConfigurationRunsDataRequestsOffBackgroundSession() async throws {
		let backgroundSession = makeBackgroundSession()
		let mockURL = try XCTUnwrap(URL(string: "mock://example.com/file"))
		let fileURL = tmpDirURL.appendingPathComponent("upload.txt")
		try Data("content".utf8).write(to: fileURL)
		URLProtocolMock.requestHandler = Array(repeating: { request in
			(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
		}, count: 2)

		let uploadOutcome = try await backgroundSession.upload(URLRequest(url: mockURL), fromFile: fileURL, bodyLimit: nil, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)
		XCTAssertEqual(200, (uploadOutcome.response as? HTTPURLResponse)?.statusCode)
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)

		// The foreground session has no mock, so it rejects the scheme that only the background session's mock handles.
		let dataOutcome = try await backgroundSession.data(URLRequest(url: mockURL), bodyLimit: nil, bodyLogging: .logged)
		XCTAssertEqual(URLError.unsupportedURL, (dataOutcome.error as? URLError)?.code)
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count, "The data request ran on the background session")
	}

	func testRequestsLogTheirSession() async throws {
		let logCapture = LogCapture.start()
		defer {
			logCapture.stop()
		}
		let backgroundSession = makeBackgroundSession()
		let mockURL = try XCTUnwrap(URL(string: "mock://example.com/file"))
		let fileURL = tmpDirURL.appendingPathComponent("upload.txt")
		try Data("content".utf8).write(to: fileURL)
		URLProtocolMock.requestHandler = [{ request in
			(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
		}]
		var uploadRequest = URLRequest(url: mockURL)
		uploadRequest.httpMethod = "PUT"

		_ = try await backgroundSession.upload(uploadRequest, fromFile: fileURL, bodyLimit: nil, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)
		_ = try await backgroundSession.data(URLRequest(url: mockURL), bodyLimit: nil, bodyLogging: .logged)

		let messages = logCapture.messages
		let uploadIndex = try XCTUnwrap(messages.firstIndex(of: "--> PUT mock://example.com/file"))
		let dataIndex = try XCTUnwrap(messages.firstIndex(of: "--> GET mock://example.com/file"))
		XCTAssertEqual("Session: background test", messages[uploadIndex + 1])
		XCTAssertEqual("Session: foreground", messages[dataIndex + 1])
	}

	func testOverlappingRequestsGetTheirOwnOutcomes() async throws {
		let firstSession = SplitURLSession(configuration: SplitURLSessionTests.mockConfiguration())
		let secondSession = SplitURLSession(configuration: SplitURLSessionTests.mockConfiguration())
		URLProtocolMock.requestHandler = Array(repeating: { request in
			(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(request.url!.lastPathComponent.utf8))
		}, count: 2)
		let firstRequest = URLRequest(url: url.appendingPathComponent("first"))
		let secondRequest = URLRequest(url: url.appendingPathComponent("second"))
		let firstHeld = XCTestExpectation(description: "first task held")
		let secondFinished = DispatchSemaphore(value: 0)
		let firstWaitResult = OSAllocatedUnfairLock<DispatchTimeoutResult?>(initialState: nil)

		// The download handler holds the first task with its record registered until the second request finished.
		let first = Task {
			try await firstSession.download(firstRequest, route: .transfer, handler: { location, _ in
				firstHeld.fulfill()
				let waitResult = secondFinished.wait(timeout: .now() + 2.0)
				firstWaitResult.withLock { $0 = waitResult }
				return try .data(Data(contentsOf: location))
			}, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)
		}
		await fulfillment(of: [firstHeld], timeout: 2.0)
		let secondOutcome = try await secondSession.data(secondRequest, bodyLimit: nil, bodyLogging: .logged)
		secondFinished.signal()
		let firstOutcome = try await value(of: first)

		XCTAssertEqual(.success, firstWaitResult.withLock { $0 }, "The requests did not overlap")
		XCTAssertEqual(Data("first".utf8), firstOutcome.data)
		XCTAssertEqual(Data("second".utf8), secondOutcome.data)
	}

	// MARK: - Body Limit

	func testBodyAtLimitIsReturned() async throws {
		let sequenceSession = SplitURLSession(configuration: sequenceConfiguration())
		URLProtocolSequenceMock.steps = try [.chunkedResponse(XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)), [Data(count: 32 * 1024), Data(count: 32 * 1024)])]

		let outcome = try await sequenceSession.data(URLRequest(url: url), bodyLimit: 64 * 1024, bodyLogging: .logged)

		XCTAssertEqual(.data(Data(count: 64 * 1024)), outcome.body)
		XCTAssertNil(outcome.recordedFailure)
	}

	func testBodyOverLimitIsDiscardedAfterTaskTerminated() async throws {
		let completionReached = XCTestExpectation(description: "terminal processing reached")
		let completionGate = DispatchSemaphore(value: 0)
		let hooks = SplitURLSession.Hooks(willProcessCompletion: { _ in
			completionReached.fulfill()
			_ = completionGate.wait(timeout: .now() + 2.0)
		})
		let sequenceSession = SplitURLSession(configuration: sequenceConfiguration(), hooks: hooks)
		URLProtocolSequenceMock.steps = try [.chunkedResponse(XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)), [Data(count: 64 * 1024), Data(count: 1)])]

		let returned = XCTestExpectation(description: "call returned before the task terminated")
		returned.isInverted = true
		let request = Task { [url] in
			defer { returned.fulfill() }
			return try await sequenceSession.data(URLRequest(url: url), bodyLimit: 64 * 1024, bodyLogging: .logged)
		}
		await fulfillment(of: [completionReached], timeout: 2.0)
		await fulfillment(of: [returned], timeout: 0.2)
		completionGate.signal()
		let outcome = try await value(of: request)

		guard case let .responseBodyTooLarge(limit)? = outcome.recordedFailure as? SplitURLSessionError else {
			XCTFail("Unexpected recorded failure: \(String(describing: outcome.recordedFailure))")
			return
		}
		XCTAssertEqual(64 * 1024, limit)
		XCTAssertEqual(SplitURLSession.Outcome.Body.none, outcome.body)
	}

	// MARK: - Challenges

	func testRejectedChallengeRecordsItsFailure() async throws {
		let sequenceSession = SplitURLSession(configuration: sequenceConfiguration(), challengeHandler: RejectingChallengeHandler())
		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil))
		URLProtocolSequenceMock.steps = [.authChallenge(URLAuthenticationChallengeMock(previousFailureCount: 0, failureResponse: failureResponse))]

		let outcome = try await sequenceSession.data(URLRequest(url: url), bodyLimit: nil, bodyLogging: .logged)

		XCTAssertTrue(outcome.recordedFailure is ChallengeFailure)
		XCTAssertTrue(try isCancellationError(XCTUnwrap(outcome.error)))
	}

	// MARK: - Compatibility

	func testDownloadReplacesExistingDestination() async throws {
		let destinationURL = tmpDirURL.appendingPathComponent("file.txt")
		try Data("old".utf8).write(to: destinationURL)
		URLProtocolMock.requestHandler = [{ [url] _ in
			(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("new".utf8))
		}]

		let (response, data) = try await session.download(URLRequest(url: url), to: destinationURL)

		XCTAssertEqual(200, response.statusCode)
		XCTAssertEqual(Data(), data)
		XCTAssertEqual(Data("new".utf8), try Data(contentsOf: destinationURL))
	}

	func testUnsuccessfulDownloadReturnsBodyAsData() async throws {
		let destinationURL = tmpDirURL.appendingPathComponent("file.txt")
		try Data("old".utf8).write(to: destinationURL)
		URLProtocolMock.requestHandler = [{ [url] _ in
			(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("not found".utf8))
		}]

		let (response, data) = try await session.download(URLRequest(url: url), to: destinationURL)

		XCTAssertEqual(404, response.statusCode)
		XCTAssertEqual(Data("not found".utf8), data)
		XCTAssertEqual(Data("old".utf8), try Data(contentsOf: destinationURL))
	}

	func testDownloadThrowsMoveError() async throws {
		let destinationURL = tmpDirURL.appendingPathComponent("missing", isDirectory: true).appendingPathComponent("file.txt")
		URLProtocolMock.requestHandler = [{ [url] _ in
			(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("content".utf8))
		}]

		await XCTAssertThrowsErrorAsync(try await session.download(URLRequest(url: url), to: destinationURL)) { error in
			XCTAssertTrue(error is CocoaError, "Unexpected error: \(error)")
		}
	}

	// MARK: - Redirects

	func testCrossOriginRedirectRemovesAuthorization() async throws {
		let redirectURL = try XCTUnwrap(URL(string: "https://download.example.com/files/1"))
		let authorizationHeaders = try await authorizationHeaders(redirectingTo: redirectURL)
		XCTAssertEqual(["Bearer token", nil], authorizationHeaders)
	}

	func testSameOriginRedirectKeepsAuthorization() async throws {
		let redirectURL = try XCTUnwrap(URL(string: "https://api.example.com/files/2/content"))
		let authorizationHeaders = try await authorizationHeaders(redirectingTo: redirectURL)
		XCTAssertEqual(["Bearer token", "Bearer token"], authorizationHeaders)
	}

	// MARK: - Helpers

	/// Returns a session whose transfer session the test registry backs with `URLProtocolMock`, because the hostless test bundle can't create background sessions.
	private func makeBackgroundSession() -> SplitURLSession {
		let registry = BackgroundURLSessionRegistry { _ in SplitURLSessionTests.mockConfiguration() }
		return SplitURLSession(configuration: .background(withIdentifier: "test"), registry: registry)
	}

	private static func mockConfiguration() -> URLSessionConfiguration {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		return configuration
	}

	private func sequenceConfiguration() -> URLSessionConfiguration {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolSequenceMock.self]
		return configuration
	}

	private func authorizationHeaders(redirectingTo redirectURL: URL) async throws -> [String?] {
		let authorizationHeaders = OSAllocatedUnfairLock(initialState: [String?]())
		URLProtocolMock.requestHandler = [{ [url] request in
			authorizationHeaders.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
			return (HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": redirectURL.absoluteString])!, nil)
		}, { request in
			authorizationHeaders.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
			return (HTTPURLResponse(url: redirectURL, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("content".utf8))
		}]
		var request = URLRequest(url: url)
		request.setValue("Bearer token", forHTTPHeaderField: "Authorization")

		let (response, data) = try await session.data(for: request)

		XCTAssertEqual(200, response.statusCode)
		XCTAssertEqual(Data("content".utf8), data)
		return authorizationHeaders.withLock { $0 }
	}
}
