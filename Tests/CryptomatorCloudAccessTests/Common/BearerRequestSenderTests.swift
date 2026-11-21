//
//  BearerRequestSenderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class BearerRequestSenderTests {
		private let request = URLRequest(url: URL(string: "https://api.example.com/item")!)
		private let tokenSource: OAuthTokenSourceStub
		private let sleeps: SleepRecorder
		private let sender: BearerRequestSender

		init() {
			self.tokenSource = OAuthTokenSourceStub()
			self.sleeps = SleepRecorder()
			self.sender = BearerRequestSender(tokenSource: tokenSource, logLabel: "BearerRequestSenderTests", sleep: { [sleeps] in sleeps.sleep(for: $0) })
		}

		// MARK: - Refresh

		@Test
		func unauthorizedRefreshesOnce() async throws {
			let attempts = ScriptedAttempts([.status(401), .status(401), .status(200)])

			let (response, _) = try await sender.send(request, urlLogging: .redacted, policy: .serverErrors(), attempt: attempts.attempt)

			#expect(response.statusCode == 401)
			#expect(attempts.authorizations == ["Bearer TOKEN", "Bearer REFRESHED"])
			#expect(tokenSource.rejectedTokens == ["TOKEN"])
			#expect(sleeps.durations.isEmpty)
		}

		@Test
		func unauthorizedLastAttemptIsReturnedWithoutRefresh() async throws {
			let attempts = ScriptedAttempts([.status(503), .status(503), .status(503), .status(503), .status(401), .status(200)])

			let (response, _) = try await sender.send(request, urlLogging: .redacted, policy: .serverErrors(), attempt: attempts.attempt)

			#expect(response.statusCode == 401)
			#expect(attempts.count == 5)
			#expect(tokenSource.rejectedTokens.isEmpty)
		}

		@Test
		func refreshCountsAsAttempt() async throws {
			let attempts = ScriptedAttempts([.status(503), .status(503), .status(503), .status(401), .status(503), .status(200)])

			let (response, _) = try await sender.send(request, urlLogging: .redacted, policy: .serverErrors(), attempt: attempts.attempt)

			#expect(response.statusCode == 503)
			#expect(attempts.count == 5)
			#expect(tokenSource.rejectedTokens == ["TOKEN"])
		}

		@Test
		func vetoedUnauthorizedIsReturnedWithoutRefresh() async throws {
			let attempts = ScriptedAttempts([.status(401), .status(200)])

			let (response, _) = try await sender.send(request, urlLogging: .redacted, policy: .serverErrors(refreshesUnauthorized: false), attempt: attempts.attempt)

			#expect(response.statusCode == 401)
			#expect(attempts.count == 1)
			#expect(tokenSource.rejectedTokens.isEmpty)
		}

		@Test
		func failedRefreshIsThrown() async throws {
			let sender = BearerRequestSender(tokenSource: FailingRefreshTokenSource(), logLabel: "BearerRequestSenderTests", sleep: { [sleeps] in sleeps.sleep(for: $0) })
			let attempts = ScriptedAttempts([.status(401), .status(200)])

			await #expect(throws: OAuthTokenStoreError.lockTimeout) { try await sender.send(self.request, urlLogging: .redacted, policy: .serverErrors(), attempt: attempts.attempt) }
			#expect(attempts.count == 1)
			#expect(sleeps.durations.isEmpty)
		}

		@Test
		func unauthorizedWithoutAuthorizationReadsNoToken() async throws {
			tokenSource.accessTokenError = CocoaError(.fileReadUnknown)
			let attempts = ScriptedAttempts([.status(401), .status(200)])

			let (response, _) = try await sender.send(request, authorization: .none, urlLogging: .originOnly, policy: .serverErrors(), attempt: attempts.attempt)

			#expect(response.statusCode == 401)
			#expect(attempts.authorizations == [nil])
			#expect(tokenSource.rejectedTokens.isEmpty)
		}

		// MARK: - Retries

		@Test
		func retryableStatusesStopAfterFiveAttempts() async throws {
			let attempts = ScriptedAttempts(Array(repeating: .status(503), count: 6))

			let (response, _) = try await sender.send(request, urlLogging: .redacted, policy: .serverErrors(), attempt: attempts.attempt)

			#expect(response.statusCode == 503)
			#expect(attempts.count == 5)
			#expect(sleeps.durations.count == 4)
		}

		@Test
		func transportErrorsAreRetriedOnlyIfThePolicyAllows() async throws {
			let retried = ScriptedAttempts([.failure(URLError(.timedOut)), .status(200)])

			let (response, _) = try await sender.send(request, urlLogging: .redacted, policy: .serverErrors(retriesTransportErrors: true), attempt: retried.attempt)

			#expect(response.statusCode == 200)
			#expect(retried.count == 2)

			let notRetried = ScriptedAttempts([.failure(URLError(.timedOut)), .status(200)])

			let error = try await #require(throws: URLError.self) { try await self.sender.send(self.request, urlLogging: .redacted, policy: .serverErrors(), attempt: notRetried.attempt) }
			#expect(error.code == .timedOut)
			#expect(notRetried.count == 1)
		}

		@Test
		func nonTransientTransportErrorIsNotRetried() async throws {
			let attempts = ScriptedAttempts([.failure(URLError(.notConnectedToInternet)), .status(200)])

			await #expect(throws: CloudProviderError.noInternetConnection) { try await self.sender.send(self.request, urlLogging: .redacted, policy: .serverErrors(retriesTransportErrors: true), attempt: attempts.attempt) }
			#expect(attempts.count == 1)
		}

		@Test
		func transportErrorAfterLastAttemptIsMapped() async throws {
			let attempts = ScriptedAttempts(Array(repeating: .failure(URLError(.networkConnectionLost)), count: 6))

			await #expect(throws: CloudProviderError.noInternetConnection) { try await self.sender.send(self.request, urlLogging: .redacted, policy: .serverErrors(retriesTransportErrors: true), attempt: attempts.attempt) }
			#expect(attempts.count == 5)
			#expect(sleeps.durations.count == 4)
		}

		@Test
		func retryAfterIsFollowedAndCapped() async throws {
			for (retryAfter, expectedWait) in [("2", Duration.seconds(2)), ("3600", .seconds(HTTPClientSupport.maxRetryDelay))] {
				let sleeps = SleepRecorder()
				let sender = BearerRequestSender(tokenSource: tokenSource, logLabel: "BearerRequestSenderTests", sleep: { sleeps.sleep(for: $0) })
				let attempts = ScriptedAttempts([.status(429, headerFields: ["Retry-After": retryAfter]), .status(200)])

				_ = try await sender.send(request, urlLogging: .redacted, policy: RetryPolicy(retriesTransportErrors: false, isRetryable: { response, _ in response.statusCode == 429 }, failure: { response, _ in URLError(.init(rawValue: response.statusCode)) }), attempt: attempts.attempt)

				#expect([expectedWait] == sleeps.durations, "\(retryAfter)")
			}
		}

		@Test
		func totalUnitCountGrowsPerFurtherAttempt() async throws {
			let progress = Progress(totalUnitCount: 1)
			let attempts = ScriptedAttempts([.status(503), .status(401), .status(200)])

			_ = try await sender.send(request, urlLogging: .redacted, policy: .serverErrors(), progress: progress, attempt: attempts.attempt)

			#expect(progress.totalUnitCount == 3)
		}

		// MARK: - Cancellation

		@Test
		func cancelledTaskGetsNoToken() async throws {
			let accessTokenCount = OSAllocatedUnfairLock(initialState: 0)
			let sender = BearerRequestSender(tokenSource: OAuthTokenSourceStub(onAccessToken: { accessTokenCount.withLock { $0 += 1 } }), logLabel: "BearerRequestSenderTests", sleep: { _ in })
			let attempts = ScriptedAttempts([.status(200)])

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: cancelledTask { [request] in try await sender.send(request, urlLogging: .redacted, policy: .serverErrors(), attempt: attempts.attempt).0 }) }
			#expect(accessTokenCount.withLock { $0 } == 0)
			#expect(attempts.authorizations.isEmpty)
		}

		@Test
		func cancellationWhileGettingTokenStopsFirstAttempt() async throws {
			let sender = BearerRequestSender(tokenSource: OAuthTokenSourceStub(onAccessToken: { withUnsafeCurrentTask { $0?.cancel() } }), logLabel: "BearerRequestSenderTests", sleep: { _ in })
			let attempts = ScriptedAttempts([.status(200)])

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: Task { [request] in try await sender.send(request, urlLogging: .redacted, policy: .serverErrors(), attempt: attempts.attempt).0 }) }
			#expect(attempts.authorizations.isEmpty)
		}

		@Test
		func cancellationDuringRefreshStopsRetry() async throws {
			let tokenSource = OAuthTokenSourceStub(onRefresh: { withUnsafeCurrentTask { $0?.cancel() } })
			let sender = BearerRequestSender(tokenSource: tokenSource, logLabel: "BearerRequestSenderTests", sleep: { _ in })
			let attempts = ScriptedAttempts([.status(401), .status(200)])

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: Task { [request] in try await sender.send(request, urlLogging: .redacted, policy: .serverErrors(), attempt: attempts.attempt).0 }) }
			#expect(attempts.count == 1)
			#expect(tokenSource.rejectedTokens == ["TOKEN"])
		}

		@Test
		func cancellationDuringAttemptSendsNoRefresh() async throws {
			for refreshesUnauthorized in [true, false] {
				let tokenSource = OAuthTokenSourceStub()
				let sender = BearerRequestSender(tokenSource: tokenSource, logLabel: "BearerRequestSenderTests", sleep: { _ in })
				let attempts = ScriptedAttempts([.status(401), .status(200)], cancellingOnAttempt: 1)

				await #expect(throws: CancellationError.self, "\(refreshesUnauthorized)") { try await cancellingValue(of: Task { [request] in try await sender.send(request, urlLogging: .redacted, policy: .serverErrors(refreshesUnauthorized: refreshesUnauthorized), attempt: attempts.attempt).0 }) }
				#expect(attempts.count == 1, "\(refreshesUnauthorized)")
				#expect(tokenSource.rejectedTokens.isEmpty, "\(refreshesUnauthorized)")
			}
		}

		@Test
		func cancellationDuringRetryWaitSendsNoFurtherAttempt() async throws {
			let sender = BearerRequestSender(tokenSource: tokenSource, logLabel: "BearerRequestSenderTests", sleep: { _ in withUnsafeCurrentTask { $0?.cancel() } })
			let attempts = ScriptedAttempts([.status(503), .status(200)])

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: Task { [request] in try await sender.send(request, urlLogging: .redacted, policy: .serverErrors(), attempt: attempts.attempt).0 }) }
			#expect(attempts.count == 1)
		}
	}
}

