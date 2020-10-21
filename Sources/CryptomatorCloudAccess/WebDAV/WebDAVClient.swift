//
//  WebDAVClient.swift
//  CryptomatorCloudAccess
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

public class WebDAVClient {
	public let baseURL: URL
	private let webDAVSession: WebDAVSession

	init(credential: WebDAVCredential, session: WebDAVSession) {
		self.baseURL = credential.baseURL
		self.webDAVSession = session
	}

	public convenience init(credential: WebDAVCredential, sharedContainerIdentifier: String) {
		let urlSessionDelegate = WebDAVClientURLSessionDelegate(credential: credential)
		self.init(credential: credential, session: WebDAVSession(sharedContainerIdentifier: sharedContainerIdentifier, delegate: urlSessionDelegate))
	}

	// MARK: - HTTP Methods for WebDAV

	public func OPTIONS(url: URL) -> Promise<(HTTPURLResponse, Data?)> {
		var request = URLRequest(url: url)
		request.httpMethod = "OPTIONS"
		return webDAVSession.performDataTask(with: request)
	}

	public func HEAD(url: URL) -> Promise<(HTTPURLResponse, Data?)> {
		var request = URLRequest(url: url)
		request.httpMethod = "HEAD"
		return webDAVSession.performDataTask(with: request)
	}

	public func PROPFIND(url: URL, depth: PropfindDepth, propertyNames: [String]? = nil) -> Promise<(HTTPURLResponse, Data?)> {
		var request = URLRequest(url: url)
		request.httpMethod = "PROPFIND"
		request.setValue(depth.rawValue, forHTTPHeaderField: "Depth")
		request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
		request.httpBody = """
		<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:">\(propfindPropElementsAsXML(with: propertyNames))</d:propfind>
		""".data(using: .utf8)
		return webDAVSession.performDataTask(with: request)
	}

	public func GET(from url: URL, to localURL: URL) -> Promise<HTTPURLResponse> {
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		return webDAVSession.performDownloadTask(with: request, to: localURL)
	}

	public func PUT(url: URL, fileURL: URL) -> Promise<(HTTPURLResponse, Data?)> {
		var request = URLRequest(url: url)
		request.httpMethod = "PUT"
		return webDAVSession.performUploadTask(with: request, fromFile: fileURL)
	}

	public func MKCOL(url: URL) -> Promise<(HTTPURLResponse, Data?)> {
		var request = URLRequest(url: url)
		request.httpMethod = "MKCOL"
		return webDAVSession.performDataTask(with: request)
	}

	public func DELETE(url: URL) -> Promise<(HTTPURLResponse, Data?)> {
		var request = URLRequest(url: url)
		request.httpMethod = "DELETE"
		return webDAVSession.performDataTask(with: request)
	}

	public func MOVE(sourceURL: URL, destinationURL: URL) -> Promise<(HTTPURLResponse, Data?)> {
		var request = URLRequest(url: sourceURL)
		request.httpMethod = "MOVE"
		request.setValue(destinationURL.absoluteString, forHTTPHeaderField: "Destination")
		request.setValue("F", forHTTPHeaderField: "Overwrite")
		return webDAVSession.performDataTask(with: request)
	}

	// MARK: - Internal

	private func propfindPropElementsAsXML(with propertyNames: [String]?) -> String {
		if let propertyNames = propertyNames {
			return "<d:prop>\(propertyNames.map { "<d:\($0)/>" }.joined())</d:prop>"
		} else {
			return "<d:allprop/>"
		}
	}
}