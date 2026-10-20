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

	func testCredentialFromCallbackURL() throws {
		let credential = try credential(fromCallbackURL: "pclsdk-w-appkey://oauth2redirect#access_token=TOKEN%2B1&token_type=bearer&uid=7&userid=7&locationid=2&hostname=eapi.pcloud.com&state=STATE")

		XCTAssertEqual(7, credential.id)
		XCTAssertEqual("7", credential.userID)
		XCTAssertEqual("TOKEN+1", credential.accessToken)
		XCTAssertEqual(2, credential.locationID)
		XCTAssertEqual("eapi.pcloud.com", credential.apiHostName)
	}

	func testRejectsInvalidCallbackURLs() {
		let validFragment = "access_token=TOKEN&userid=7&locationid=2&hostname=eapi.pcloud.com&state=STATE"
		let callbackURLs = [
			"other://oauth2redirect#\(validFragment)",
			"pclsdk-w-appkey://other#\(validFragment)",
			"pclsdk-w-appkey://oauth2redirect",
			"pclsdk-w-appkey://oauth2redirect#error=access_denied&state=STATE",
			"pclsdk-w-appkey://oauth2redirect#access_token=TOKEN&userid=7&locationid=2&hostname=eapi.pcloud.com&state=OTHER",
			"pclsdk-w-appkey://oauth2redirect#access_token=TOKEN&userid=7&locationid=2&hostname=eapi.pcloud.com",
			"pclsdk-w-appkey://oauth2redirect#access_token=&userid=7&locationid=2&hostname=eapi.pcloud.com&state=STATE",
			"pclsdk-w-appkey://oauth2redirect#access_token=TOKEN&locationid=2&hostname=eapi.pcloud.com&state=STATE",
			"pclsdk-w-appkey://oauth2redirect#access_token=TOKEN&userid=seven&locationid=2&hostname=eapi.pcloud.com&state=STATE",
			"pclsdk-w-appkey://oauth2redirect#access_token=TOKEN&userid=7&hostname=eapi.pcloud.com&state=STATE",
			"pclsdk-w-appkey://oauth2redirect#access_token=TOKEN&userid=7&locationid=2&state=STATE",
			"pclsdk-w-appkey://oauth2redirect#access_token=TOKEN&userid=7&locationid=2&hostname=evil.example&state=STATE",
			"pclsdk-w-appkey://oauth2redirect#access_token=TOKEN&userid=7&locationid=2&hostname=evilpcloud.com&state=STATE",
			"pclsdk-w-appkey://oauth2redirect#access_token=TOKEN&userid=7&locationid=2&hostname=evil.com%2F.pcloud.com&state=STATE"
		]
		for callbackURL in callbackURLs {
			XCTAssertThrowsError(try credential(fromCallbackURL: callbackURL), callbackURL) { error in
				XCTAssertEqual(.authenticationFailed, error as? PCloudAuthenticatorError, callbackURL)
			}
		}
	}

	func testConvertLoginFlowErrorWithCanceledLogin() {
		XCTAssertEqual(.userCancelled, (PCloudAuthenticator.convertLoginFlowError(ASWebAuthenticationSessionError(.canceledLogin)) as? CocoaError)?.code)
	}

	func testConvertLoginFlowErrorWithFailedSession() {
		XCTAssertEqual(.authenticationFailed, PCloudAuthenticator.convertLoginFlowError(ASWebAuthenticationSessionError(.presentationContextInvalid)) as? PCloudAuthenticatorError)
	}

	private func credential(fromCallbackURL callbackURL: String) throws -> PCloudCredential {
		return try PCloudAuthenticator.credential(fromCallbackURL: XCTUnwrap(URL(string: callbackURL)), appKey: appKey, expectedState: state)
	}
}
