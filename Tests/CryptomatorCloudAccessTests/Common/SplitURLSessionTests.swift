//
//  SplitURLSessionTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class SplitURLSessionTests: XCTestCase {
	private let url = URL(string: "https://api.example.com/files/1/content")!
	private var session: SplitURLSession!

	override func setUpWithError() throws {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		session = SplitURLSession(configuration: configuration)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		session = nil
	}

	func testCrossOriginRedirectRemovesAuthorization() async throws {
		let redirectURL = try XCTUnwrap(URL(string: "https://download.example.com/files/1"))
		let authorizationHeaders = try await authorizationHeaders(redirectingTo: redirectURL)
		XCTAssertEqual(["Bearer token", nil], authorizationHeaders)
	}

	func testSameOriginRedirectKeepsAuthorization() async throws {
		let redirectURL = try XCTUnwrap(URL(string: "https://api.example.com/files/2/content"))
		let authorizationHeaders = try await authorizationHeaders(redirectingTo: redirectURL)
		XCTAssertEqual(["Bearer token", "Bearer token"], authorizationHeaders)
	}

	// MARK: - Helpers

	private func authorizationHeaders(redirectingTo redirectURL: URL) async throws -> [String?] {
		let authorizationHeaders = OSAllocatedUnfairLock(initialState: [String?]())
		URLProtocolMock.requestHandler = [{ [url] request in
			authorizationHeaders.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
			return (HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": redirectURL.absoluteString])!, nil)
		}, { request in
			authorizationHeaders.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
			return (HTTPURLResponse(url: redirectURL, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("content".utf8))
		}]
		var request = URLRequest(url: url)
		request.setValue("Bearer token", forHTTPHeaderField: "Authorization")

		let (response, data) = try await session.data(for: request)

		XCTAssertEqual(200, response.statusCode)
		XCTAssertEqual(Data("content".utf8), data)
		return authorizationHeaders.withLock { $0 }
	}
}
