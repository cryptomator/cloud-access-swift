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

/// `@unchecked Sendable`: restates the conformance of `MicrosoftGraphCredential`; this subclass adds no state.
class MicrosoftGraphCredentialMock: MicrosoftGraphCredential, @unchecked Sendable {
	init() {
		let tokenSource = MicrosoftGraphTokenSourceMock()
		let clientApplication = MSALPublicClientApplicationStub()
		super.init(identifier: "IntegrationTests", scopes: MicrosoftGraphType.oneDrive.scopes, tokenSource: tokenSource, clientApplication: clientApplication)
	}

	override func deauthenticate() throws {
		// swiftlint:disable:next force_cast
		let tokenSource = tokenSource as! MicrosoftGraphTokenSourceMock
		tokenSource.overrideAccessToken = "InvalidToken"
	}
}
