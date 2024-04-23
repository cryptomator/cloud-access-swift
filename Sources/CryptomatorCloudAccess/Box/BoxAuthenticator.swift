//
//  BoxAuthenticator.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 18.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#endif
import AuthenticationServices
import BoxSDK
import Promises
import UIKit

public enum BoxAuthenticatorError: Error {
	case authenticationFailed
	case invalidContext
}

public enum BoxAuthenticator {
	public static let sdk = BoxSDK(clientId: BoxSetup.constants.clientId, clientSecret: BoxSetup.constants.clientSecret)

	public static func authenticate(from viewController: UIViewController, tokenStore: TokenStore) -> Promise<(BoxClient, String)> {
		return Promise { fulfill, reject in

			guard let context = viewController as? ASWebAuthenticationPresentationContextProviding else {
				reject(BoxAuthenticatorError.invalidContext)
				return
			}

			sdk.getOAuth2Client(tokenStore: tokenStore, context: context) { result in
				switch result {
				case let .success(client):
					client.users.getCurrent(fields: ["id"]) { userResult in
						switch userResult {
						case let .success(user):
							fulfill((client, user.id))
						case .failure:
							reject(BoxAuthenticatorError.authenticationFailed)
						}
					}
				case .failure:
					reject(BoxAuthenticatorError.authenticationFailed)
				}
			}
		}
	}
}
