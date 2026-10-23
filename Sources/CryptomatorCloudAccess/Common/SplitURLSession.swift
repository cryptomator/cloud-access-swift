//
//  SplitURLSession.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 14.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os

enum SplitURLSessionError: Error {
	case responseBodyTooLarge(limit: Int)
}

private struct TaskRecord {
	let resumer: Resumer<SplitURLSession.Outcome>
	let challengeHandler: SplitURLSession.ChallengeHandler?
	let hooks: SplitURLSession.Hooks
	let bodyLimit: Int?
	let bodyLogging: HTTPDebugLogger.BodyLogging
	let urlLogging: HTTPDebugLogger.URLLogging
	let downloadHandler: SplitURLSession.DownloadHandler?
	var accumulatedData = Data()
	var downloadedBody = SplitURLSession.Outcome.Body.none
	var recordedFailure: Error?

	var body: SplitURLSession.Outcome.Body {
		if downloadHandler != nil {
			return downloadedBody
		}
		return recordedFailure == nil ? .data(accumulatedData) : .none
	}

	/// Returns whether the data exceeded the body limit, in which case the body is discarded and the task has to be cancelled.
	mutating func append(_ data: Data) -> Bool {
		guard recordedFailure == nil else {
			return false
		}
		if let bodyLimit, accumulatedData.count + data.count > bodyLimit {
			accumulatedData = Data()
			recordedFailure = SplitURLSessionError.responseBodyTooLarge(limit: bodyLimit)
			return true
		}
		accumulatedData.append(data)
		return false
	}

	func complete(with response: URLResponse?, error: Error?) {
		let body = body
		if let response {
			switch body {
			case let .data(data):
				HTTPDebugLogger.logResponse(response, with: data, or: nil, bodyLogging: bodyLogging, urlLogging: urlLogging)
			case let .file(url):
				HTTPDebugLogger.logResponse(response, with: nil, or: url, bodyLogging: bodyLogging, urlLogging: urlLogging)
			case .none:
				HTTPDebugLogger.logResponse(response, with: nil, or: nil, bodyLogging: bodyLogging, urlLogging: urlLogging)
			}
		}
		resumer.resume(returning: SplitURLSession.Outcome(response: response, body: body, error: error, recordedFailure: recordedFailure))
	}
}

/// The delegate of every session of `SplitURLSession`. It is shared because a background session from `BackgroundURLSessionRegistry` serves several `SplitURLSession`s, so it routes the callbacks of a task to the record that its attempt registered.
final class SplitURLSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, Sendable {
	static let shared = SplitURLSessionDelegate()

	private let records = OSAllocatedUnfairLock(initialState: [URLSessionTask: TaskRecord]())

	fileprivate func register(_ record: TaskRecord, for task: URLSessionTask) {
		records.withLock {
			$0[task] = record
		}
	}

	/// Completes the attempt of a terminated task, unless it was completed already.
	fileprivate func completeTask(_ task: URLSessionTask, error: Error?) {
		guard let record = records.withLock({ $0.removeValue(forKey: task) }) else {
			return
		}
		record.hooks.willProcessCompletion(task)
		record.complete(with: task.response, error: error)
	}

	// MARK: - URLSessionTaskDelegate

	/// Also receives the session-wide challenges, e.g., server trust, because the session-level variant is not implemented.
	func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		guard let (challengeHandler, hooks) = records.withLock({ $0[task].map { ($0.challengeHandler, $0.hooks) } }) else {
			// A task without a record, e.g., one that an earlier process left on a background session, might have a URL that is a credential.
			CloudAccessDDLogDebug("SplitURLSessionDelegate: received a challenge for the unknown task of \(HTTPDebugLogger.redactedURLString(task.originalRequest?.url, urlLogging: .originOnly))")
			completionHandler(.performDefaultHandling, nil)
			return
		}
		guard let challengeHandler else {
			completionHandler(.performDefaultHandling, nil)
			return
		}
		let decision = challengeHandler.decision(for: challenge, task: task)
		if let failure = decision.failure {
			records.withLock {
				$0[task]?.recordedFailure = failure
			}
		}
		completionHandler(decision.disposition, decision.credential)
		hooks.didApplyChallengeDecision(task, decision)
	}

	/// Removes the `Authorization` header when a redirect changes the scheme, host or port, e.g., to a pre-signed download URL. Only foreground sessions call this. A background session follows redirects on its own.
	func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
		var request = request
		let currentURL = task.currentRequest?.url
		if request.url?.scheme != currentURL?.scheme || request.url?.host != currentURL?.host || request.url?.port != currentURL?.port {
			request.setValue(nil, forHTTPHeaderField: "Authorization")
		}
		completionHandler(request)
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		completeTask(task, error: error)
	}

	// MARK: - URLSessionDataDelegate

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		let exceedsBodyLimit = records.withLock {
			$0[dataTask]?.append(data) ?? false
		}
		if exceedsBodyLimit {
			dataTask.cancel()
		}
	}

	// MARK: - URLSessionDownloadDelegate

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		guard let downloadHandler = records.withLock({ $0[downloadTask]?.downloadHandler }) else {
			return
		}
		do {
			let body = try downloadHandler(location, downloadTask.response)
			records.withLock {
				$0[downloadTask]?.downloadedBody = body
			}
		} catch {
			records.withLock {
				$0[downloadTask]?.recordedFailure = error
			}
		}
	}
}

