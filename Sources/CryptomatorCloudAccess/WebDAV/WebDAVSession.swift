//
//  WebDAVSession.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 07.10.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum URLSessionError: Error {
	case httpError(_ error: Error?, statusCode: Int)
	case unexpectedResponse
}

private struct WebDAVDataTask {
	let resumer: Resumer<(HTTPURLResponse, Data?)>
	var accumulatedData = Data()
	var failure: Error?

	func complete(with response: URLResponse?, error: Error?) {
		if let httpResponse = response as? HTTPURLResponse {
			HTTPDebugLogger.logResponse(httpResponse, with: accumulatedData, or: nil)
		}
		do {
			try resumer.resume(returning: (successfulResponse(response, error: error, failure: failure), accumulatedData))
		} catch {
			resumer.resume(throwing: error)
		}
	}
}

private struct WebDAVDownloadTask {
	let resumer: Resumer<HTTPURLResponse>
	let localURL: URL
	var isDownloadMoved = false
	var failure: Error?

	mutating func moveDownload(from location: URL) {
		do {
			try FileManager.default.moveItem(at: location, to: localURL)
			isDownloadMoved = true
		} catch {
			failure = error
		}
	}

	func complete(with response: URLResponse?, error: Error?) {
		if let httpResponse = response as? HTTPURLResponse {
			HTTPDebugLogger.logResponse(httpResponse, with: nil, or: localURL)
		}
		do {
			let httpResponse = try successfulResponse(response, error: error, failure: failure)
			guard isDownloadMoved else {
				throw URLSessionError.unexpectedResponse
			}
			resumer.resume(returning: httpResponse)
		} catch {
			resumer.resume(throwing: error)
		}
	}
}

/// Returns the response of a terminated task if it succeeded. A failure that was recorded while the task was running takes precedence over the error that the task terminated with.
private func successfulResponse(_ response: URLResponse?, error: Error?, failure: Error?) throws -> HTTPURLResponse {
	if let failure {
		throw failure
	}
	switch (response, error) {
	case let (_, .some(error)) where isCancellationError(error):
		throw CancellationError()
	case let (httpResponse as HTTPURLResponse, .some(error)):
		throw URLSessionError.httpError(error, statusCode: httpResponse.statusCode)
	case let (_, .some(error)):
		throw error
	case let (httpResponse as HTTPURLResponse, nil):
		guard (200 ... 299).contains(httpResponse.statusCode) else {
			throw URLSessionError.httpError(nil, statusCode: httpResponse.statusCode)
		}
		return httpResponse
	default:
		throw URLSessionError.unexpectedResponse
	}
}

private extension URLSessionTask {
	/// Whether the task was cancelled or completed before the session resumed it, i.e., while `onTaskCreation` ran. Its terminal delegate call may have found nothing registered then.
	var isTerminated: Bool {
		return state == .canceling || state == .completed || error != nil
	}
}

/// `@unchecked Sendable`: `runningDataTasks` and `runningDownloadTasks` are only accessed on `queue`, everything else is immutable. The class is subclassed in tests.
class WebDAVClientURLSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
	private let queue: DispatchQueue
	fileprivate let credential: WebDAVCredential
	private var runningDataTasks = [URLSessionDataTask: WebDAVDataTask]()
	private var runningDownloadTasks = [URLSessionDownloadTask: WebDAVDownloadTask]()

	init(credential: WebDAVCredential) {
		self.credential = credential
		self.queue = DispatchQueue(label: "WebDAVClientURLSessionDelegate_\(credential.identifier)")
	}

	// MARK: - URLSessionDelegate

	func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		if challenge.previousFailureCount < 1 {
			if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust, allowedCertificateMatchesActualCertificate(in: trust) {
				completionHandler(.useCredential, URLCredential(trust: trust))
			} else {
				completionHandler(.performDefaultHandling, nil)
			}
		} else {
			completionHandler(.cancelAuthenticationChallenge, nil)
		}
	}

	// MARK: - URLSessionTaskDelegate

	func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		if challenge.previousFailureCount < 1 {
			completionHandler(.useCredential, URLCredential(user: credential.username, password: credential.password, persistence: .forSession))
		} else {
			// The task terminates with a cancellation error after this, which must not replace the actual failure.
			recordFailure(URLSessionError.httpError(nil, statusCode: 401), for: task)
			completionHandler(.cancelAuthenticationChallenge, nil)
		}
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		switch task {
		case let dataTask as URLSessionDataTask:
			removeRunningDataTask(forKey: dataTask)?.complete(with: task.response, error: error)
		case let downloadTask as URLSessionDownloadTask:
			removeRunningDownloadTask(forKey: downloadTask)?.complete(with: task.response, error: error)
		default:
			break
		}
	}

	// MARK: - URLSessionDataDelegate

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		queue.sync {
			runningDataTasks[dataTask]?.accumulatedData.append(data)
		}
	}

	// MARK: - URLSessionDownloadDelegate

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		guard let response = downloadTask.response as? HTTPURLResponse, (200 ... 299).contains(response.statusCode) else {
			return
		}
		queue.sync {
			runningDownloadTasks[downloadTask]?.moveDownload(from: location)
		}
	}

	// MARK: - Internal

	private func allowedCertificateMatchesActualCertificate(in trust: SecTrust) -> Bool {
		guard let allowedCertificate = credential.allowedCertificate, SecTrustGetCertificateCount(trust) > 0, let actualCertificate = SecTrustGetCertificateAtIndex(trust, 0) else {
			return false
		}
		return allowedCertificate == SecCertificateCopyData(actualCertificate) as Data
	}

	// MARK: - Synchronized Access to the Dictionaries

	fileprivate func addRunningDataTask(key: URLSessionDataTask, value: WebDAVDataTask) {
		queue.sync {
			runningDataTasks[key] = value
		}
	}

	fileprivate func removeRunningDataTask(forKey key: URLSessionDataTask) -> WebDAVDataTask? {
		return queue.sync {
			runningDataTasks.removeValue(forKey: key)
		}
	}

	fileprivate func addRunningDownloadTask(key: URLSessionDownloadTask, value: WebDAVDownloadTask) {
		queue.sync {
			runningDownloadTasks[key] = value
		}
	}

	fileprivate func removeRunningDownloadTask(forKey key: URLSessionDownloadTask) -> WebDAVDownloadTask? {
		return queue.sync {
			runningDownloadTasks.removeValue(forKey: key)
		}
	}

	private func recordFailure(_ failure: Error, for task: URLSessionTask) {
		queue.sync {
			switch task {
			case let dataTask as URLSessionDataTask:
				runningDataTasks[dataTask]?.failure = failure
			case let downloadTask as URLSessionDownloadTask:
				runningDownloadTasks[downloadTask]?.failure = failure
			default:
				break
			}
		}
	}
}

