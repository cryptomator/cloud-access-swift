//
//  WebDAVSession.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 07.10.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

private struct WebDAVDownloadTask {
	let promise: Promise<HTTPURLResponse>
	let localURL: URL
}

private class WebDAVDataTask {
	let promise: Promise<(HTTPURLResponse, Data?)>
	lazy var accumulatedData: Data = .init()

	init(promise: Promise<(HTTPURLResponse, Data?)>) {
		self.promise = promise
	}

	func fulfillPromise(with response: HTTPURLResponse) {
		promise.fulfill((response, accumulatedData))
	}
}

class WebDAVClientURLSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, URLSessionDownloadDelegate {
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
			switch task {
			case let dataTask as URLSessionDataTask:
				let runningDataTask = removeRunningDataTask(forKey: dataTask)
				runningDataTask?.promise.reject(URLSessionError.httpError(nil, statusCode: 401))
			case let downloadTask as URLSessionDownloadTask:
				let runningDownloadTaskPromise = removeRunningDownloadTask(forKey: downloadTask)
				runningDownloadTaskPromise?.promise.reject(URLSessionError.httpError(nil, statusCode: 401))
			default:
				break
			}
			completionHandler(.cancelAuthenticationChallenge, nil)
		}
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		switch (task, task.response, error) {
		case let (dataTask as URLSessionDataTask, httpResponse as HTTPURLResponse, nil):
			let runningDataTask = removeRunningDataTask(forKey: dataTask)
			guard (200 ... 299).contains(httpResponse.statusCode) else {
				runningDataTask?.promise.reject(URLSessionError.httpError(nil, statusCode: httpResponse.statusCode))
				return
			}
			runningDataTask?.fulfillPromise(with: httpResponse)
		case let (dataTask as URLSessionDataTask, httpResponse as HTTPURLResponse, .some(error)):
			let runningDataTask = removeRunningDataTask(forKey: dataTask)
			runningDataTask?.promise.reject(URLSessionError.httpError(error, statusCode: httpResponse.statusCode))
		case let (dataTask as URLSessionDataTask, _, .some(error)):
			let runningDataTask = removeRunningDataTask(forKey: dataTask)
			runningDataTask?.promise.reject(error)
		case let (downloadTask as URLSessionDownloadTask, httpResponse as HTTPURLResponse, .some(error)):
			let runningDownloadTaskPromise = removeRunningDownloadTask(forKey: downloadTask)
			runningDownloadTaskPromise?.promise.reject(URLSessionError.httpError(error, statusCode: httpResponse.statusCode))
		case let (downloadTask as URLSessionDownloadTask, _, .some(error)):
			let runningDownloadTaskPromise = removeRunningDownloadTask(forKey: downloadTask)
			runningDownloadTaskPromise?.promise.reject(error)
		default:
			return
		}
	}

	// MARK: - URLSessionDataDelegate

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		queue.sync {
			let runningDataTask = runningDataTasks[dataTask]
			runningDataTask?.accumulatedData.append(data)
		}
	}

	// MARK: - URLSessionDownloadDelegate

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		guard let runningDownloadTask = removeRunningDownloadTask(forKey: downloadTask) else {
			return
		}
		if let response = downloadTask.response as? HTTPURLResponse {
			guard (200 ... 299).contains(response.statusCode) else {
				runningDownloadTask.promise.reject(URLSessionError.httpError(nil, statusCode: response.statusCode))
				return
			}
			do {
				try FileManager.default.moveItem(at: location, to: runningDownloadTask.localURL)
				runningDownloadTask.promise.fulfill(response)
			} catch {
				runningDownloadTask.promise.reject(error)
			}
		} else {
			runningDownloadTask.promise.reject(URLSessionError.unexpectedResponse)
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

	private func removeRunningDataTask(forKey key: URLSessionDataTask) -> WebDAVDataTask? {
		return queue.sync {
			runningDataTasks.removeValue(forKey: key)
		}
	}

	fileprivate func addRunningDownloadTask(key: URLSessionDownloadTask, value: WebDAVDownloadTask) {
		queue.sync {
			runningDownloadTasks[key] = value
		}
	}

	private func removeRunningDownloadTask(forKey key: URLSessionDownloadTask) -> WebDAVDownloadTask? {
		return queue.sync {
			runningDownloadTasks.removeValue(forKey: key)
		}
	}
}

class WebDAVSession {
	private let urlSession: URLSession
	private weak var delegate: WebDAVClientURLSessionDelegate?

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
	static func createBackgroundSession(with delegate: WebDAVClientURLSessionDelegate, sharedContainerIdentifier: String? = nil) -> WebDAVSession {
		let bundleId = Bundle.main.bundleIdentifier ?? ""
		let configuration = URLSessionConfiguration.background(withIdentifier: "CloudAccessWebDAVSession_\(delegate.credential.identifier)_\(bundleId)")
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

	func performDataTask(with request: URLRequest) -> Promise<(HTTPURLResponse, Data?)> {
		HTTPDebugLogger.logRequest(request)
		let task = urlSession.dataTask(with: request)
		let pendingPromise = Promise<(HTTPURLResponse, Data?)>.pending()
		let webDAVDataTask = WebDAVDataTask(promise: pendingPromise)
		delegate?.addRunningDataTask(key: task, value: webDAVDataTask)
		task.resume()
		return pendingPromise.then { response, data -> Promise<(HTTPURLResponse, Data?)> in
			HTTPDebugLogger.logResponse(response, with: data, or: nil)
			return Promise((response, data))
		}
	}

	func performDownloadTask(with request: URLRequest, to localURL: URL, onTaskCreation: ((URLSessionDownloadTask?) -> Void)?) -> Promise<HTTPURLResponse> {
		HTTPDebugLogger.logRequest(request)
		let progress = Progress(totalUnitCount: 1)
		let task = urlSession.downloadTask(with: request)
		onTaskCreation?(task)
		progress.addChild(task.progress, withPendingUnitCount: 1)
		let pendingPromise = Promise<HTTPURLResponse>.pending()
		let webDAVDownloadTask = WebDAVDownloadTask(promise: pendingPromise, localURL: localURL)
		delegate?.addRunningDownloadTask(key: task, value: webDAVDownloadTask)
		task.resume()
		return pendingPromise.then { response -> Promise<HTTPURLResponse> in
			HTTPDebugLogger.logResponse(response, with: nil, or: localURL)
			return Promise(response)
		}
	}

	func performUploadTask(with request: URLRequest, fromFile fileURL: URL) -> Promise<(HTTPURLResponse, Data?)> {
		HTTPDebugLogger.logRequest(request)
		let progress = Progress(totalUnitCount: 1)
		let task = urlSession.uploadTask(with: request, fromFile: fileURL)
		progress.addChild(task.progress, withPendingUnitCount: 1)
		let pendingPromise = Promise<(HTTPURLResponse, Data?)>.pending()
		let webDAVDataTask = WebDAVDataTask(promise: pendingPromise)
		delegate?.addRunningDataTask(key: task, value: webDAVDataTask)
		task.resume()
		return pendingPromise.then { response, data -> Promise<(HTTPURLResponse, Data?)> in
			HTTPDebugLogger.logResponse(response, with: data, or: nil)
			return Promise((response, data))
		}
	}
}
