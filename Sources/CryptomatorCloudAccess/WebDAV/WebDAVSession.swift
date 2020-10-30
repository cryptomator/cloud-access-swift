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
	lazy var accumulatedData: Data = {
		return Data()
	}()

	init(promise: Promise<(HTTPURLResponse, Data?)>) {
		self.promise = promise
	}

	func fulfillPromise(with response: HTTPURLResponse) {
		promise.fulfill((response, accumulatedData))
	}
}

class WebDAVClientURLSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, URLSessionDownloadDelegate {
	fileprivate let credential: WebDAVCredential
	fileprivate var runningDataTasks = [URLSessionDataTask: WebDAVDataTask]()
	fileprivate var runningDownloadTasks = [URLSessionDownloadTask: WebDAVDownloadTask]()

	init(credential: WebDAVCredential) {
		self.credential = credential
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
				let runningDataTask = runningDataTasks.removeValue(forKey: dataTask)
				runningDataTask?.promise.reject(URLSessionError.httpError(nil, statusCode: 401))
			case let downloadTask as URLSessionDownloadTask:
				let runningDownloadTaskPromise = runningDownloadTasks.removeValue(forKey: downloadTask)
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
			let runningDataTask = runningDataTasks.removeValue(forKey: dataTask)
			guard (200 ... 299).contains(httpResponse.statusCode) else {
				runningDataTask?.promise.reject(URLSessionError.httpError(nil, statusCode: httpResponse.statusCode))
				return
			}
			runningDataTask?.fulfillPromise(with: httpResponse)
		case let (dataTask as URLSessionDataTask, httpResponse as HTTPURLResponse, .some(error)):
			let runningDataTask = runningDataTasks.removeValue(forKey: dataTask)
			runningDataTask?.promise.reject(URLSessionError.httpError(error, statusCode: httpResponse.statusCode))
		case let (dataTask as URLSessionDataTask, _, .some(error)):
			let runningDataTask = runningDataTasks.removeValue(forKey: dataTask)
			runningDataTask?.promise.reject(error)
		case let (downloadTask as URLSessionDownloadTask, httpResponse as HTTPURLResponse, .some(error)):
			let runningDownloadTaskPromise = runningDownloadTasks.removeValue(forKey: downloadTask)
			runningDownloadTaskPromise?.promise.reject(URLSessionError.httpError(error, statusCode: httpResponse.statusCode))
		case let (downloadTask as URLSessionDownloadTask, _, .some(error)):
			let runningDownloadTaskPromise = runningDownloadTasks.removeValue(forKey: downloadTask)
			runningDownloadTaskPromise?.promise.reject(error)
		default:
			return
		}
	}

	// MARK: - URLSessionDataDelegate

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		let runningDataTask = runningDataTasks[dataTask]
		runningDataTask?.accumulatedData.append(data)
	}

	// MARK: - URLSessionDownloadDelegate

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		guard let runningDownloadTask = runningDownloadTasks.removeValue(forKey: downloadTask) else {
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
}

class WebDAVSession {
	private let delegate: WebDAVClientURLSessionDelegate
	private let urlSession: URLSession

	init(urlSession: URLSession, delegate: WebDAVClientURLSessionDelegate) {
		precondition(urlSession.delegate as? WebDAVClientURLSessionDelegate == delegate)
		self.urlSession = urlSession
		self.delegate = delegate
	}

	convenience init(sharedContainerIdentifier: String, delegate: WebDAVClientURLSessionDelegate) {
		let configuration = URLSessionConfiguration.background(withIdentifier: "CloudAccessWebDAVSession_\(delegate.credential.identifier)")
		configuration.sharedContainerIdentifier = sharedContainerIdentifier
		configuration.httpCookieStorage = HTTPCookieStorage()
		let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
		self.init(urlSession: session, delegate: delegate)
	}

	func performDataTask(with request: URLRequest) -> Promise<(HTTPURLResponse, Data?)> {
		let task = urlSession.dataTask(with: request)
		let pendingPromise = Promise<(HTTPURLResponse, Data?)>.pending()
		let webDAVDataTask = WebDAVDataTask(promise: pendingPromise)
		delegate.runningDataTasks[task] = webDAVDataTask
		task.resume()
		return pendingPromise
	}

	func performDownloadTask(with request: URLRequest, to localURL: URL) -> Promise<HTTPURLResponse> {
		let progress = Progress(totalUnitCount: 1)
		let task = urlSession.downloadTask(with: request)

		if #available(iOS 11.0, macOS 10.13, *) {
			progress.addChild(task.progress, withPendingUnitCount: 1)
		}

		let pendingPromise = Promise<HTTPURLResponse>.pending()
		let webDAVDownloadTask = WebDAVDownloadTask(promise: pendingPromise, localURL: localURL)
		delegate.runningDownloadTasks[task] = webDAVDownloadTask
		task.resume()
		return pendingPromise
	}

	func performUploadTask(with request: URLRequest, fromFile fileURL: URL) -> Promise<(HTTPURLResponse, Data?)> {
		let progress = Progress(totalUnitCount: 1)
		let task = urlSession.uploadTask(with: request, fromFile: fileURL)

		if #available(iOS 11.0, macOS 10.13, *) {
			progress.addChild(task.progress, withPendingUnitCount: 1)
		}

		let pendingPromise = Promise<(HTTPURLResponse, Data?)>.pending()
		let webDAVDataTask = WebDAVDataTask(promise: pendingPromise)
		delegate.runningDataTasks[task] = webDAVDataTask
		task.resume()
		return pendingPromise
	}
}
