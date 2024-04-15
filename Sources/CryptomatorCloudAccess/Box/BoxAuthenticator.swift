//
//  BoxAuthenticator.swift
//
//
//  Created by Majid Achhoud on 18.03.24.
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
}

public enum BoxAuthenticator {
	public static let sdk = BoxSDK(clientId: BoxSetup.constants.clientId, clientSecret: BoxSetup.constants.clientSecret)

	public static func authenticate(from viewController: UIViewController, tokenStore: TokenStore) -> Promise<(BoxClient, String)> {
		return Promise { fulfill, reject in
			sdk.getOAuth2Client(tokenStore: tokenStore, context: viewController as! ASWebAuthenticationPresentationContextProviding) { result in
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
