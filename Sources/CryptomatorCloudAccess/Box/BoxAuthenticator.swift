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
import BoxSdkGen
import Promises
import UIKit

public enum BoxAuthenticatorError: Error {
	case authenticationFailed
	case invalidContext
}

public enum BoxAuthenticator {
	public static func authenticate(from viewController: UIViewController, tokenStorage: TokenStorage) -> Promise<BoxCredential> {
		let pendingPromise = Promise<BoxCredential>.pending()

		_Concurrency.Task {
			do {
				guard let context = viewController as? ASWebAuthenticationPresentationContextProviding else {
					throw BoxAuthenticatorError.invalidContext
				}

				let config = OAuthConfig(clientId: BoxSetup.constants.clientId, clientSecret: BoxSetup.constants.clientSecret)
				let oauth = BoxOAuth(config: config)

				// Run the login flow and store the access token using tokenStorage
				try await oauth.runLoginFlow(options: .init(), context: context)
				// TODO: Catch error when login failed

				pendingPromise.fulfill(BoxCredential(tokenStore: tokenStorage))
			} catch {
				pendingPromise.reject(BoxAuthenticatorError.authenticationFailed)
			}
		}

		return pendingPromise
	}
}
