//
//  HTTPDebugLogger.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 15.11.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation

enum HTTPDebugLogger {
	// MARK: - URLRequest

	private enum RequestBodyType {
		case none
		case empty
		case plaintext
		case binary
	}

	static func logRequest(_ request: URLRequest) {
		CloudAccessDDLogDebug("")
		CloudAccessDDLogDebug("--> \(String(describing: request.httpMethod)) \(String(describing: request.url)) HTTP/1.1")
		if let headerFields = request.allHTTPHeaderFields {
			headerFields.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
				.filter { !isExcludedHeader($0.key) }
				.forEach { CloudAccessDDLogDebug("\($0.key): \($0.value)") }
		}
		let bodyType = logRequestBody(request)
		switch bodyType {
		case .none:
			CloudAccessDDLogDebug("--> END \(String(describing: request.httpMethod))")
		case .empty:
			CloudAccessDDLogDebug("--> END \(String(describing: request.httpMethod)) (empty body)")
		case .plaintext:
			CloudAccessDDLogDebug("--> END \(String(describing: request.httpMethod)) (\(String(describing: request.httpBody?.count))-byte body)")
		case .binary:
			CloudAccessDDLogDebug("--> END \(String(describing: request.httpMethod)) (binary \(String(describing: request.httpBody?.count))-byte body omitted)")
		}
	}

	private static func logRequestBody(_ request: URLRequest) -> RequestBodyType {
		guard let bodyData = request.httpBody else {
			return .none
		}
		if let body = String(data: bodyData, encoding: .utf8) {
			if body.isEmpty {
				return .empty
			} else {
				CloudAccessDDLogDebug("Body: \(body)")
				return .plaintext
			}
		} else {
			return .binary
		}
	}

	// MARK: - URLResponse

	private enum ResponseBodyType {
		case none
		case empty
		case encoded
		case download
		case plaintext
		case binary
	}

	static func logResponse(_ response: URLResponse, with data: Data?, or localURL: URL?) {
		CloudAccessDDLogDebug("")
		guard let httpResponse = response as? HTTPURLResponse else {
			CloudAccessDDLogDebug("<-- \(String(describing: response.url))")
			return
		}
		CloudAccessDDLogDebug("<-- \(httpResponse.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)) \(String(describing: response.url))")
		httpResponse.allHeaderFields.reduce(into: [String: Any]()) { if let key = $1.key as? String { $0[key] = $1.value } }
			.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
			.filter { !isExcludedHeader($0.key) }
			.forEach { CloudAccessDDLogDebug("\($0.key): \($0.value)") }
		let bodyType = logResponseBody(httpResponse, with: data, or: localURL)
		switch bodyType {
		case .none:
			CloudAccessDDLogDebug("<-- END HTTP")
		case .empty:
			CloudAccessDDLogDebug("<-- END HTTP (empty body)")
		case .encoded:
			CloudAccessDDLogDebug("<-- END HTTP (encoded body omitted)")
		case .download:
			CloudAccessDDLogDebug("<-- END HTTP (downloaded body omitted)")
		case .plaintext:
			CloudAccessDDLogDebug("<-- END HTTP (\(String(describing: data?.count))-byte body)")
		case .binary:
			CloudAccessDDLogDebug("<-- END HTTP (binary \(String(describing: data?.count))-byte body omitted)")
		}
	}

	private static func logResponseBody(_ response: HTTPURLResponse, with data: Data?, or localURL: URL?) -> ResponseBodyType {
		if localURL != nil {
			return .download
		}
		guard let bodyData = data else {
			return .none
		}
		if let contentEncodingHeaderField = response.value(forHTTPHeaderField: "Content-Encoding"), contentEncodingHeaderField.caseInsensitiveCompare("identity") != .orderedSame {
			return .encoded
		}
		if let body = String(data: bodyData, encoding: .utf8) {
			if body.isEmpty {
				return .empty
			} else {
				CloudAccessDDLogDebug("Body: \(body)")
				return .plaintext
			}
		} else {
			return .binary
		}
	}

	// MARK: - Helpers

	private static func isExcludedHeader(_ name: String) -> Bool {
		let excludedNames = ["Authorization", "WWW-Authenticate", "Cookie", "Set-Cookie"]
		return excludedNames
			.map { $0.caseInsensitiveCompare(name) == .orderedSame }
			.contains(true)
	}
}
