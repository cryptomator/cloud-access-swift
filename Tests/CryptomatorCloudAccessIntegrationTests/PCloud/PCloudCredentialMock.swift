//
//  PCloudCredentialMock.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 04.03.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
@testable import PCloudSDKSwift
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class PCloudCredentialMock: PCloudCredential {
	init() {
		let user = OAuth.User(id: 0, token: IntegrationTestSecrets.pCloudAccessToken, serverRegionId: 0, httpAPIHostName: IntegrationTestSecrets.pCloudHTTPAPIHostName)
		super.init(user: user)
	}
}

class PCloudInvalidCredentialMock: PCloudCredential {
	init() {
		let user = OAuth.User(id: 0, token: "Foo", serverRegionId: 0, httpAPIHostName: IntegrationTestSecrets.pCloudHTTPAPIHostName)
		super.init(user: user)
	}
}
