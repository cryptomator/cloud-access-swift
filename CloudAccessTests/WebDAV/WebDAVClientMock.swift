//
//  WebDAVClientMock.swift
//  CloudAccessTests
//
//  Created by Tobias Hagemann on 13.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
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
	var data: Data?
	var url: URL?
	var response: URLResponse?
	var error: Error?

	override func dataTask(with request: URLRequest, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
		return URLSessionDataTaskMock {
			completionHandler(self.data, self.response, self.error)
		}
	}

	override func downloadTask(with request: URLRequest, completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void) -> URLSessionDownloadTask {
		return URLSessionDownloadTaskMock {
			completionHandler(self.url, self.response, self.error)
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

	init() {
		super.init(credential: WebDAVCredential(baseURL: URL(string: "/")!, username: "", password: "", allowedCertificate: nil), urlSession: urlSession)
	}
}
