//
//  PCloudCredentialMock.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 04.03.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

extension PCloudCredential {
	static func integrationTest() throws -> PCloudCredential {
		return try PCloudCredential(id: 0, accessToken: IntegrationTestSecrets.pCloudAccessToken, apiHostName: IntegrationTestSecrets.pCloudHTTPAPIHostName, locationID: 0)
	}

	static func integrationTestInvalid() throws -> PCloudCredential {
		return try PCloudCredential(id: 0, accessToken: "Foo", apiHostName: IntegrationTestSecrets.pCloudHTTPAPIHostName, locationID: 0)
	}
}
