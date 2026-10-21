//
//  GoogleDriveAuthenticatorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

@preconcurrency import AppAuth
import XCTest
@testable import CryptomatorCloudAccess
#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#endif

class GoogleDriveAuthenticatorTests: XCTestCase {
	func testDriveAccessNeedsDriveScope() {
		XCTAssertTrue(GoogleDriveAuthenticator.grantsDriveAccess("https://www.googleapis.com/auth/drive openid https://www.googleapis.com/auth/userinfo.email"))
		for scopes in ["openid https://www.googleapis.com/auth/userinfo.email", "https://www.googleapis.com/auth/drive.file", nil] {
			XCTAssertFalse(GoogleDriveAuthenticator.grantsDriveAccess(scopes), scopes ?? "nil")
		}
	}

	func testConvertLoginFlowErrorWithCancellation() {
		for code in [OIDErrorCode.userCanceledAuthorizationFlow, .programCanceledAuthorizationFlow] {
			let error = NSError(domain: OIDGeneralErrorDomain, code: code.rawValue)

			XCTAssertEqual(.userCancelled, (GoogleDriveAuthenticator.convertLoginFlowError(error) as? CocoaError)?.code, "\(code)")
		}
	}

	func testConvertLoginFlowErrorWithOtherError() {
		let error = NSError(domain: OIDGeneralErrorDomain, code: OIDErrorCode.networkError.rawValue)

		XCTAssertEqual(error, GoogleDriveAuthenticator.convertLoginFlowError(error) as NSError)
	}
}
