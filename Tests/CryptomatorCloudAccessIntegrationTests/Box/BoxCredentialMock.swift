//
//  BoxCredentialMock.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Majid Achhoud on 15.04.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises
@testable import BoxSdkGen
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class BoxCredentialMock: BoxCredential {
	init() {
		// Set up Box constants for testing purposes
		BoxSetup.constants = BoxSetup(clientId: "", clientSecret: "", sharedContainerIdentifier: "")

		// Initialize the BoxCredential with InMemoryTokenStore
		let tokenStore = InMemoryTokenStorage()
		super.init(tokenStorage: tokenStore)

		// Override the client with a test token using BoxDeveloperTokenAuth
		let devTokenAuth = BoxDeveloperTokenAuth(token: IntegrationTestSecrets.boxDeveloperToken)
		client = BoxClient(auth: devTokenAuth)
	}

	override func deauthenticate() -> Promise<Void> {
		// Set the client to an invalid token for deauthentication in tests
		let invalidTokenAuth = BoxDeveloperTokenAuth(token: "invalid")
		client = BoxClient(auth: invalidTokenAuth)
		return Promise(())
	}
}
