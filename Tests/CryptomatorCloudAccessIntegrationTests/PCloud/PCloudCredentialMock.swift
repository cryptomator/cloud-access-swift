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
		return try PCloudCredential(userID: "IntegrationTest", tokenSource: StaticOAuthTokenSource(token: IntegrationTestSecrets.pCloudAccessToken, apiHost: integrationTestAPIHost()))
	}

	static func integrationTestInvalid() throws -> PCloudCredential {
		return try PCloudCredential(userID: "IntegrationTest", tokenSource: StaticOAuthTokenSource(token: "Foo", apiHost: integrationTestAPIHost()))
	}

	private static func integrationTestAPIHost() throws -> String {
		guard let apiHost = apiHost(IntegrationTestSecrets.pCloudHTTPAPIHostName) else {
			throw URLError(.badURL)
		}
		return apiHost
	}
}
