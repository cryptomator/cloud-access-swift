//
//  HTTPDebugLoggerTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class HTTPDebugLoggerTests {
		private let url = URL(string: "https://user:SECRET-PASSWORD@example.com:8443/path/file.txt?token=SECRET-TOKEN&SECRET-BARE-TOKEN#SECRET-FRAGMENT")!
		private let logCapture = LogCapture.start()

		deinit {
			logCapture.stop()
		}

		@Test
		func requestLineIsRedacted() {
			var request = URLRequest(url: url)
			request.httpMethod = "GET"

			HTTPDebugLogger.logRequest(request)

			#expect(logCapture.messages.contains("--> GET https://example.com:8443/path/file.txt?token=<redacted>&<redacted>"))
			#expect(!logCapture.joinedMessages.contains("SECRET"))
		}

		@Test
		func responseLineIsRedacted() throws {
			let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))

			HTTPDebugLogger.logResponse(response, requestURL: url, with: nil, or: nil)

			#expect(logCapture.messages.contains("<-- 200 no error https://example.com:8443/path/file.txt?token=<redacted>&<redacted>"))
			#expect(!logCapture.joinedMessages.contains("SECRET"))
		}

		@Test
		func nonHTTPResponseLineIsRedacted() {
			let response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)

			HTTPDebugLogger.logResponse(response, requestURL: url, with: nil, or: nil)

			#expect(logCapture.messages.contains("<-- https://example.com:8443/path/file.txt?token=<redacted>&<redacted>"))
			#expect(!logCapture.joinedMessages.contains("SECRET"))
		}

		@Test
		func urlHeadersAreRedacted() throws {
			var request = try URLRequest(url: #require(URL(string: "https://example.com/source")))
			request.httpMethod = "MOVE"
			request.setValue("https://example.com/target?sig=SECRET-SIGNATURE", forHTTPHeaderField: "destination")
			let response = try #require(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://example.com:8443/file?sig=SECRET-SIGNATURE"]))

			HTTPDebugLogger.logRequest(request)
			HTTPDebugLogger.logResponse(response, requestURL: url, with: nil, or: nil)

			#expect(logCapture.messages.contains("destination: https://example.com/target?sig=<redacted>"))
			#expect(logCapture.messages.contains("Location: https://example.com:8443/file?sig=<redacted>"))
			#expect(!logCapture.joinedMessages.contains("SECRET"))
		}

		@Test
		func originOnlyURLsAreRedacted() throws {
			var request = URLRequest(url: url)
			request.httpMethod = "PUT"
			let response = try #require(HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: ["Location": "https://example.com:8443/up/SECRET-PATH-TOKEN"]))

			HTTPDebugLogger.logRequest(request, urlLogging: .originOnly)
			HTTPDebugLogger.logResponse(response, requestURL: url, with: nil, or: nil, urlLogging: .originOnly)

			#expect(logCapture.messages.contains("--> PUT https://example.com:8443/<redacted>"))
			#expect(logCapture.messages.contains("<-- 201 created https://example.com:8443/<redacted>"))
			#expect(logCapture.messages.contains("Location: https://example.com:8443/<redacted>"))
			#expect(!logCapture.joinedMessages.contains("SECRET"))
			#expect(!logCapture.joinedMessages.contains("file.txt"))
		}

		@Test
		func crossOriginURLsAreLoggedOriginOnly() throws {
			let requestURL = try #require(URL(string: "https://example.com/source"))
			var request = URLRequest(url: requestURL)
			request.httpMethod = "MOVE"
			request.setValue("http://example.com/SECRET-DESTINATION", forHTTPHeaderField: "Destination")
			let responseURL = try #require(URL(string: "https://example.com:8443/SECRET-RESPONSE-PATH"))
			let response = try #require(HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: nil, headerFields: ["Location": "https://download.example.com/SECRET-LOCATION", "Content-Location": "/SECRET-RELATIVE-PATH"]))

			HTTPDebugLogger.logRequest(request)
			HTTPDebugLogger.logResponse(response, requestURL: requestURL, with: nil, or: nil)

			#expect(logCapture.messages.contains("--> MOVE https://example.com/source"))
			#expect(logCapture.messages.contains("Destination: http://example.com/<redacted>"))
			#expect(logCapture.messages.contains("<-- 201 created https://example.com:8443/<redacted>"))
			#expect(logCapture.messages.contains("Location: https://download.example.com/<redacted>"))
			#expect(logCapture.messages.contains("Content-Location: https://example.com:8443/<redacted>"))
			#expect(!logCapture.joinedMessages.contains("SECRET"))
		}

		@Test
		func omittedBodiesAreNotLogged() throws {
			var request = try URLRequest(url: #require(URL(string: "https://example.com/oauth2/token")))
			request.httpMethod = "POST"
			request.httpBody = Data("refresh_token=SECRET-REFRESH-TOKEN".utf8)
			let requestURL = try #require(request.url)
			let response = try #require(HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil))

			HTTPDebugLogger.logRequest(request, bodyLogging: .omitted)
			HTTPDebugLogger.logResponse(response, requestURL: request.url, with: Data("{\"access_token\":\"SECRET-ACCESS-TOKEN\"}".utf8), or: nil, bodyLogging: .omitted)

			#expect(logCapture.messages.contains("--> END POST (34-byte body omitted)"))
			#expect(logCapture.messages.contains("<-- END HTTP (38-byte body omitted)"))
			#expect(!logCapture.joinedMessages.contains("SECRET"))
		}

		@Test
		func sessionIsLogged() throws {
			let request = try URLRequest(url: #require(URL(string: "https://example.com/file")))

			HTTPDebugLogger.logRequest(request, session: "background com.example.session")

			#expect(logCapture.messages.contains("Session: background com.example.session"))
		}
	}
}
