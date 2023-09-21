//
//  GoogleDriveAuthenticatorMockTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 25.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
class GoogleDriveAuthenticatorMockTests: XCTestCase {
	/**
	 It is necessary to call another function than canAuthorize, because it returns true as soon as any refreshToken is set and does not check it online for correctness before.
	 */
	func testAuthenticationWorksWithoutViewController() throws {
		let expectation = XCTestExpectation(description: "Google Authentication works without ViewController")
		let credential = GoogleDriveAuthenticatorMock.generateAuthorizedCredential(withRefreshToken: IntegrationTestSecrets.googleDriveRefreshToken, tokenUID: "GDriveCredentialTest")
		credential.authSession?.authorizeRequest(NSMutableURLRequest(url: URL(string: "https://example.com")!), completionHandler: { error in
			XCTAssertNil(error)
			expectation.fulfill()
		})
		wait(for: [expectation], timeout: 60.0)
	}
}
