//
//  BoxCredential.swift
//
//
//  Created by Majid Achhoud on 19.03.24.
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
			case let .failure(error):
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
		return Promise<String> { fulfill, reject in
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
