//
//  HTTPDebugLogger.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 15.11.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation

enum HTTPDebugLogger {
	/// Whether the body of a request or response is logged. Callers pass `.omitted` for a body that contains credentials, e.g., a token or a pre-authenticated URL, so that only its length is logged.
	enum BodyLogging {
		case logged
		case omitted
	}

	// MARK: - URLRequest

	private enum RequestBodyType {
		case none
		case empty
		case plaintext
		case binary
		case omitted
	}

	/// - Parameter session: The session that the request runs on, e.g., `foreground` or `background <identifier>`, if it should be logged.
	static func logRequest(_ request: URLRequest, session: String? = nil, bodyLogging: BodyLogging = .logged) {
		guard isCloudAccessLogEnabled(for: .debug) else {
			return
		}
		CloudAccessDDLogDebug("--> \(request.httpMethod ?? "nil") \(redactedURLString(request.url))")
		if let session {
			CloudAccessDDLogDebug("Session: \(session)")
		}
		if let headerFields = request.allHTTPHeaderFields {
			headerFields.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
				.filter { !isExcludedHeader($0.key) }
				.forEach { CloudAccessDDLogDebug("\($0.key): \(redactedHeaderValue($0.value, forHeader: $0.key))") }
		}
		let bodyType = logRequestBody(request, bodyLogging: bodyLogging)
		switch bodyType {
		case .none:
			CloudAccessDDLogDebug("--> END \(request.httpMethod ?? "nil")")
		case .empty:
			CloudAccessDDLogDebug("--> END \(request.httpMethod ?? "nil") (empty body)")
		case .plaintext:
			CloudAccessDDLogDebug("--> END \(request.httpMethod ?? "nil") (\(request.httpBody?.count ?? -1)-byte body)")
		case .binary:
			CloudAccessDDLogDebug("--> END \(request.httpMethod ?? "nil") (binary \(request.httpBody?.count ?? -1)-byte body omitted)")
		case .omitted:
			CloudAccessDDLogDebug("--> END \(request.httpMethod ?? "nil") (\(request.httpBody?.count ?? -1)-byte body omitted)")
		}
	}

	private static func logRequestBody(_ request: URLRequest, bodyLogging: BodyLogging) -> RequestBodyType {
		guard let bodyData = request.httpBody else {
			return .none
		}
		guard bodyLogging == .logged else {
			return .omitted
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
		case omitted
	}

	static func logResponse(_ response: URLResponse, with data: Data?, or localURL: URL?, bodyLogging: BodyLogging = .logged) {
		guard isCloudAccessLogEnabled(for: .debug) else {
			return
		}
		guard let httpResponse = response as? HTTPURLResponse else {
			CloudAccessDDLogDebug("<-- \(redactedURLString(response.url))")
			return
		}
		CloudAccessDDLogDebug("<-- \(httpResponse.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)) \(redactedURLString(response.url))")
		httpResponse.allHeaderFields
			.reduce(into: [String: Any]()) { result, header in
				if let key = header.key as? String {
					result[key] = header.value
				}
			}
			.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
			.filter { !isExcludedHeader($0.key) }
			.forEach { CloudAccessDDLogDebug("\($0.key): \(redactedHeaderValue("\($0.value)", forHeader: $0.key))") }
		let bodyType = logResponseBody(httpResponse, with: data, or: localURL, bodyLogging: bodyLogging)
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
		case .omitted:
			CloudAccessDDLogDebug("<-- END HTTP (\(data?.count ?? -1)-byte body omitted)")
		}
	}

	private static func logResponseBody(_ response: HTTPURLResponse, with data: Data?, or localURL: URL?, bodyLogging: BodyLogging) -> ResponseBodyType {
		if localURL != nil {
			return .download
		}
		guard let bodyData = data else {
			return .none
		}
		guard bodyLogging == .logged else {
			return .omitted
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

	/// Returns the URL without its user info and fragment, and with the value of every query parameter replaced, because these can contain credentials, e.g., the token of a pre-authenticated URL.
	static func redactedURLString(_ url: URL?) -> String {
		guard let url else {
			return "nil"
		}
		guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
			return "<unparsable URL>"
		}
		let query = components.percentEncodedQuery
		components.user = nil
		components.password = nil
		components.query = nil
		components.fragment = nil
		guard var urlString = components.string else {
			return "<unparsable URL>"
		}
		if let query {
			urlString += "?" + query.split(separator: "&", omittingEmptySubsequences: false).map { parameter in
				guard let separatorIndex = parameter.firstIndex(of: "=") else {
					return String(parameter)
				}
				return "\(parameter[..<separatorIndex])=<redacted>"
			}.joined(separator: "&")
		}
		return urlString
	}

	private static func redactedHeaderValue(_ value: String, forHeader name: String) -> String {
		let urlHeaderNames = ["Location", "Content-Location", "Destination"]
		guard urlHeaderNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
			return value
		}
		guard let url = URL(string: value) else {
			return "<unparsable URL>"
		}
		return redactedURLString(url)
	}

	private static func isExcludedHeader(_ name: String) -> Bool {
		let excludedNames = ["Authorization", "WWW-Authenticate", "Cookie", "Set-Cookie"]
		return excludedNames
			.map { $0.caseInsensitiveCompare(name) == .orderedSame }
			.contains(true)
	}
}
