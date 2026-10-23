//
//  WebDAVClient.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 30.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

enum PropfindDepth: String, Sendable {
	case zero = "0"
	case one = "1"
}

/// `@unchecked Sendable`: `baseURL` and the `Sendable` `webDAVSession` are immutable. The class is subclassed in tests.
class WebDAVClient: @unchecked Sendable {
	let baseURL: URL
	private let webDAVSession: WebDAVSession

	init(credential: WebDAVCredential, session: WebDAVSession) {
		if credential.baseURL.absoluteString.hasSuffix("/") {
			self.baseURL = credential.baseURL
		} else {
			self.baseURL = credential.baseURL.appendingPathComponent("/")
		}
		self.webDAVSession = session
	}

	/// Creates a `WebDAVClient` with a foreground `URLSession`.
	convenience init(credential: WebDAVCredential) {
		self.init(credential: credential, session: WebDAVSession(credential: credential))
	}

	// MARK: - HTTP Methods for WebDAV

	func OPTIONS(url: URL) async throws -> (HTTPURLResponse, Data?) {
		var request = URLRequest(url: url)
		request.httpMethod = "OPTIONS"
		return try await webDAVSession.performDataTask(with: request)
	}

	func HEAD(url: URL) async throws -> (HTTPURLResponse, Data?) {
		var request = URLRequest(url: url)
		request.httpMethod = "HEAD"
		return try await webDAVSession.performDataTask(with: request)
	}

	func PROPFIND(url: URL, depth: PropfindDepth, to localURL: URL, propertyNames: [String]? = nil) async throws -> HTTPURLResponse {
		var request = URLRequest(url: url)
		request.httpMethod = "PROPFIND"
		request.setValue(depth.rawValue, forHTTPHeaderField: "Depth")
		request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
		request.httpBody = Data("""
		<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:">\(propfindPropElementsAsXML(with: propertyNames))</d:propfind>
		""".utf8)
		return try await webDAVSession.performMetadataDownloadTask(with: request, to: localURL)
	}

	func PROPFIND(url: URL, depth: PropfindDepth, propertyNames: [String]? = nil) async throws -> (HTTPURLResponse, Data?) {
		var request = URLRequest(url: url)
		request.httpMethod = "PROPFIND"
		request.setValue(depth.rawValue, forHTTPHeaderField: "Depth")
		request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
		request.httpBody = Data("""
		<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:">\(propfindPropElementsAsXML(with: propertyNames))</d:propfind>
		""".utf8)
		return try await webDAVSession.performDataTask(with: request)
	}

	func GET(from url: URL, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> HTTPURLResponse {
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		return try await webDAVSession.performDownloadTask(with: request, to: localURL, progress: progress, onTaskCreation: onTaskCreation)
	}

	func PUT(url: URL, fileURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> (HTTPURLResponse, Data?) {
		var request = URLRequest(url: url)
		request.httpMethod = "PUT"
		return try await webDAVSession.performUploadTask(with: request, fromFile: fileURL, progress: progress, onTaskCreation: onTaskCreation)
	}

	func MKCOL(url: URL) async throws -> (HTTPURLResponse, Data?) {
		var request = URLRequest(url: url)
		request.httpMethod = "MKCOL"
		return try await webDAVSession.performDataTask(with: request)
	}

	func DELETE(url: URL) async throws -> (HTTPURLResponse, Data?) {
		var request = URLRequest(url: url)
		request.httpMethod = "DELETE"
		return try await webDAVSession.performDataTask(with: request)
	}

	func MOVE(sourceURL: URL, destinationURL: URL) async throws -> (HTTPURLResponse, Data?) {
		var request = URLRequest(url: sourceURL)
		request.httpMethod = "MOVE"
		request.setValue(destinationURL.absoluteString, forHTTPHeaderField: "Destination")
		request.setValue("F", forHTTPHeaderField: "Overwrite")
		return try await webDAVSession.performDataTask(with: request)
	}

	// MARK: - Internal

	private func propfindPropElementsAsXML(with propertyNames: [String]?) -> String {
		if let propertyNames {
			return "<d:prop>\(propertyNames.map { "<d:\($0)/>" }.joined())</d:prop>"
		} else {
			return "<d:allprop/>"
		}
	}
}
