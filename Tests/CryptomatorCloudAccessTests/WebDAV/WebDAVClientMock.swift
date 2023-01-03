//
//  WebDAVClientMock.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class WebDAVClientMock: WebDAVClient {
	var optionsRequests: [String] = []
	var headRequests: [String] = []
	var propfindRequests: [String: PropfindDepth] = [:]
	var getRequests: [String] = []
	var putRequests: [String] = []
	var mkcolRequests: [String] = []
	var deleteRequests: [String] = []
	var moveRequests: [String: String] = [:]

	init(baseURL: URL, urlProtocolMock: AnyClass) {
		let credential = WebDAVCredential(baseURL: baseURL, username: "", password: "", allowedCertificate: nil)
		let delegate = WebDAVClientURLSessionDelegate(credential: credential)
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [urlProtocolMock]
		let urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
		super.init(credential: credential, session: WebDAVSession(urlSession: urlSession, delegate: delegate))
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

	override func PROPFIND(url: URL, depth: PropfindDepth, to localURL: URL, propertyNames: [String]? = nil) -> Promise<HTTPURLResponse> {
		propfindRequests[url.relativePath] = depth
		return super.PROPFIND(url: url, depth: depth, to: localURL, propertyNames: propertyNames)
	}

	override func GET(from url: URL, to localURL: URL, onTaskCreation: ((URLSessionDownloadTask?) -> Void)?) -> Promise<HTTPURLResponse> {
		getRequests.append(url.relativePath)
		return super.GET(from: url, to: localURL, onTaskCreation: onTaskCreation)
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
