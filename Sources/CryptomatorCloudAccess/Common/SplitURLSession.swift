//
//  SplitURLSession.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 14.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os

private struct RunningTask {
	let resumer: Resumer<(HTTPURLResponse, Data)>
	let downloadDestinationURL: URL?
	var accumulatedData = Data()
	var isDownloadMoved = false
	var failure: Error?

	/// Moves the body of a 2xx download to its destination. Any other body becomes the response data instead, so that an error response never ends up at the destination.
	mutating func finishDownload(from location: URL, response: URLResponse?) {
		guard let downloadDestinationURL else {
			return
		}
		do {
			if let httpResponse = response as? HTTPURLResponse, (200 ... 299).contains(httpResponse.statusCode) {
				try? FileManager.default.removeItem(at: downloadDestinationURL)
				try FileManager.default.moveItem(at: location, to: downloadDestinationURL)
				isDownloadMoved = true
			} else {
				accumulatedData = try Data(contentsOf: location)
			}
		} catch {
			failure = error
		}
	}

	func complete(with response: URLResponse?, error: Error?) {
		if let httpResponse = response as? HTTPURLResponse {
			HTTPDebugLogger.logResponse(httpResponse, with: accumulatedData, or: isDownloadMoved ? downloadDestinationURL : nil)
		}
		if let failure {
			resumer.resume(throwing: failure)
		} else if let error {
			resumer.resume(throwing: error)
		} else if let httpResponse = response as? HTTPURLResponse {
			resumer.resume(returning: (httpResponse, accumulatedData))
		} else {
			resumer.resume(throwing: URLError(.badServerResponse))
		}
	}
}

private final class SplitURLSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, Sendable {
	private let runningTasks = OSAllocatedUnfairLock(initialState: [URLSessionTask: RunningTask]())

	func addRunningTask(key: URLSessionTask, value: RunningTask) {
		runningTasks.withLock {
			$0[key] = value
		}
	}

	// MARK: - URLSessionTaskDelegate

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
		let runningTask = runningTasks.withLock {
			$0.removeValue(forKey: task)
		}
		runningTask?.complete(with: task.response, error: error)
	}

	// MARK: - URLSessionDataDelegate

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		runningTasks.withLock {
			$0[dataTask]?.accumulatedData.append(data)
		}
	}

	// MARK: - URLSessionDownloadDelegate

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		let response = downloadTask.response
		runningTasks.withLock {
			$0[downloadTask]?.finishDownload(from: location, response: response)
		}
	}
}

/**
 `URLSession` wrapper that also works with a background configuration.

 Downloads and uploads run on a session with the given configuration, as download and upload tasks. Uploads are sent from a file, which is the only kind of upload a background session supports. Other requests run as data tasks on a foreground session, because a background session doesn't support them.

 Task cancellation is not forwarded to a request, so a request returns only after its `URLSessionTask` has terminated. Every response is returned, whatever its status code.
 */
final class SplitURLSession: Sendable {
	private let transferSession: URLSession
	private let metadataSession: URLSession
	private let delegate: SplitURLSessionDelegate

	init(configuration: URLSessionConfiguration) {
		let delegate = SplitURLSessionDelegate()
		self.delegate = delegate
		self.transferSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
		if configuration.identifier != nil {
			self.metadataSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
		} else {
			self.metadataSession = transferSession
		}
	}

	deinit {
		transferSession.invalidateAndCancel()
		if metadataSession !== transferSession {
			metadataSession.invalidateAndCancel()
		}
	}

	func data(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
		return try await perform(metadataSession.dataTask(with: request), request: request, downloadDestinationURL: nil)
	}

	/// Moves the body of a 2xx response to `destinationURL`, replacing any item there. Any other body is returned as data instead.
	func download(_ request: URLRequest, to destinationURL: URL) async throws -> (HTTPURLResponse, Data) {
		return try await perform(transferSession.downloadTask(with: request), request: request, downloadDestinationURL: destinationURL)
	}

	func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (HTTPURLResponse, Data) {
		return try await perform(transferSession.uploadTask(with: request, fromFile: fileURL), request: request, downloadDestinationURL: nil)
	}

	private func perform(_ task: URLSessionTask, request: URLRequest, downloadDestinationURL: URL?) async throws -> (HTTPURLResponse, Data) {
		HTTPDebugLogger.logRequest(request)
		return try await withSDKContinuation { resumer in
			delegate.addRunningTask(key: task, value: RunningTask(resumer: resumer, downloadDestinationURL: downloadDestinationURL))
			task.resume()
		}
	}
}
