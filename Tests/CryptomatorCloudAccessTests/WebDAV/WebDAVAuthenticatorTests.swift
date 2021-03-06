//
//  WebDAVAuthenticatorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import Foundation
import XCTest

enum WebDAVAuthenticatorTestsError: Error {
	case missingTestResource
}

class WebDAVAuthenticatorTests: XCTestCase {
	var baseURL: URL!
	var client: WebDAVClientMock!

	override func setUp() {
		baseURL = URL(string: "/cloud/remote.php/webdav/")
		client = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolMock.self)
	}

	func testVerifyClient() throws {
		let expectation = XCTestExpectation(description: "verifyClient")

		let optionsResponse = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["DAV": "1"])!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == self.baseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (optionsResponse, nil)
		})

		let propfindData = try getTestData(forResource: "authentication-success", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == self.baseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		WebDAVAuthenticator.verifyClient(client: client).then {
			XCTAssertTrue(self.client.optionsRequests.contains(self.baseURL.relativePath))
			XCTAssertEqual(.zero, self.client.propfindRequests[self.baseURL.relativePath])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	// MARK: - Internal

	private func getTestData(forResource name: String, withExtension ext: String) throws -> Data {
		let testBundle = Bundle(for: type(of: self))
		guard let fileURL = testBundle.url(forResource: name, withExtension: ext) else {
			throw WebDAVAuthenticatorTestsError.missingTestResource
		}
		return try Data(contentsOf: fileURL)
	}
}
