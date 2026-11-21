//
//  SplitURLSessionTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

private struct ChallengeFailure: Error {}

private struct RejectingChallengeHandler: SplitURLSession.ChallengeHandler {
	func decision(for challenge: URLAuthenticationChallenge, task: URLSessionTask) -> SplitURLSession.ChallengeDecision {
		return SplitURLSession.ChallengeDecision(disposition: .cancelAuthenticationChallenge, credential: nil, failure: ChallengeFailure())
	}
}

extension UnitTests {
	final class SplitURLSessionTests {
		private let url = URL(string: "https://api.example.com/files/1/content")!
		private let session: SplitURLSession
		private let tmpDirURL: URL

		init() throws {
			URLProtocolMock.requestHandler = []
			URLProtocolSequenceMock.steps = []
			self.session = SplitURLSession(configuration: SplitURLSessionTests.mockConfiguration())
			self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		// MARK: - Routing

		@Test
		func requestsRunOnTheSessionOfTheirRoute() async throws {
			let markedSession = SplitURLSession(configuration: URLProtocolMock.configuration(marker: "transfer"), metadataConfiguration: URLProtocolMock.configuration(marker: "metadata"))
			let markers = OSAllocatedUnfairLock(initialState: [String?]())
			URLProtocolMock.requestHandler = Array(repeating: { [url] request in
				markers.withLock { $0.append(request.value(forHTTPHeaderField: "X-Session")) }
				return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
			}, count: 4)
			let fileURL = tmpDirURL.appendingPathComponent("upload.txt")
			try Data("content".utf8).write(to: fileURL)

			_ = try await markedSession.data(URLRequest(url: url), bodyLimit: nil, bodyLogging: .logged)
			_ = try await markedSession.download(URLRequest(url: url), route: .metadata, handler: { _, _ in .none }, bodyLogging: .logged, urlLogging: .redacted, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)
			_ = try await markedSession.download(URLRequest(url: url), route: .transfer, handler: { _, _ in .none }, bodyLogging: .logged, urlLogging: .redacted, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)
			_ = try await markedSession.upload(URLRequest(url: url), fromFile: fileURL, bodyLimit: nil, bodyLogging: .logged, urlLogging: .redacted, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)

			#expect(markers.withLock { $0 } == ["metadata", "metadata", "transfer", "transfer"])
		}

		@Test
		func backgroundConfigurationRunsDataRequestsOffBackgroundSession() async throws {
			let backgroundSession = makeBackgroundSession()
			let mockURL = try #require(URL(string: "mock://example.com/file"))
			let fileURL = tmpDirURL.appendingPathComponent("upload.txt")
			try Data("content".utf8).write(to: fileURL)
			URLProtocolMock.requestHandler = Array(repeating: { request in
				(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
			}, count: 2)

			let uploadOutcome = try await backgroundSession.upload(URLRequest(url: mockURL), fromFile: fileURL, bodyLimit: nil, bodyLogging: .logged, urlLogging: .redacted, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)
			#expect((uploadOutcome.response as? HTTPURLResponse)?.statusCode == 200)
			#expect(URLProtocolMock.requestHandler.count == 1)

			// The foreground session has no mock, so it rejects the scheme that only the background session's mock handles.
			let dataOutcome = try await backgroundSession.data(URLRequest(url: mockURL), bodyLimit: nil, bodyLogging: .logged)
			#expect(URLError.unsupportedURL == (dataOutcome.error as? URLError)?.code)
			#expect(URLProtocolMock.requestHandler.count == 1, "The data request ran on the background session")
		}

		@Test
		func requestsLogTheirSession() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			let backgroundSession = makeBackgroundSession()
			let mockURL = try #require(URL(string: "mock://example.com/file"))
			let fileURL = tmpDirURL.appendingPathComponent("upload.txt")
			try Data("content".utf8).write(to: fileURL)
			URLProtocolMock.requestHandler = [{ request in
				(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
			}]
			var uploadRequest = URLRequest(url: mockURL)
			uploadRequest.httpMethod = "PUT"

			_ = try await backgroundSession.upload(uploadRequest, fromFile: fileURL, bodyLimit: nil, bodyLogging: .logged, urlLogging: .redacted, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)
			_ = try await backgroundSession.data(URLRequest(url: mockURL), bodyLimit: nil, bodyLogging: .logged)

			let messages = logCapture.messages
			let uploadIndex = try #require(messages.firstIndex(of: "--> PUT mock://example.com/file"))
			let dataIndex = try #require(messages.firstIndex(of: "--> GET mock://example.com/file"))
			#expect(messages[uploadIndex + 1] == "Session: background test")
			#expect(messages[dataIndex + 1] == "Session: foreground")
		}

		@Test
		func downloadLogsURLsByItsURLLogging() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			let downloadURL = try #require(URL(string: "https://download.example.com/REQUESTPATH/file.txt"))
			URLProtocolMock.requestHandler = Array(repeating: { request in
				(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Location": "https://download.example.com/RESPONSEPATH/file.txt"])!, Data())
			}, count: 2)

			_ = try await session.download(URLRequest(url: downloadURL), route: .transfer, handler: { _, _ in .none }, bodyLogging: .logged, urlLogging: .originOnly, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)
			let originOnlyLog = logCapture.joinedMessages
			_ = try await session.download(URLRequest(url: downloadURL), route: .transfer, handler: { _, _ in .none }, bodyLogging: .logged, urlLogging: .redacted, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)
			let redactedLog = logCapture.joinedMessages

			#expect(originOnlyLog.contains("https://download.example.com/<redacted>"), "\(originOnlyLog)")
			#expect(!originOnlyLog.contains("REQUESTPATH"), "\(originOnlyLog)")
			#expect(!originOnlyLog.contains("RESPONSEPATH"), "\(originOnlyLog)")
			#expect(redactedLog.contains("REQUESTPATH"), "\(redactedLog)")
			#expect(redactedLog.contains("RESPONSEPATH"), "\(redactedLog)")
		}

		@Test
		func responseRedirectedToAnotherOriginLogsOnlyItsOrigin() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 302, headerFields: ["Location": "https://download.example.com/SECRET-PATH/file.txt"]),
				URLProtocolMock.handler()
			]

