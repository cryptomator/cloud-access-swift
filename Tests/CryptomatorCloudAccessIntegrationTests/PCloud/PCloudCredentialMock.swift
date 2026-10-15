//
//  PCloudCredentialMock.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 04.03.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
@preconcurrency @testable import PCloudSDKSwift
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

/// `@unchecked Sendable`: restates the conformance of `PCloudCredential`; this subclass adds no state.
class PCloudCredentialMock: PCloudCredential, @unchecked Sendable {
	init() {
		let user = OAuth.User(id: 0, token: IntegrationTestSecrets.pCloudAccessToken, serverRegionId: 0, httpAPIHostName: IntegrationTestSecrets.pCloudHTTPAPIHostName)
		super.init(user: user)
	}
}

/// `@unchecked Sendable`: restates the conformance of `PCloudCredential`; this subclass adds no state.
class PCloudInvalidCredentialMock: PCloudCredential, @unchecked Sendable {
	init() {
		let user = OAuth.User(id: 0, token: "Foo", serverRegionId: 0, httpAPIHostName: IntegrationTestSecrets.pCloudHTTPAPIHostName)
		super.init(user: user)
	}
}
