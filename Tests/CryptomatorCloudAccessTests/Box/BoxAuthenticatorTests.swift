//
//  BoxAuthenticatorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import AuthenticationServices
import Foundation
import Testing
@testable import CryptomatorCloudAccess
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct BoxAuthenticatorTests {
		private let clientID = "clientid"
		private let state = "STATE"

		@Test
		func authorizationCodeFromCallbackURL() throws {
			#expect(try authorizationCode(fromCallbackURL: "boxsdk-clientid://boxsdkoauth2redirect?state=STATE&code=CODE%2B1") == "CODE+1")
		}

		@Test
		func rejectsInvalidCallbackURLs() {
			let callbackURLs = [
				"other://boxsdkoauth2redirect?state=STATE&code=CODE",
				"boxsdk-clientid://other?state=STATE&code=CODE",
				"boxsdk-clientid://boxsdkoauth2redirect?state=OTHER&code=CODE",
				"boxsdk-clientid://boxsdkoauth2redirect?code=CODE",
				"boxsdk-clientid://boxsdkoauth2redirect?state=STATE&error=server_error",
				"boxsdk-clientid://boxsdkoauth2redirect?state=STATE",
				"boxsdk-clientid://boxsdkoauth2redirect?state=STATE&code="
			]
			for callbackURL in callbackURLs {
				#expect(throws: BoxAuthenticatorError.authenticationFailed, "\(callbackURL)") { try authorizationCode(fromCallbackURL: callbackURL) }
			}
		}

		@Test
		func deniedAccessIsUserCancellation() throws {
			for callbackURL in ["boxsdk-clientid://boxsdkoauth2redirect?state=STATE&error=access_denied", "boxsdk-clientid://boxsdkoauth2redirect?error=access_denied&error_description=The+user+denied+access"] {
				let error = try #require(throws: (any Error).self, "\(callbackURL)") { try authorizationCode(fromCallbackURL: callbackURL) }
				#expect((error as? CocoaError)?.code == .userCancelled, "\(callbackURL)")
			}
		}

		@Test
		func convertLoginFlowErrorWithCanceledLogin() {
			#expect((BoxAuthenticator.convertLoginFlowError(ASWebAuthenticationSessionError(.canceledLogin)) as? CocoaError)?.code == .userCancelled)
		}

		@Test
		func convertLoginFlowErrorWithFailedSession() {
			#expect((BoxAuthenticator.convertLoginFlowError(ASWebAuthenticationSessionError(.presentationContextInvalid)) as? BoxAuthenticatorError) == .authenticationFailed)
		}

		@Test
		func convertLoginFlowErrorWithOtherError() {
			#expect((BoxAuthenticator.convertLoginFlowError(URLError(.timedOut)) as? URLError)?.code == .timedOut)
		}

		private func authorizationCode(fromCallbackURL callbackURL: String) throws -> String {
			return try BoxAuthenticator.authorizationCode(fromCallbackURL: #require(URL(string: callbackURL)), clientID: clientID, expectedState: state)
		}
	}
}
