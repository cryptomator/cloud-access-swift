//
//  BoxAuthenticationMock.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 21.08.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import BoxSdkGen
import Foundation

class BoxAuthenticationMock: Authentication {
	func retrieveToken(networkSession: NetworkSession?) async throws -> AccessToken {
		return AccessToken()
	}

	func refreshToken(networkSession: NetworkSession?) async throws -> AccessToken {
		return AccessToken()
	}

	func retrieveAuthorizationHeader(networkSession: NetworkSession?) async throws -> String {
		return ""
	}

	func revokeToken(networkSession: NetworkSession?) async throws {
		// do nothing
	}

	func downscopeToken(scopes: [String], resource: String?, sharedLink: String?, networkSession: BoxSdkGen.NetworkSession?) async throws -> AccessToken {
		return AccessToken()
	}
}
