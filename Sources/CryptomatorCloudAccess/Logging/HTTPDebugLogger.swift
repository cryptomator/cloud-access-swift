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
		CloudAccessDDLogDebug("--> \(request.httpMethod ?? "nil") \(request.url?.absoluteString ?? "nil")")
		if let headerFields = request.allHTTPHeaderFields {
			headerFields.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
				.filter { !isExcludedHeader($0.key) }
				.forEach { CloudAccessDDLogDebug("\($0.key): \($0.value)") }
		}
		let bodyType = logRequestBody(request)
		switch bodyType {
		case .none:
			CloudAccessDDLogDebug("--> END \(request.httpMethod ?? "nil")")
		case .empty:
			CloudAccessDDLogDebug("--> END \(request.httpMethod ?? "nil") (empty body)")
		case .plaintext:
			CloudAccessDDLogDebug("--> END \(request.httpMethod ?? "nil") (\(request.httpBody?.count ?? -1)-byte body)")
		case .binary:
			CloudAccessDDLogDebug("--> END \(request.httpMethod ?? "nil") (binary \(request.httpBody?.count ?? -1)-byte body omitted)")
		}
	}

	private static func logRequestBody(_ request: URLRequest) -> RequestBodyType {
		guard let bodyData = request.httpBody else {
			return .none
		}
		// swiftlint:disable:next non_optional_string_data_conversion
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
		guard let httpResponse = response as? HTTPURLResponse else {
			CloudAccessDDLogDebug("<-- \(response.url?.absoluteString ?? "nil")")
			return
		}
		CloudAccessDDLogDebug("<-- \(httpResponse.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)) \(response.url?.absoluteString ?? "nil")")
		httpResponse.allHeaderFields.reduce(into: [:]) { if let key = $1.key as? String { $0[key] = $1.value } }
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
			CloudAccessDDLogDebug("<-- END HTTP (\(data?.count ?? -1)-byte body)")
		case .binary:
			CloudAccessDDLogDebug("<-- END HTTP (binary \(data?.count ?? -1)-byte body omitted)")
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
		// swiftlint:disable:next non_optional_string_data_conversion
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