private extension URLSessionTask {
	/// Whether the task was cancelled or completed before it was resumed, i.e., while `onTaskCreation` ran. Its terminal delegate call may have found nothing registered then.
	var isTerminated: Bool {
		return state == .canceling || state == .completed || error != nil
	}
}

/**
 `URLSession` wrapper that also works with a background configuration.

 Downloads and uploads run on a transfer session with the given configuration, as download and upload tasks. Uploads are sent from a file, which is the only kind of upload a background session supports. Other requests run as data tasks on a foreground metadata session, because a background session doesn't support them. A download can also run on the metadata session. Background sessions are shared per identifier through `BackgroundURLSessionRegistry` and live for the process.

 Each call makes one attempt and returns its raw outcome, whatever its status code. Authentication, retries and the mapping of statuses to errors are up to the caller.

 Task cancellation is not forwarded to a running request, so a request returns only after its `URLSessionTask` has terminated. With `cancelsBeforeResume`, a cancellation that arrives before the task is resumed cancels the task instead.
 */
final class SplitURLSession: Sendable {
	enum DownloadRoute {
		case transfer
		case metadata
	}

	struct Outcome: Sendable {
		// swiftlint:disable:next nesting
		enum Body: Sendable, Equatable {
			case data(Data)
			case file(URL)
			case none
		}

		let response: URLResponse?
		let body: Body
		let error: Error?
		/// A failure that was recorded while the task was running, e.g., by a challenge handler, the body limit or a download handler. It takes precedence over `error`, which may be the cancellation that the failure caused.
		let recordedFailure: Error?

		var data: Data? {
			guard case let .data(data) = body else {
				return nil
			}
			return data
		}
	}

	/// Disposes of the downloaded file at the given location, which only exists while the handler runs, and returns the body of the outcome. A thrown error becomes the recorded failure.
	typealias DownloadHandler = @Sendable (URL, URLResponse?) throws -> Outcome.Body

	struct ChallengeDecision {
		let disposition: URLSession.AuthChallengeDisposition
		let credential: URLCredential?
		/// The failure to record for the task, e.g., because its credential was rejected.
		let failure: Error?
	}

	protocol ChallengeHandler: Sendable {
		func decision(for challenge: URLAuthenticationChallenge, task: URLSessionTask) -> ChallengeDecision
	}

	/// Lets tests observe and hold back a task. Both usually run on the delegate queue of the task's session. For a task that terminated before it was resumed, `willProcessCompletion` runs on the calling task instead.
	struct Hooks: Sendable {
		var didApplyChallengeDecision: @Sendable (URLSessionTask, ChallengeDecision) -> Void = { _, _ in }
		var willProcessCompletion: @Sendable (URLSessionTask) -> Void = { _ in }
	}

	private struct Attempt {
		let sessionDescription: String
		let bodyLimit: Int?
		let bodyLogging: HTTPDebugLogger.BodyLogging
		let urlLogging: HTTPDebugLogger.URLLogging
		let downloadHandler: DownloadHandler?
		let cancelsBeforeResume: Bool
	}

	private static let foregroundSessionDescription = "foreground"

	private let transferSession: URLSession
	private let transferSessionDescription: String
	private let metadataSession: URLSession
	private let ownedSessions: [URLSession]
	private let challengeHandler: ChallengeHandler?
	private let hooks: Hooks

	/**
	 - Parameter configuration: The configuration of the transfer session. A background configuration gets its session from `registry`.
	 - Parameter metadataConfiguration: Without one, a background `configuration` gets a hardened `.default` metadata session, and a foreground one shares its session with the metadata requests.
	 - Parameter challengeHandler: Decides every authentication challenge of the requests. Without one, the system handles them.
	 */
	init(configuration: URLSessionConfiguration, metadataConfiguration: URLSessionConfiguration? = nil, challengeHandler: ChallengeHandler? = nil, hooks: Hooks = Hooks(), registry: BackgroundURLSessionRegistry = .shared) {
		let delegate = SplitURLSessionDelegate.shared
		var ownedSessions = [URLSession]()
		if let identifier = configuration.identifier {
			self.transferSession = registry.session(for: configuration)
			self.transferSessionDescription = "background \(identifier)"
		} else {
			self.transferSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
			self.transferSessionDescription = SplitURLSession.foregroundSessionDescription
			ownedSessions.append(transferSession)
		}
		if let metadataConfiguration {
			self.metadataSession = URLSession(configuration: metadataConfiguration, delegate: delegate, delegateQueue: nil)
			ownedSessions.append(metadataSession)
		} else if configuration.identifier != nil {
			self.metadataSession = URLSession(configuration: HTTPClientSupport.hardened(.default), delegate: delegate, delegateQueue: nil)
			ownedSessions.append(metadataSession)
		} else {
			self.metadataSession = transferSession
		}
		self.ownedSessions = ownedSessions
		self.challengeHandler = challengeHandler
		self.hooks = hooks
	}

