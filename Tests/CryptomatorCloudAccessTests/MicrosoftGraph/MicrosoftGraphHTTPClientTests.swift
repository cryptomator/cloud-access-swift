//
//  MicrosoftGraphHTTPClientTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 14.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

private final class AccessTokenProviderMock: MicrosoftGraphAccessTokenProvider {
	func getAccessToken() async throws -> String {
		return "token"
	}
}

class MicrosoftGraphHTTPClientTests: XCTestCase {
	private let url = URL(string: "https://graph.microsoft.com/v1.0/me/drive/root")!
	private var client: MicrosoftGraphHTTPClient!

	override func setUpWithError() throws {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		client = MicrosoftGraphHTTPClient(accessTokenProvider: AccessTokenProviderMock(), configuration: configuration)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		client = nil
	}

	func testThrottledRequestIsRetried() async throws {
		let authorizationHeaders = OSAllocatedUnfairLock(initialState: [String?]())
		URLProtocolMock.requestHandler = [{ [url] request in
			authorizationHeaders.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
			return (HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "0"])!, nil)
		}, { [url] request in
			authorizationHeaders.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
			return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
		}]

		let (response, data) = try await client.data(for: URLRequest(url: url))

		XCTAssertEqual(200, response.statusCode)
		XCTAssertEqual(Data("{}".utf8), data)
		XCTAssertEqual(["Bearer token", "Bearer token"], authorizationHeaders.withLock { $0 })
	}

	func testThrottledResponseIsReturnedAfterLastRetry() async throws {
		URLProtocolMock.requestHandler = Array(repeating: { [url] _ in
			(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": "0"])!, nil)
		}, count: 4)

		let (response, _) = try await client.data(for: URLRequest(url: url))

		XCTAssertEqual(503, response.statusCode)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testUploadIsSentWithoutAuthorization() async throws {
		let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try Data("chunk".utf8).write(to: fileURL)
		defer {
			try? FileManager.default.removeItem(at: fileURL)
		}
		let authorizationHeaders = OSAllocatedUnfairLock(initialState: [String?]())
		URLProtocolMock.requestHandler = [{ [url] request in
			authorizationHeaders.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
			return (HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: nil)!, nil)
		}]
		var request = URLRequest(url: url)
		request.httpMethod = "PUT"

		let (response, _) = try await client.upload(request, fromFile: fileURL)

		XCTAssertEqual(202, response.statusCode)
		XCTAssertEqual([nil], authorizationHeaders.withLock { $0 })
	}
}
