//
//  PCloudAuthenticatorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 19.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import AuthenticationServices
import XCTest
@testable import CryptomatorCloudAccess
#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#endif

class PCloudAuthenticatorTests: XCTestCase {
	private let appKey = "AppKey"
	private let state = "STATE"

	func testCallbackFromCallbackURL() throws {
		let callback = try callback(fromCallbackURL: "pclsdk-w-appkey://oauth2redirect#access_token=TOKEN%2B1&token_type=bearer&uid=7&userid=7&locationid=2&hostname=eapi.pcloud.com&state=STATE")

		XCTAssertEqual(PCloudCallback(accessToken: "TOKEN+1", userID: "7", apiHostName: "eapi.pcloud.com"), callback)
	}

	func testRejectsInvalidCallbackURLs() {
		let validFragment = "access_token=TOKEN&userid=7&locationid=2&hostname=eapi.pcloud.com&state=STATE"
		let callbackURLs = [
			"other://oauth2redirect#\(validFragment)",
			"pclsdk-w-appkey://other#\(validFragment)",
			"pclsdk-w-appkey://oauth2redirect",
			"pclsdk-w-appkey://oauth2redirect#error=invalid_request&state=STATE",
			"pclsdk-w-appkey://oauth2redirect#access_token=TOKEN&userid=7&locationid=2&hostname=eapi.pcloud.com&state=OTHER",
			"pclsdk-w-appkey://oauth2redirect#access_token=TOKEN&userid=7&locationid=2&hostname=eapi.pcloud.com",
			"pclsdk-w-appkey://oauth2redirect#access_token=&userid=7&locationid=2&hostname=eapi.pcloud.com&state=STATE",
			"pclsdk-w-appkey://oauth2redirect#access_token=TOKEN&locationid=2&hostname=eapi.pcloud.com&state=STATE",
			"pclsdk-w-appkey://oauth2redirect#access_token=TOKEN&userid=seven&locationid=2&hostname=eapi.pcloud.com&state=STATE",
			"pclsdk-w-appkey://oauth2redirect#access_token=TOKEN&userid=7&locationid=2&state=STATE"
		]
		for callbackURL in callbackURLs {
			XCTAssertThrowsError(try callback(fromCallbackURL: callbackURL), callbackURL) { error in
				XCTAssertEqual(.authenticationFailed, error as? PCloudAuthenticatorError, callbackURL)
			}
		}
	}

	func testDeniedAccessIsUserCancellation() {
		for callbackURL in ["pclsdk-w-appkey://oauth2redirect#error=access_denied&state=STATE", "pclsdk-w-appkey://oauth2redirect#error=access_denied"] {
			XCTAssertThrowsError(try callback(fromCallbackURL: callbackURL), callbackURL) { error in
				XCTAssertEqual(.userCancelled, (error as? CocoaError)?.code, callbackURL)
			}
		}
	}

	func testConvertLoginFlowErrorWithCanceledLogin() {
		XCTAssertEqual(.userCancelled, (PCloudAuthenticator.convertLoginFlowError(ASWebAuthenticationSessionError(.canceledLogin)) as? CocoaError)?.code)
	}

	func testConvertLoginFlowErrorWithFailedSession() {
		XCTAssertEqual(.authenticationFailed, PCloudAuthenticator.convertLoginFlowError(ASWebAuthenticationSessionError(.presentationContextInvalid)) as? PCloudAuthenticatorError)
	}

	private func callback(fromCallbackURL callbackURL: String) throws -> PCloudCallback {
		return try PCloudAuthenticator.callback(fromCallbackURL: XCTUnwrap(URL(string: callbackURL)), appKey: appKey, expectedState: state)
	}
}