	/// An attempt retains its `SplitURLSession`, so this never cancels a running request of it.
	deinit {
		for session in ownedSessions {
			session.invalidateAndCancel()
		}
	}

	// MARK: - Attempts

	/// - Parameter bodyLimit: The maximum length of the response body. A longer body is discarded and cancels the task, and the outcome records `SplitURLSessionError.responseBodyTooLarge`.
	func data(_ request: URLRequest, bodyLimit: Int?, bodyLogging: HTTPDebugLogger.BodyLogging) async throws -> Outcome {
		let onTaskCreation: (@concurrent @Sendable (URLSessionDataTask) async -> Void)? = nil
		let attempt = Attempt(sessionDescription: SplitURLSession.foregroundSessionDescription, bodyLimit: bodyLimit, bodyLogging: bodyLogging, urlLogging: .redacted, downloadHandler: nil, cancelsBeforeResume: false)
		return try await perform(metadataSession.dataTask(with: request), request: request, attempt: attempt, progress: nil, onTaskCreation: onTaskCreation)
	}

	/// - Parameter cancelsBeforeResume: Whether to cancel the task and throw `CancellationError` instead of resuming it if the calling task is cancelled by the time `onTaskCreation` returns.
	// swiftlint:disable:next function_parameter_count
	func download(_ request: URLRequest, route: DownloadRoute, handler: @escaping DownloadHandler, bodyLogging: HTTPDebugLogger.BodyLogging, urlLogging: HTTPDebugLogger.URLLogging, progress: Progress?, cancelsBeforeResume: Bool, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> Outcome {
		let (session, sessionDescription) = switch route {
		case .transfer:
			(transferSession, transferSessionDescription)
		case .metadata:
			(metadataSession, SplitURLSession.foregroundSessionDescription)
		}
		let attempt = Attempt(sessionDescription: sessionDescription, bodyLimit: nil, bodyLogging: bodyLogging, urlLogging: urlLogging, downloadHandler: handler, cancelsBeforeResume: cancelsBeforeResume)
		return try await perform(session.downloadTask(with: request), request: request, attempt: attempt, progress: progress, onTaskCreation: onTaskCreation)
	}

	// swiftlint:disable:next function_parameter_count
	func upload(_ request: URLRequest, fromFile fileURL: URL, bodyLimit: Int?, bodyLogging: HTTPDebugLogger.BodyLogging, urlLogging: HTTPDebugLogger.URLLogging, progress: Progress?, cancelsBeforeResume: Bool, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> Outcome {
		let attempt = Attempt(sessionDescription: transferSessionDescription, bodyLimit: bodyLimit, bodyLogging: bodyLogging, urlLogging: urlLogging, downloadHandler: nil, cancelsBeforeResume: cancelsBeforeResume)
		return try await perform(transferSession.uploadTask(with: request, fromFile: fileURL), request: request, attempt: attempt, progress: progress, onTaskCreation: onTaskCreation)
	}

	private func perform<SessionTask: URLSessionTask>(_ task: SessionTask, request: URLRequest, attempt: Attempt, progress: Progress?, onTaskCreation: (@concurrent @Sendable (SessionTask) async -> Void)?) async throws -> Outcome {
		HTTPDebugLogger.logRequest(request, session: attempt.sessionDescription, bodyLogging: attempt.bodyLogging, urlLogging: attempt.urlLogging)
		progress?.addChild(task.progress, withPendingUnitCount: 1)
		await onTaskCreation?(task)
		if attempt.cancelsBeforeResume, Task.isCancelled {
			task.cancel()
			throw CancellationError()
		}
		let delegate = SplitURLSessionDelegate.shared
		return try await withSDKContinuation { resumer in
			delegate.register(TaskRecord(resumer: resumer, challengeHandler: challengeHandler, hooks: hooks, bodyLimit: attempt.bodyLimit, bodyLogging: attempt.bodyLogging, urlLogging: attempt.urlLogging, downloadHandler: attempt.downloadHandler), for: task)
			if task.isTerminated {
				delegate.completeTask(task, error: task.error ?? URLError(.cancelled))
			} else {
				task.resume()
			}
		}
	}
}
