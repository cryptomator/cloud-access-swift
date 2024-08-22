//
//  BoxCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 19.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import AuthenticationServices
import BoxSdkGen
import Foundation
import Promises

public enum BoxCredentialErrors: Error {
	case noUsername
}

public class BoxCredential {
	var auth: Authentication
	var client: BoxClient

	public init(tokenStorage: TokenStorage) {
		let config = OAuthConfig(clientId: BoxSetup.constants.clientId, clientSecret: BoxSetup.constants.clientSecret, tokenStorage: tokenStorage)
		self.auth = BoxOAuth(config: config)
		self.client = BoxClient(auth: auth)
	}

	public func deauthenticate() -> Promise<Void> {
		let pendingPromise = Promise<Void>.pending()
		_Concurrency.Task {
			do {
				let networkSession = NetworkSession()
				try await self.client.auth.revokeToken(networkSession: networkSession)
				pendingPromise.fulfill(())
			} catch {
				pendingPromise.reject(error)
			}
		}
		return pendingPromise
	}

	public func getUsername() -> Promise<String> {
		let pendingPromise = Promise<String>.pending()
		_Concurrency.Task {
			do {
				let user = try await client.users.getUserMe()
				if let name = user.name {
					pendingPromise.fulfill(name)
				} else {
					pendingPromise.reject(BoxCredentialErrors.noUsername)
				}
			} catch {
				pendingPromise.reject(error)
			}
		}
		return pendingPromise
	}

	public func getUserID() -> Promise<String> {
		let pendingPromise = Promise<String>.pending()
		_Concurrency.Task {
			do {
				let user = try await client.users.getUserMe()
				pendingPromise.fulfill(user.id)
			} catch {
				pendingPromise.reject(error)
			}
		}
		return pendingPromise
	}
}
