//
//  BoxCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 19.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import AuthenticationServices
import BoxSDK
import Foundation
import Promises

public enum BoxCredentialErrors: Error {
	case noUsername
}

public class BoxCredential {
	public internal(set) var client: BoxClient?

	public init(tokenStore: TokenStore) {
		let sdk = BoxSDK(clientId: BoxSetup.constants.clientId, clientSecret: BoxSetup.constants.clientSecret)
		sdk.getOAuth2Client(tokenStore: tokenStore) { result in
			switch result {
			case let .success(client):
				self.client = client
			case let .failure:
				break
			}
		}
	}

	public func deauthenticate() -> Promise<Void> {
		return Promise<Void> { fulfill, reject in
			self.client?.destroy { result in
				switch result {
				case .success:
					fulfill(())
				case let .failure(error):
					reject(error)
				}
			}
		}
	}

	public func getUsername() -> Promise<String> {
		return Promise<String>(on: .global()) { fulfill, reject in
			self.client?.users.getCurrent(fields: ["name"]) { result in
				switch result {
				case let .success(user):
					if let name = user.name {
						fulfill(name)
					} else {
						reject(BoxCredentialErrors.noUsername)
					}
				case let .failure(error):
					reject(error)
				}
			}
		}
	}
}
