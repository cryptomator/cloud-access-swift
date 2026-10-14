//
//  BoxCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 19.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import AuthenticationServices
@preconcurrency import BoxSdkGen
import Foundation

public enum BoxCredentialErrors: Error {
	case noUsername
}

/// `@unchecked Sendable`: `client` is immutable and each of its requests is an independent async call. The class is subclassed in tests.
public class BoxCredential: @unchecked Sendable {
	let client: BoxClient

	init(auth: Authentication) {
		self.client = BoxClient(auth: auth)
	}

	public convenience init(tokenStorage: TokenStorage) {
		let config = OAuthConfig(clientId: BoxSetup.constants.clientId, clientSecret: BoxSetup.constants.clientSecret, tokenStorage: tokenStorage)
		let auth = BoxOAuth(config: config)
		self.init(auth: auth)
	}

	public func deauthenticate() async throws {
		try await withBoxSDKCancellationShield { try await self.client.auth.revokeToken(networkSession: nil) }
	}

	public func getUsername() async throws -> String {
		let user = try await withBoxSDKCancellationShield { try await self.client.users.getUserMe() }
		guard let name = user.name else {
			throw BoxCredentialErrors.noUsername
		}
		return name
	}

	public func getUserID() async throws -> String {
		let user = try await withBoxSDKCancellationShield { try await self.client.users.getUserMe() }
		return user.id
	}
}
