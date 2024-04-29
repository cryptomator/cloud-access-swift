//
//  BoxCredentialMock.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Majid Achhoud on 15.04.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises
@testable import BoxSDK
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class BoxCredentialMock: BoxCredential {
	init() {
		BoxSetup.constants = BoxSetup(clientId: "", clientSecret: "", sharedContainerIdentifier: "")
		super.init(tokenStore: MemoryTokenStore())
		client = BoxSDK.getClient(token: IntegrationTestSecrets.boxDeveloperToken)
	}

	override func deauthenticate() -> Promise<Void> {
		client = BoxSDK.getClient(token: "invalid")
		return Promise(())
	}
}
