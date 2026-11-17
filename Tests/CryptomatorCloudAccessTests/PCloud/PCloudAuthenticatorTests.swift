//
//  PCloudAuthenticatorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 19.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import AuthenticationServices
import Foundation
import Testing
@testable import CryptomatorCloudAccess
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct PCloudAuthenticatorTests {
		private let appKey = "AppKey"
		private let state = "STATE"

		@Test
		func callbackFromCallbackURL() throws {
			let callback = try callback(fromCallbackURL: "pclsdk-w-appkey://oauth2redirect#access_token=TOKEN%2B1&token_type=bearer&uid=7&userid=7&locationid=2&hostname=eapi.pcloud.com&state=STATE")

			#expect(PCloudCallback(accessToken: "TOKEN+1", userID: "7", apiHostName: "eapi.pcloud.com") == callback)
		}

		@Test
		func rejectsInvalidCallbackURLs() {
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
				#expect(throws: PCloudAuthenticatorError.authenticationFailed, "\(callbackURL)") { try callback(fromCallbackURL: callbackURL) }
			}
		}

		@Test
		func deniedAccessIsUserCancellation() throws {
			for callbackURL in ["pclsdk-w-appkey://oauth2redirect#error=access_denied&state=STATE", "pclsdk-w-appkey://oauth2redirect#error=access_denied"] {
				let error = try #require(throws: (any Error).self, "\(callbackURL)") { try callback(fromCallbackURL: callbackURL) }
				#expect((error as? CocoaError)?.code == .userCancelled, "\(callbackURL)")
			}
		}

		@Test
		func convertLoginFlowErrorWithCanceledLogin() {
			#expect((PCloudAuthenticator.convertLoginFlowError(ASWebAuthenticationSessionError(.canceledLogin)) as? CocoaError)?.code == .userCancelled)
		}

		@Test
		func convertLoginFlowErrorWithFailedSession() {
			#expect((PCloudAuthenticator.convertLoginFlowError(ASWebAuthenticationSessionError(.presentationContextInvalid)) as? PCloudAuthenticatorError) == .authenticationFailed)
		}

		private func callback(fromCallbackURL callbackURL: String) throws -> PCloudCallback {
			return try PCloudAuthenticator.callback(fromCallbackURL: #require(URL(string: callbackURL)), appKey: appKey, expectedState: state)
		}
	}
}
