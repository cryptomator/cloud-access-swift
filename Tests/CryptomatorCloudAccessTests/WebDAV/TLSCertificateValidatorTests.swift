//
//  TLSCertificateValidatorTests.swift
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

class TLSCertificateValidatorTests: XCTestCase {
	func testValidateRethrowsConnectionError() async throws {
		let validator = try TLSCertificateValidator(baseURL: XCTUnwrap(URL(string: "https://127.0.0.1:1/")))
		await XCTAssertThrowsErrorAsync(try await validator.validate()) { error in
			XCTAssertEqual(.cannotConnectToHost, (error as? URLError)?.code)
		}
	}
}
