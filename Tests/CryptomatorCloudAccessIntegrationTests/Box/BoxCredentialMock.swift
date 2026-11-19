//
//  BoxCredentialMock.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Majid Achhoud on 15.04.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation
@testable import CryptomatorCloudAccessCore

extension BoxCredential {
	static func integrationTest() -> BoxCredential {
		return BoxCredential(userID: "IntegrationTest", tokenSource: ClientCredentialsTokenSource(fetchToken: fetchIntegrationTestToken))
	}

	static func integrationTestInvalid() -> BoxCredential {
		return BoxCredential(userID: "IntegrationTest-Invalid", tokenSource: InvalidOAuthTokenSource())
	}

	/// Gets a token of the test enterprise's service account.
	///
	/// - Throws: `OAuthTokenEndpointError` for an unsuccessful response, so that a server error counts as transient.
	@Sendable private static func fetchIntegrationTestToken() async throws -> String {
		let endpoint = try BoxOAuthEndpoint(clientID: IntegrationTestSecrets.boxClientId, clientSecret: IntegrationTestSecrets.boxClientSecret)
		return try await endpoint.token(for: [("grant_type", "client_credentials"), ("box_subject_type", "enterprise"), ("box_subject_id", IntegrationTestSecrets.boxEnterpriseId)]).accessToken
	}
}
