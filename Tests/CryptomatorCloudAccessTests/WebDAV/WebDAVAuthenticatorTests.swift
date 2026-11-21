//
//  WebDAVAuthenticatorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

enum WebDAVAuthenticatorTestsError: Error {
	case missingTestResource
}

extension UnitTests {
	struct WebDAVAuthenticatorTests {
		let baseURL: URL
		let client: WebDAVClient

		init() throws {
			URLProtocolMock.requestHandler = []
			RecordingURLProtocolMock.log.reset()
			self.baseURL = try #require(URL(string: "/cloud/remote.php/webdav/"))
			self.client = .mocked(baseURL: baseURL)
		}

		@Test
		func testVerifyClient() async throws {
			let baseURL: URL = baseURL
			let optionsResponse = try #require(HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["DAV": "1"]))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == baseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (optionsResponse, nil)
			})

			let propfindData = try getTestData(forResource: "authentication-success", withExtension: "xml")
			let propfindResponse = try #require(HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == baseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, propfindData)
			})

			try await WebDAVAuthenticator.verifyClient(client: client)
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["OPTIONS /cloud/remote.php/webdav/", "PROPFIND Depth 0 /cloud/remote.php/webdav/"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Internal

		private func getTestData(forResource name: String, withExtension ext: String) throws -> Data {
			let testBundle = Bundle.module
			guard let fileURL = testBundle.url(forResource: name, withExtension: ext) else {
				throw WebDAVAuthenticatorTestsError.missingTestResource
			}
			return try Data(contentsOf: fileURL)
		}
	}
}
