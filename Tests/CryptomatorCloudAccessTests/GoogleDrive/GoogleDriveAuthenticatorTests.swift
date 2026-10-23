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

	func testConvertLoginFlowErrorWithDeniedAccess() {
		let error = NSError(domain: OIDOAuthAuthorizationErrorDomain, code: OIDErrorCodeOAuth.accessDenied.rawValue)

		XCTAssertEqual(.userCancelled, (GoogleDriveAuthenticator.convertLoginFlowError(error) as? CocoaError)?.code)
	}

	func testConvertLoginFlowErrorWithOtherError() {
		for error in [NSError(domain: OIDGeneralErrorDomain, code: OIDErrorCode.networkError.rawValue), NSError(domain: OIDOAuthAuthorizationErrorDomain, code: OIDErrorCodeOAuth.invalidScope.rawValue)] {
			XCTAssertEqual(error, GoogleDriveAuthenticator.convertLoginFlowError(error) as NSError)
		}
	}

	@MainActor
	func testCancellationCancelsLoginFlow() async throws {
		let started = XCTestExpectation(description: "started")
		let cancelled = XCTestExpectation(description: "cancelled")
		let login = Task { @MainActor in
			try await GoogleDriveAuthenticator.runLoginFlow { _ in
				started.fulfill()
				return { cancelled.fulfill() }
			}
		}
		await fulfillment(of: [started], timeout: testWaitTimeout)

		login.cancel()

		await XCTAssertThrowsErrorAsync(try await value(of: login)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		await fulfillment(of: [cancelled], timeout: testWaitTimeout)
	}
}
