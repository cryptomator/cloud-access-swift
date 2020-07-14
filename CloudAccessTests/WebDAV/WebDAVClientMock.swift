//
//  WebDAVClientMock.swift
//  CloudAccessTests
//
//  Created by Tobias Hagemann on 13.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises
@testable import CloudAccess

class URLSessionDataTaskMock: URLSessionDataTask {
	private let completionHandler: () -> Void

	init(completionHandler: @escaping () -> Void) {
		self.completionHandler = completionHandler
	}

	override func resume() {
		completionHandler()
	}
}

class URLSessionDownloadTaskMock: URLSessionDownloadTask {
	private let completionHandler: () -> Void

	init(completionHandler: @escaping () -> Void) {
		self.completionHandler = completionHandler
	}

	override func resume() {
		completionHandler()
	}
}

class URLSessionUploadTaskMock: URLSessionUploadTask {
	private let completionHandler: () -> Void

	init(completionHandler: @escaping () -> Void) {
		self.completionHandler = completionHandler
	}

	override func resume() {
		completionHandler()
	}
}

class URLSessionMock: URLSession {
	let tmpDirURL: URL

	var data: Data?
	var response: URLResponse?
	var error: Error?

	override init() {
		self.tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
		try? FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	override func dataTask(with request: URLRequest, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
		return URLSessionDataTaskMock {
			completionHandler(self.data, self.response, self.error)
		}
	}

	override func downloadTask(with request: URLRequest, completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void) -> URLSessionDownloadTask {
		return URLSessionDownloadTaskMock {
			let url = self.tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try? self.data?.write(to: url)
			completionHandler(url, self.response, self.error)
		}
	}

	override func uploadTask(with request: URLRequest, fromFile fileURL: URL, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionUploadTask {
		return URLSessionUploadTaskMock {
			completionHandler(self.data, self.response, self.error)
		}
	}
}

class WebDAVClientMock: WebDAVClient {
	var urlSession = URLSessionMock()

	var optionsRequests: [String] = []
	var headRequests: [String] = []
	var propfindRequests: [String: PropfindDepth] = [:]
	var getRequests: [String] = []
	var putRequests: [String] = []
	var mkcolRequests: [String] = []
	var deleteRequests: [String] = []
	var moveRequests: [String: String] = [:]

	init(baseURL: URL) {
		super.init(credential: WebDAVCredential(baseURL: baseURL, username: "", password: "", allowedCertificate: nil), urlSession: urlSession)
	}

	override func OPTIONS(url: URL) -> Promise<(HTTPURLResponse, Data?)> {
		optionsRequests.append(url.relativePath)
		return super.OPTIONS(url: url)
	}

	override func HEAD(url: URL) -> Promise<(HTTPURLResponse, Data?)> {
		headRequests.append(url.relativePath)
		return super.HEAD(url: url)
	}

	override func PROPFIND(url: URL, depth: PropfindDepth, propertyNames: [String]? = nil) -> Promise<(HTTPURLResponse, Data?)> {
		propfindRequests[url.relativePath] = depth
		return super.PROPFIND(url: url, depth: depth, propertyNames: propertyNames)
	}

	override func GET(url: URL) -> Promise<(HTTPURLResponse, URL?)> {
		getRequests.append(url.relativePath)
		return super.GET(url: url)
	}

	override func PUT(url: URL, fileURL: URL) -> Promise<(HTTPURLResponse, Data?)> {
		putRequests.append(url.relativePath)
		return super.PUT(url: url, fileURL: fileURL)
	}

	override func MKCOL(url: URL) -> Promise<(HTTPURLResponse, Data?)> {
		mkcolRequests.append(url.relativePath)
		return super.MKCOL(url: url)
	}

	override func DELETE(url: URL) -> Promise<(HTTPURLResponse, Data?)> {
		deleteRequests.append(url.relativePath)
		return super.DELETE(url: url)
	}

	override func MOVE(sourceURL: URL, destinationURL: URL) -> Promise<(HTTPURLResponse, Data?)> {
		moveRequests[sourceURL.relativePath] = destinationURL.relativePath
		return super.MOVE(sourceURL: sourceURL, destinationURL: destinationURL)
	}
}