private extension RetryPolicy {
	/// Retries a 5xx, and a transient transport error if `retriesTransportErrors` holds.
	static func serverErrors(retriesTransportErrors: Bool = false, refreshesUnauthorized: Bool = true) -> RetryPolicy {
		return RetryPolicy(retriesTransportErrors: retriesTransportErrors, isRetryable: { response, _ in response.statusCode >= 500 }, failure: { response, _ in URLError(.init(rawValue: response.statusCode)) }, retryDelay: { _, _, _ in .zero }, refreshesUnauthorized: { _, _ in refreshesUnauthorized })
	}
}

/// Answers the attempts of a request in order, and records the `Authorization` header of each.
private final class ScriptedAttempts: Sendable {
	enum Answer {
		case status(Int, headerFields: [String: String]? = nil)
		case failure(URLError)
	}

	private let answers: [Answer]
	private let cancellingAttempt: Int?
	private let recordedAuthorizations = OSAllocatedUnfairLock(initialState: [String?]())

	/// - Parameter cancellingAttempt: The number of the attempt during which the calling task is cancelled.
	init(_ answers: [Answer], cancellingOnAttempt cancellingAttempt: Int? = nil) {
		self.answers = answers
		self.cancellingAttempt = cancellingAttempt
	}

	var authorizations: [String?] {
		return recordedAuthorizations.withLock { $0 }
	}

	var count: Int {
		return authorizations.count
	}

	var attempt: @Sendable (URLRequest, Bool) async throws -> SplitURLSession.Outcome {
		return { request, _ in
			let number = self.recordedAuthorizations.withLock { authorizations in
				authorizations.append(request.value(forHTTPHeaderField: "Authorization"))
				return authorizations.count
			}
			if number == self.cancellingAttempt {
				withUnsafeCurrentTask { $0?.cancel() }
			}
			guard number <= self.answers.count else {
				throw UnexpectedAttemptError(number: number)
			}
			switch self.answers[number - 1] {
			case let .status(statusCode, headerFields):
				return SplitURLSession.Outcome(response: HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: headerFields), body: .data(Data()), error: nil, recordedFailure: nil)
			case let .failure(error):
				return SplitURLSession.Outcome(response: nil, body: .none, error: error, recordedFailure: nil)
			}
		}
	}
}

private struct UnexpectedAttemptError: Error {
	let number: Int
}

private struct FailingRefreshTokenSource: BearerTokenSource {
	func accessToken() async throws -> String {
		return "TOKEN"
	}

	func refresh(rejecting accessToken: String) async throws -> String {
		throw OAuthTokenStoreError.lockTimeout
	}
}
