//
//  WebDAVClientMock.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

/// `@unchecked Sendable`: restates the conformance of `WebDAVClient`; the recorded requests are protected by `requests`.
class WebDAVClientMock: WebDAVClient, @unchecked Sendable {
	private struct Requests {
		var options: [String] = []
		var head: [String] = []
		var propfind: [String: PropfindDepth] = [:]
		var get: [String] = []
		var put: [String] = []
		var mkcol: [String] = []
		var delete: [String] = []
		var move: [String: String] = [:]
	}

	private let requests = OSAllocatedUnfairLock(initialState: Requests())

	var optionsRequests: [String] {
		requests.withLock { $0.options }
	}

	var headRequests: [String] {
		requests.withLock { $0.head }
	}

	var propfindRequests: [String: PropfindDepth] {
		requests.withLock { $0.propfind }
	}

	var getRequests: [String] {
		requests.withLock { $0.get }
	}

	var putRequests: [String] {
		requests.withLock { $0.put }
	}

	var mkcolRequests: [String] {
		requests.withLock { $0.mkcol }
	}

	var deleteRequests: [String] {
		requests.withLock { $0.delete }
	}

	var moveRequests: [String: String] {
		requests.withLock { $0.move }
	}

	init(baseURL: URL, urlProtocolMock: AnyClass) {
		let credential = WebDAVCredential(baseURL: baseURL, username: "", password: "", allowedCertificate: nil)
		let delegate = WebDAVClientURLSessionDelegate(credential: credential)
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [urlProtocolMock]
		let urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
		super.init(credential: credential, session: WebDAVSession(urlSession: urlSession, delegate: delegate))
	}

	override func OPTIONS(url: URL) async throws -> (HTTPURLResponse, Data?) {
		requests.withLock { $0.options.append(url.relativePath) }
		return try await super.OPTIONS(url: url)
	}

	override func HEAD(url: URL) async throws -> (HTTPURLResponse, Data?) {
		requests.withLock { $0.head.append(url.relativePath) }
		return try await super.HEAD(url: url)
	}

	override func PROPFIND(url: URL, depth: PropfindDepth, propertyNames: [String]? = nil) async throws -> (HTTPURLResponse, Data?) {
		requests.withLock { $0.propfind[url.relativePath] = depth }
		return try await super.PROPFIND(url: url, depth: depth, propertyNames: propertyNames)
	}

	override func PROPFIND(url: URL, depth: PropfindDepth, to localURL: URL, propertyNames: [String]? = nil) async throws -> HTTPURLResponse {
		requests.withLock { $0.propfind[url.relativePath] = depth }
		return try await super.PROPFIND(url: url, depth: depth, to: localURL, propertyNames: propertyNames)
	}

	override func GET(from url: URL, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> HTTPURLResponse {
		requests.withLock { $0.get.append(url.relativePath) }
		return try await super.GET(from: url, to: localURL, progress: progress, onTaskCreation: onTaskCreation)
	}

	override func PUT(url: URL, fileURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> (HTTPURLResponse, Data?) {
		requests.withLock { $0.put.append(url.relativePath) }
		return try await super.PUT(url: url, fileURL: fileURL, progress: progress, onTaskCreation: onTaskCreation)
	}

	override func MKCOL(url: URL) async throws -> (HTTPURLResponse, Data?) {
		requests.withLock { $0.mkcol.append(url.relativePath) }
		return try await super.MKCOL(url: url)
	}

	override func DELETE(url: URL) async throws -> (HTTPURLResponse, Data?) {
		requests.withLock { $0.delete.append(url.relativePath) }
		return try await super.DELETE(url: url)
	}

	override func MOVE(sourceURL: URL, destinationURL: URL) async throws -> (HTTPURLResponse, Data?) {
		requests.withLock { $0.move[sourceURL.relativePath] = destinationURL.relativePath }
		return try await super.MOVE(sourceURL: sourceURL, destinationURL: destinationURL)
	}
}
