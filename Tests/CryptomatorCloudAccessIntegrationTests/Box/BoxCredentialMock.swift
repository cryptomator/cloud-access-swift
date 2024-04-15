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
	let tokenStore: MemoryTokenStore

	init() {
		BoxSetup.constants = BoxSetup(clientId: "", clientSecret: "", sharedContainerIdentifier: "")
		self.tokenStore = MemoryTokenStore()
		tokenStore.tokenInfo = TokenInfo(accessToken: IntegrationTestSecrets.boxAccessToken, refreshToken: IntegrationTestSecrets.boxRefreshToken, expiresIn: 3600, tokenType: "bearer")
		super.init(tokenStore: tokenStore)
	}

	override func deauthenticate() -> Promise<Void> {
		tokenStore.tokenInfo = TokenInfo(accessToken: "invalid", expiresIn: 0)
		return Promise(())
	}
}
