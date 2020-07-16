//
//  WebDAVClient.swift
//  CloudAccess
//
//  Created by Tobias Hagemann on 30.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

public enum PropfindDepth: String {
	case zero = "0"
	case one = "1"
}

internal class WebDAVClientURLSessionDelegate: NSObject, URLSessionTaskDelegate {
	let credential: WebDAVCredential

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
			completionHandler(.cancelAuthenticationChallenge, nil)
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

public class WebDAVClient {
	public let baseURL: URL
	private let urlSession: URLSession

	init(credential: WebDAVCredential, urlSession: URLSession) {
		self.baseURL = credential.baseURL
		self.urlSession = urlSession
	}

	public convenience init(credential: WebDAVCredential, sharedContainerIdentifier: String) {
		let urlSessionDelegate = WebDAVClientURLSessionDelegate(credential: credential)
		self.init(credential: credential, urlSession: WebDAVClient.createURLSession(sharedContainerIdentifier: sharedContainerIdentifier, delegate: urlSessionDelegate))
	}

	private static func createURLSession(sharedContainerIdentifier: String, delegate: URLSessionDelegate) -> URLSession {
		let configuration = URLSessionConfiguration.background(withIdentifier: "CloudAccessWebDAVClient_\(UUID().uuidString)")
		configuration.sharedContainerIdentifier = sharedContainerIdentifier
		configuration.httpCookieStorage = HTTPCookieStorage()
		return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
	}

	// MARK: - HTTP Methods for WebDAV

	public func OPTIONS(url: URL) -> Promise<(HTTPURLResponse, Data?)> {
		var request = URLRequest(url: url)
		request.httpMethod = "OPTIONS"
		return urlSession.performDataTask(with: request)
	}

	public func HEAD(url: URL) -> Promise<(HTTPURLResponse, Data?)> {
		var request = URLRequest(url: url)
		request.httpMethod = "HEAD"
		return urlSession.performDataTask(with: request)
	}

	public func PROPFIND(url: URL, depth: PropfindDepth, propertyNames: [String]? = nil) -> Promise<(HTTPURLResponse, Data?)> {
		var request = URLRequest(url: url)
		request.httpMethod = "PROPFIND"
		request.setValue(depth.rawValue, forHTTPHeaderField: "Depth")
		request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
		request.httpBody = """
		<?xml version="1.0" encoding="utf-8"?><D:propfind xmlns:D="DAV:">\(propfindPropElementsAsXML(with: propertyNames))</D:propfind>
		""".data(using: .utf8)
		return urlSession.performDataTask(with: request)
	}

	public func GET(url: URL) -> Promise<(HTTPURLResponse, URL?)> {
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		return urlSession.performDownloadTask(with: request)
	}

	public func PUT(url: URL, fileURL: URL) -> Promise<(HTTPURLResponse, Data?)> {
		var request = URLRequest(url: url)
		request.httpMethod = "PUT"
		return urlSession.performUploadTask(with: request, fromFile: fileURL)
	}

	public func MKCOL(url: URL) -> Promise<(HTTPURLResponse, Data?)> {
		var request = URLRequest(url: url)
		request.httpMethod = "MKCOL"
		return urlSession.performDataTask(with: request)
	}

	public func DELETE(url: URL) -> Promise<(HTTPURLResponse, Data?)> {
		var request = URLRequest(url: url)
		request.httpMethod = "DELETE"
		return urlSession.performDataTask(with: request)
	}

	public func MOVE(sourceURL: URL, destinationURL: URL) -> Promise<(HTTPURLResponse, Data?)> {
		var request = URLRequest(url: sourceURL)
		request.httpMethod = "MOVE"
		request.setValue("Destination", forHTTPHeaderField: destinationURL.absoluteString)
		request.setValue("Overwrite", forHTTPHeaderField: "F")
		return urlSession.performDataTask(with: request)
	}

	// MARK: - Internal

	private func propfindPropElementsAsXML(with propertyNames: [String]?) -> String {
		if let propertyNames = propertyNames {
			return "<D:prop>\(propertyNames.map { "<\($0)/>" }.joined())</D:prop>"
		} else {
			return "<D:allprop/>"
		}
	}
}
