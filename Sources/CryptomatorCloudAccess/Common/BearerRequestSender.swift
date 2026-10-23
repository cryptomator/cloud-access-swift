//
//  BearerRequestSender.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 22.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

protocol BearerTokenSource: Sendable {
	func accessToken() async throws -> String
	/// Returns a token that replaces the rejected one.
	func refresh(rejecting accessToken: String) async throws -> String
}

/// Which responses of a request are retried, and how long a retry waits.
struct RetryPolicy {
	let isRetryable: (HTTPURLResponse, SplitURLSession.Outcome) -> Bool
	/// The error of a retried response, for the log.
	let failure: (HTTPURLResponse, SplitURLSession.Outcome) -> Error
	/// Whether a transient transport error is retried, which is safe only for a request that may be applied twice.
	let retriesTransportErrors: Bool
	/// The wait before retrying a response, given the number of the attempt that got it.
	let retryDelay: (HTTPURLResponse, SplitURLSession.Outcome, _ attempt: Int) -> Duration

	init(retriesTransportErrors: Bool, isRetryable: @escaping (HTTPURLResponse, SplitURLSession.Outcome) -> Bool, failure: @escaping (HTTPURLResponse, SplitURLSession.Outcome) -> Error, retryDelay: @escaping (HTTPURLResponse, SplitURLSession.Outcome, _ attempt: Int) -> Duration = { response, _, attempt in HTTPClientSupport.retryDelay(for: response, attempt: attempt, now: Date()) }) {
		self.retriesTransportErrors = retriesTransportErrors
		self.isRetryable = isRetryable
		self.failure = failure
		self.retryDelay = retryDelay
	}
}

/**
 Makes the attempts of a request that carries the bearer token of a token source, until one is final.

 A 401 refreshes the token and retries once. A request makes at most `maxAttemptCount` attempts, counting the one after a refresh. The last attempt's response is returned whatever its status, even a 401. A cancelled task stops a request before each attempt, before a refresh and before each wait. A running attempt finishes either way.
 */
struct BearerRequestSender: Sendable {
	enum Authorization {
		/// The request carries the token, and a 401 refreshes it once.
		case bearer
		/// The request is sent to a pre-authenticated URL, which must not receive the token. A 401 is final.
		case none
	}

	static let maxAttemptCount = 5

	private let tokenSource: any BearerTokenSource
	/// The name of the client that log lines start with.
	private let logLabel: String
	private let sleep: @Sendable (Duration) async throws -> Void

	init(tokenSource: any BearerTokenSource, logLabel: String, sleep: @escaping @Sendable (Duration) async throws -> Void) {
		self.tokenSource = tokenSource
		self.logLabel = logLabel
		self.sleep = sleep
	}

	/**
	 Returns the response of the final attempt, whatever its status. A transport error is mapped to `CloudProviderError.noInternetConnection` only when it is thrown, because the retry decision reads the raw error and most transient connection errors are also network connection errors.

	 - Parameter urlLogging: How the failure log shows the request's URL.
	 - Parameter progress: The progress to which each attempt adds its task's progress with a pending unit count of 1. Its total unit count grows by 1 before each further attempt, so that the attempts never push it past complete.
	 - Parameter attempt: Sends the request once.
	 */
	func send(_ request: URLRequest, authorization: Authorization = .bearer, urlLogging: HTTPDebugLogger.URLLogging, policy: RetryPolicy, progress: Progress? = nil, attempt: (URLRequest, _ isFirstAttempt: Bool) async throws -> SplitURLSession.Outcome) async throws -> (HTTPURLResponse, SplitURLSession.Outcome) {
		try Task.checkCancellation()
		var accessToken: String? = switch authorization {
		case .bearer:
			try await tokenSource.accessToken()
		case .none:
			nil
		}
		var attemptCount = 0
		var hasRefreshed = false
		while true {
			try Task.checkCancellation()
			if attemptCount > 0 {
				progress?.totalUnitCount += 1
			}
			attemptCount += 1
			var authorizedRequest = request
			if let accessToken {
				authorizedRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
			}
			let outcome = try await attempt(authorizedRequest, attemptCount == 1)
			let response: HTTPURLResponse
			do {
				response = try HTTPClientSupport.httpResponse(of: outcome)
			} catch {
				HTTPClientSupport.logFailure(of: request, urlLogging: urlLogging, with: error, label: logLabel)
				guard policy.retriesTransportErrors, attemptCount < BearerRequestSender.maxAttemptCount, (error as? URLError).map(HTTPClientSupport.isTransient) ?? false else {
					throw isNetworkConnectionError(error) ? CloudProviderError.noInternetConnection : error
				}
				try Task.checkCancellation()
				try await sleep(.seconds(HTTPClientSupport.retryDelay(forRetry: attemptCount)))
				continue
			}
			guard attemptCount < BearerRequestSender.maxAttemptCount else {
				return (response, outcome)
			}
			if response.statusCode == 401, let rejectedAccessToken = accessToken, !hasRefreshed {
				hasRefreshed = true
				try Task.checkCancellation()
				accessToken = try await tokenSource.refresh(rejecting: rejectedAccessToken)
				continue
			}
			guard policy.isRetryable(response, outcome) else {
				return (response, outcome)
			}
			HTTPClientSupport.logFailure(of: request, urlLogging: urlLogging, with: policy.failure(response, outcome), label: logLabel)
			try Task.checkCancellation()
			try await sleep(policy.retryDelay(response, outcome, attemptCount))
		}
	}
}
