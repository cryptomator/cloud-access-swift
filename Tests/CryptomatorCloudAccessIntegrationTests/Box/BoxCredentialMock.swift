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
		BoxSetup.constants = BoxSetup(clientId: IntegrationTestSecrets.boxClientId, clientSecret: IntegrationTestSecrets.boxClientSecret, sharedContainerIdentifier: "")
		super.init(tokenStorage: InMemoryTokenStorage())
		let config = CCGConfig(clientId: BoxSetup.constants.clientId, clientSecret: BoxSetup.constants.clientSecret, enterpriseId: IntegrationTestSecrets.boxEnterpriseId)
		let auth = BoxCCGAuth(config: config)
		client = BoxClient(auth: auth)
	}
}
