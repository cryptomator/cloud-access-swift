//
//  PCloudCredentialTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 19.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class PCloudCredentialTests: XCTestCase {
	override func tearDown() {
		URLProtocolMock.requestHandler = []
	}

	func testGetUsernameReturnsEmail() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"result":0,"email":"user@example.com","userid":1}"#)]

		let username = try await PCloudCredential.stub().getUsername(client: .mocked())

		XCTAssertEqual("user@example.com", username)
	}

	func testGetUsernameThrowsAPIError() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudMockResponse.result(2009))]

		await XCTAssertThrowsErrorAsync(try await PCloudCredential.stub().getUsername(client: .mocked())) { error in
			XCTAssertEqual(.apiError(code: 2009, message: "Error 2009."), error as? PCloudError)
		}
	}

	func testAcceptsAPIHostNames() throws {
		XCTAssertEqual("api.pcloud.com", try PCloudCredential(id: 1, accessToken: "token", apiHostName: "api.pcloud.com", locationID: 1).apiHostName)
		XCTAssertEqual("eapi.pcloud.com", try PCloudCredential(id: 1, accessToken: "token", apiHostName: "EAPI.PCLOUD.COM", locationID: 2).apiHostName)
	}

	func testRejectsAPIHostNamesThatAreNoBareHostNames() {
		for apiHostName in ["evil.com/.pcloud.com", "evil.com?.pcloud.com", "evil.com#.pcloud.com", "user@evil.com", "api.pcloud.com:8443", "api..pcloud.com", "", "[::1]", "api.pcloud.com.", "api pcloud.com", "äpi.pcloud.com"] {
			XCTAssertThrowsError(try PCloudCredential(id: 1, accessToken: "token", apiHostName: apiHostName, locationID: 1), apiHostName) { error in
				XCTAssertEqual(.badURL, (error as? URLError)?.code, apiHostName)
			}
		}
	}
}
