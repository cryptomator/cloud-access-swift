//
//  MicrosoftGraphCredentialMock.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 20.05.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class MicrosoftGraphCredentialMock: MicrosoftGraphCredential {
	init() {
		let authProvider = MSAuthenticationProviderMock()
		let clientApplication = MSALPublicClientApplicationStub()
		super.init(identifier: "IntegrationTests", scopes: MicrosoftGraphType.oneDrive.scopes, authProvider: authProvider, clientApplication: clientApplication)
	}

	func resetAccessTokenOverride() {
		// swiftlint:disable:next force_cast
		let authProvider = self.authProvider as! MSAuthenticationProviderMock
		authProvider.overrideAccessToken = nil
	}

	override func deauthenticate() throws {
		// swiftlint:disable:next force_cast
		let authProvider = self.authProvider as! MSAuthenticationProviderMock
		authProvider.overrideAccessToken = "InvalidToken"
	}
}
