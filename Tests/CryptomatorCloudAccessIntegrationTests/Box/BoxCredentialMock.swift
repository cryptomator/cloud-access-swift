//
//  BoxCredentialMock.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Majid Achhoud on 15.04.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import BoxSdkGen
import Foundation
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class BoxCredentialMock: BoxCredential {
	init() {
		let config = CCGConfig(clientId: IntegrationTestSecrets.boxClientId, clientSecret: IntegrationTestSecrets.boxClientSecret, enterpriseId: IntegrationTestSecrets.boxEnterpriseId)
		let auth = BoxCCGAuth(config: config)
		super.init(auth: auth)
	}
}

class BoxInvalidCredentialMock: BoxCredential {
	init() {
		let auth = BoxAuthenticationMock()
		super.init(auth: auth)
	}
}
