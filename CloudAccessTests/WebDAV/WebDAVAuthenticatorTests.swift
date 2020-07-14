//
//  WebDAVAuthenticatorTests.swift
//  CloudAccessTests
//
//  Created by Tobias Hagemann on 13.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest
@testable import CloudAccess

enum WebDAVAuthenticatorTestsError: Error {
	case missingTestResource
}

class WebDAVAuthenticatorTests: XCTestCase {
	var client: WebDAVClientMock!

	override func setUp() {
		client = WebDAVClientMock()
	}

	func testVerifyClient() throws {
		let expectation = XCTestExpectation(description: "verifyClient")
		client.urlSession.response = HTTPURLResponse(url: URL(string: "/cloud/remote.php/webdav/")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["DAV": "1"])
		client.urlSession.data = try getData(forResource: "authentication-success", withExtension: "xml")
		WebDAVAuthenticator.verifyClient(client: client).catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	// MARK: - Internal

	private func getData(forResource name: String, withExtension ext: String) throws -> Data {
		let testBundle = Bundle(for: type(of: self))
		guard let fileURL = testBundle.url(forResource: name, withExtension: ext) else {
			throw WebDAVAuthenticatorTestsError.missingTestResource
		}
		return try Data(contentsOf: fileURL)
	}
}