final class WebDAVSession: Sendable {
	private let urlSession: URLSession
	private let delegate: WebDAVClientURLSessionDelegate

	init(urlSession: URLSession, delegate: WebDAVClientURLSessionDelegate) {
		precondition(urlSession.delegate as? WebDAVClientURLSessionDelegate == delegate)
		self.urlSession = urlSession
		self.delegate = delegate
	}

	/**
	 Use this method to conveniently create a WebDAV session with a background URL session.

	 If the `WebDAVSession` is used in an app extension, set the `sharedContainerIdentifier` to a valid identifier for a container that will be shared between the app and the extension.

	 To avoid collisions in the `URLSession` Identifier between multiple targets (e.g. main app and app extension), the `BundleID` is used in addition to the Credential UID.
	 */
	static func createBackgroundSession(with delegate: WebDAVClientURLSessionDelegate, sessionIdentifier: String, sharedContainerIdentifier: String? = nil) -> WebDAVSession {
		let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
		configuration.sharedContainerIdentifier = sharedContainerIdentifier
		configuration.httpCookieStorage = HTTPCookieStorage()
		configuration.urlCredentialStorage = nil
		let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
		return WebDAVSession(urlSession: session, delegate: delegate)
	}

	convenience init(delegate: WebDAVClientURLSessionDelegate) {
		let configuration = URLSessionConfiguration.default
		configuration.httpCookieStorage = HTTPCookieStorage()
		configuration.urlCredentialStorage = nil
		let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
		self.init(urlSession: session, delegate: delegate)
	}

	deinit {
		urlSession.invalidateAndCancel()
	}

	func performDataTask(with request: URLRequest) async throws -> (HTTPURLResponse, Data?) {
		HTTPDebugLogger.logRequest(request)
		let task = urlSession.dataTask(with: request)
		return try await withSDKContinuation { resumer in
			delegate.addRunningDataTask(key: task, value: WebDAVDataTask(resumer: resumer))
			task.resume()
		}
	}

	func performDownloadTask(with request: URLRequest, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> HTTPURLResponse {
		HTTPDebugLogger.logRequest(request)
		let task = urlSession.downloadTask(with: request)
		progress?.addChild(task.progress, withPendingUnitCount: 1)
		await onTaskCreation?(task)
		guard !Task.isCancelled else {
			task.cancel()
			throw CancellationError()
		}
		return try await withSDKContinuation { resumer in
			delegate.addRunningDownloadTask(key: task, value: WebDAVDownloadTask(resumer: resumer, localURL: localURL))
			if task.isTerminated {
				delegate.removeRunningDownloadTask(forKey: task)?.complete(with: task.response, error: task.error ?? URLError(.cancelled))
			} else {
				task.resume()
			}
		}
	}

	func performUploadTask(with request: URLRequest, fromFile fileURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> (HTTPURLResponse, Data?) {
		HTTPDebugLogger.logRequest(request)
		let task = urlSession.uploadTask(with: request, fromFile: fileURL)
		progress?.addChild(task.progress, withPendingUnitCount: 1)
		await onTaskCreation?(task)
		guard !Task.isCancelled else {
			task.cancel()
			throw CancellationError()
		}
		return try await withSDKContinuation { resumer in
			delegate.addRunningDataTask(key: task, value: WebDAVDataTask(resumer: resumer))
			if task.isTerminated {
				delegate.removeRunningDataTask(forKey: task)?.complete(with: task.response, error: task.error ?? URLError(.cancelled))
			} else {
				task.resume()
			}
		}
	}
}
