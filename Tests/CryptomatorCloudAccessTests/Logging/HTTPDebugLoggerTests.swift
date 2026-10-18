//
//  HTTPDebugLoggerTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class HTTPDebugLoggerTests: XCTestCase {
	private let url = URL(string: "https://user:SECRET-PASSWORD@example.com:8443/path/file.txt?token=SECRET-TOKEN&flag#SECRET-FRAGMENT")!
	private var logCapture: LogCapture!

	override func setUp() {
		logCapture = LogCapture.start()
	}

	override func tearDown() {
		logCapture.stop()
	}

	func testRequestLineIsRedacted() {
		var request = URLRequest(url: url)
		request.httpMethod = "GET"

		HTTPDebugLogger.logRequest(request)

		XCTAssertTrue(logCapture.messages.contains("--> GET https://example.com:8443/path/file.txt?token=<redacted>&flag"))
		XCTAssertFalse(logCapture.joinedMessages.contains("SECRET"))
	}

	func testResponseLineIsRedacted() throws {
		let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))

		HTTPDebugLogger.logResponse(response, with: nil, or: nil)

		XCTAssertTrue(logCapture.messages.contains("<-- 200 no error https://example.com:8443/path/file.txt?token=<redacted>&flag"))
		XCTAssertFalse(logCapture.joinedMessages.contains("SECRET"))
	}

	func testNonHTTPResponseLineIsRedacted() {
		let response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)

		HTTPDebugLogger.logResponse(response, with: nil, or: nil)

		XCTAssertTrue(logCapture.messages.contains("<-- https://example.com:8443/path/file.txt?token=<redacted>&flag"))
		XCTAssertFalse(logCapture.joinedMessages.contains("SECRET"))
	}

	func testURLHeadersAreRedacted() throws {
		var request = try URLRequest(url: XCTUnwrap(URL(string: "https://example.com/source")))
		request.httpMethod = "MOVE"
		request.setValue("https://example.com/target?sig=SECRET-SIGNATURE", forHTTPHeaderField: "destination")
		let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://download.example.com/file?sig=SECRET-SIGNATURE"]))

		HTTPDebugLogger.logRequest(request)
		HTTPDebugLogger.logResponse(response, with: nil, or: nil)

		XCTAssertTrue(logCapture.messages.contains("destination: https://example.com/target?sig=<redacted>"))
		XCTAssertTrue(logCapture.messages.contains("Location: https://download.example.com/file?sig=<redacted>"))
		XCTAssertFalse(logCapture.joinedMessages.contains("SECRET"))
	}

	func testOmittedBodiesAreNotLogged() throws {
		var request = try URLRequest(url: XCTUnwrap(URL(string: "https://example.com/oauth2/token")))
		request.httpMethod = "POST"
		request.httpBody = Data("refresh_token=SECRET-REFRESH-TOKEN".utf8)
		let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))

		HTTPDebugLogger.logRequest(request, bodyLogging: .omitted)
		HTTPDebugLogger.logResponse(response, with: Data("{\"access_token\":\"SECRET-ACCESS-TOKEN\"}".utf8), or: nil, bodyLogging: .omitted)

		XCTAssertTrue(logCapture.messages.contains("--> END POST (34-byte body omitted)"))
		XCTAssertTrue(logCapture.messages.contains("<-- END HTTP (38-byte body omitted)"))
		XCTAssertFalse(logCapture.joinedMessages.contains("SECRET"))
	}

	func testSessionIsLogged() throws {
		let request = try URLRequest(url: XCTUnwrap(URL(string: "https://example.com/file")))

		HTTPDebugLogger.logRequest(request, session: "background com.example.session")

		XCTAssertTrue(logCapture.messages.contains("Session: background com.example.session"))
	}
}
