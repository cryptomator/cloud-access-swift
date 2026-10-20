//
//  BoxAuthenticatorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import AuthenticationServices
import XCTest
@testable import CryptomatorCloudAccess
#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#endif

class BoxAuthenticatorTests: XCTestCase {
	private let clientId = "clientid"
	private let state = "STATE"

	func testAuthorizationCodeFromCallbackURL() throws {
		XCTAssertEqual("CODE+1", try authorizationCode(fromCallbackURL: "boxsdk-clientid://boxsdkoauth2redirect?state=STATE&code=CODE%2B1"))
	}

	func testRejectsInvalidCallbackURLs() {
		let callbackURLs = [
			"other://boxsdkoauth2redirect?state=STATE&code=CODE",
			"boxsdk-clientid://other?state=STATE&code=CODE",
			"boxsdk-clientid://boxsdkoauth2redirect?state=OTHER&code=CODE",
			"boxsdk-clientid://boxsdkoauth2redirect?code=CODE",
			"boxsdk-clientid://boxsdkoauth2redirect?state=STATE&error=access_denied",
			"boxsdk-clientid://boxsdkoauth2redirect?state=STATE&error=access_denied&code=CODE",
			"boxsdk-clientid://boxsdkoauth2redirect?state=STATE",
			"boxsdk-clientid://boxsdkoauth2redirect?state=STATE&code="
		]
		for callbackURL in callbackURLs {
			XCTAssertThrowsError(try authorizationCode(fromCallbackURL: callbackURL), callbackURL) { error in
				XCTAssertEqual(.authenticationFailed, error as? BoxAuthenticatorError, callbackURL)
			}
		}
	}

	func testConvertLoginFlowErrorWithCanceledLogin() {
		XCTAssertEqual(.userCancelled, (BoxAuthenticator.convertLoginFlowError(ASWebAuthenticationSessionError(.canceledLogin)) as? CocoaError)?.code)
	}

	func testConvertLoginFlowErrorWithFailedSession() {
		XCTAssertEqual(.authenticationFailed, BoxAuthenticator.convertLoginFlowError(ASWebAuthenticationSessionError(.presentationContextInvalid)) as? BoxAuthenticatorError)
	}

	func testConvertLoginFlowErrorWithOtherError() {
		XCTAssertEqual(.timedOut, (BoxAuthenticator.convertLoginFlowError(URLError(.timedOut)) as? URLError)?.code)
	}

	private func authorizationCode(fromCallbackURL callbackURL: String) throws -> String {
		return try BoxAuthenticator.authorizationCode(fromCallbackURL: XCTUnwrap(URL(string: callbackURL)), clientId: clientId, expectedState: state)
	}
}