			_ = try await session.download(URLRequest(url: url), route: .transfer, handler: { _, _ in .none }, bodyLogging: .logged, urlLogging: .redacted, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)

			#expect(logCapture.messages.contains("--> GET https://api.example.com/files/1/content"), "\(logCapture.joinedMessages)")
			#expect(logCapture.messages.contains("<-- 200 no error https://download.example.com/<redacted>"), "\(logCapture.joinedMessages)")
			#expect(!logCapture.joinedMessages.contains("SECRET"), "\(logCapture.joinedMessages)")
		}

		@Test
		func responseRedirectedWithinTheOriginLogsItsPath() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 302, headerFields: ["Location": "/files/2/content"]),
				URLProtocolMock.handler()
			]

			_ = try await session.download(URLRequest(url: url), route: .transfer, handler: { _, _ in .none }, bodyLogging: .logged, urlLogging: .redacted, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)

			#expect(logCapture.messages.contains("<-- 200 no error https://api.example.com/files/2/content"), "\(logCapture.joinedMessages)")
		}

		@Test
		func overlappingRequestsGetTheirOwnOutcomes() async throws {
			let firstSession = SplitURLSession(configuration: SplitURLSessionTests.mockConfiguration())
			let secondSession = SplitURLSession(configuration: SplitURLSessionTests.mockConfiguration())
			URLProtocolMock.requestHandler = Array(repeating: { request in
				(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(request.url!.lastPathComponent.utf8))
			}, count: 2)
			let firstRequest = URLRequest(url: url.appendingPathComponent("first"))
			let secondRequest = URLRequest(url: url.appendingPathComponent("second"))
			let firstHeld = TestSignal("first task held")
			let secondFinished = DispatchSemaphore(value: 0)
			let firstWaitResult = OSAllocatedUnfairLock<DispatchTimeoutResult?>(initialState: nil)

			// The download handler holds the first task with its record registered until the second request finished.
			let first = Task {
				try await firstSession.download(firstRequest, route: .transfer, handler: { location, _ in
					firstHeld.fulfill()
					let waitResult = secondFinished.wait(timeout: testWaitDeadline())
					firstWaitResult.withLock { $0 = waitResult }
					return try .data(Data(contentsOf: location))
				}, bodyLogging: .logged, urlLogging: .redacted, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)
			}
			await firstHeld.wait()
			let secondOutcome = try await secondSession.data(secondRequest, bodyLimit: nil, bodyLogging: .logged)
			secondFinished.signal()
			let firstOutcome = try await cancellingValue(of: first)

			#expect(firstWaitResult.withLock { $0 } == .success, "The requests did not overlap")
			#expect(Data("first".utf8) == firstOutcome.data)
			#expect(Data("second".utf8) == secondOutcome.data)
		}

		// MARK: - Body Limit

		@Test
		func bodyAtLimitIsReturned() async throws {
			let sequenceSession = SplitURLSession(configuration: sequenceConfiguration())
			URLProtocolSequenceMock.steps = try [.chunkedResponse(#require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)), [Data(count: 32 * 1024), Data(count: 32 * 1024)])]

			let outcome = try await sequenceSession.data(URLRequest(url: url), bodyLimit: 64 * 1024, bodyLogging: .logged)

			#expect(.data(Data(count: 64 * 1024)) == outcome.body)
			#expect(outcome.recordedFailure == nil)
		}

		@Test
		func bodyOverLimitIsDiscardedAfterTaskTerminated() async throws {
			let completionReached = TestSignal("terminal processing reached")
			let completionGate = DispatchSemaphore(value: 0)
			let hooks = SplitURLSession.Hooks(willProcessCompletion: { _ in
				completionReached.fulfill()
				_ = completionGate.wait(timeout: testWaitDeadline())
			})
			let sequenceSession = SplitURLSession(configuration: sequenceConfiguration(), hooks: hooks)
			URLProtocolSequenceMock.steps = try [.chunkedResponse(#require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)), [Data(count: 64 * 1024), Data(count: 1)])]

			let returned = TestSignal("call returned before the task terminated")
			let request = Task { [url] in
				defer { returned.fulfill() }
				return try await sequenceSession.data(URLRequest(url: url), bodyLimit: 64 * 1024, bodyLogging: .logged)
			}
			await completionReached.wait()
			await returned.expectNoFulfillment(within: .seconds(0.2))
			completionGate.signal()
			let outcome = try await cancellingValue(of: request)

			guard case let .responseBodyTooLarge(limit)? = outcome.recordedFailure as? SplitURLSessionError else {
				Issue.record("Unexpected recorded failure: \(String(describing: outcome.recordedFailure))")
				return
			}
			#expect(64 * 1024 == limit)
			#expect(SplitURLSession.Outcome.Body.none == outcome.body)
		}

		// MARK: - Challenges

		@Test
		func rejectedChallengeRecordsItsFailure() async throws {
			let sequenceSession = SplitURLSession(configuration: sequenceConfiguration(), challengeHandler: RejectingChallengeHandler())
			let failureResponse = try #require(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil))
			URLProtocolSequenceMock.steps = [.authChallenge(URLAuthenticationChallengeMock(previousFailureCount: 0, failureResponse: failureResponse))]

			let outcome = try await sequenceSession.data(URLRequest(url: url), bodyLimit: nil, bodyLogging: .logged)

			#expect(outcome.recordedFailure is ChallengeFailure)
			#expect(try isCancellationError(#require(outcome.error)))
		}

		// MARK: - Downloads

		@Test
		func downloadMovesBodyOfSuccessfulResponse() async throws {
			let stagingURL = tmpDirURL.appendingPathComponent("file.txt")
			URLProtocolMock.requestHandler = [{ [url] _ in
				(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("new".utf8))
			}]

			let outcome = try await download(to: stagingURL)

			#expect(try HTTPClientSupport.httpResponse(of: outcome).statusCode == 200)
			#expect(.file(stagingURL) == outcome.body)
			#expect(try Data("new".utf8) == Data(contentsOf: stagingURL))
		}

		@Test
		func unsuccessfulDownloadReturnsBodyAsData() async throws {
			let stagingURL = tmpDirURL.appendingPathComponent("file.txt")
			URLProtocolMock.requestHandler = [{ [url] _ in
				(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("not found".utf8))
			}]

			let outcome = try await download(to: stagingURL)

			#expect(try HTTPClientSupport.httpResponse(of: outcome).statusCode == 404)
			#expect(.data(Data("not found".utf8)) == outcome.body)
			#expect(!FileManager.default.fileExists(atPath: stagingURL.path))
		}

		@Test
		func downloadRecordsMoveError() async throws {
			let stagingURL = tmpDirURL.appendingPathComponent("missing", isDirectory: true).appendingPathComponent("file.txt")
			URLProtocolMock.requestHandler = [{ [url] _ in
				(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("content".utf8))
			}]

			let outcome = try await download(to: stagingURL)

			#expect(outcome.recordedFailure is CocoaError, "Unexpected failure: \(String(describing: outcome.recordedFailure))")
		}

		// MARK: - Redirects

		@Test
		func crossOriginRedirectRemovesAuthorization() async throws {
			let redirectURL = try #require(URL(string: "https://download.example.com/files/1"))
			let authorizationHeaders = try await authorizationHeaders(redirectingTo: redirectURL)
			#expect(authorizationHeaders == ["Bearer token", nil])
		}

		@Test
		func sameOriginRedirectKeepsAuthorization() async throws {
			let redirectURL = try #require(URL(string: "https://api.example.com/files/2/content"))
			let authorizationHeaders = try await authorizationHeaders(redirectingTo: redirectURL)
			#expect(authorizationHeaders == ["Bearer token", "Bearer token"])
		}

		// MARK: - Helpers

		private func download(to stagingURL: URL) async throws -> SplitURLSession.Outcome {
			return try await session.download(URLRequest(url: url), route: .transfer, handler: HTTPClientSupport.downloadHandler(movingTo: stagingURL, maxErrorBodyLength: 1024), bodyLogging: .logged, urlLogging: .redacted, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)
		}

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

			let outcome = try await session.data(request, bodyLimit: nil, bodyLogging: .logged)

			#expect(try HTTPClientSupport.httpResponse(of: outcome).statusCode == 200)
			#expect(Data("content".utf8) == outcome.data)
			return authorizationHeaders.withLock { $0 }
		}
	}
}
