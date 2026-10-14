//
//  BoxAuthenticatorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import AuthenticationServices
@preconcurrency import BoxSdkGen
import XCTest
@testable import CryptomatorCloudAccess

@MainActor
class BoxAuthenticatorTests: XCTestCase {
	func testAuthenticateWithInvalidContext() async {
		let viewController = UIViewController()
		let authentication = _Concurrency.Task {
			try await BoxAuthenticator.authenticate(from: viewController, tokenStorage: InMemoryTokenStorage())
		}
		await XCTAssertThrowsErrorAsync(try await value(of: authentication)) { error in
			XCTAssertEqual(BoxAuthenticatorError.invalidContext, error as? BoxAuthenticatorError)
		}
	}

	func testConvertLoginFlowErrorWithCanceledLogin() {
		let error = BoxSDKError(message: "", error: ASWebAuthenticationSessionError(.canceledLogin))
		XCTAssertEqual(.userCancelled, (BoxAuthenticator.convertLoginFlowError(error) as? CocoaError)?.code)
	}

	func testConvertLoginFlowErrorWithFailedSession() {
		let error = BoxSDKError(message: "", error: ASWebAuthenticationSessionError(.presentationContextInvalid))
		XCTAssertEqual(.authenticationFailed, BoxAuthenticator.convertLoginFlowError(error) as? BoxAuthenticatorError)
	}

	func testConvertLoginFlowErrorWithOtherError() {
		let error = BoxSDKError(message: "other")
		XCTAssertTrue(BoxAuthenticator.convertLoginFlowError(error) as? BoxSDKError === error)
	}
}
