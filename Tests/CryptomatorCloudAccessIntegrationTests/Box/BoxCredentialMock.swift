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
		BoxSetup.constants = BoxSetup(clientId: "", clientSecret: "", sharedContainerIdentifier: "")
		super.init(tokenStorage: InMemoryTokenStorage())
		let devTokenAuth = BoxDeveloperTokenAuth(token: IntegrationTestSecrets.boxDeveloperToken)
		client = BoxClient(auth: devTokenAuth)
	}

	override func deauthenticate() -> Promise<Void> {
		let invalidTokenAuth = BoxDeveloperTokenAuth(token: "invalid")
		client = BoxClient(auth: invalidTokenAuth)
		return Promise(())
	}
}
