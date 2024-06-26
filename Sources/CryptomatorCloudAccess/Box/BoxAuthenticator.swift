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
	case loginCancelled
}

public enum BoxAuthenticator {
	public static func authenticate(from viewController: UIViewController, tokenStorage: TokenStorage) -> Promise<BoxCredential> {
		let pendingPromise = Promise<BoxCredential>.pending()

		_Concurrency.Task {
			do {
				guard let context = viewController as? ASWebAuthenticationPresentationContextProviding else {
					throw BoxAuthenticatorError.invalidContext
				}

				let config = OAuthConfig(clientId: BoxSetup.constants.clientId, clientSecret: BoxSetup.constants.clientSecret, tokenStorage: tokenStorage)
				let oauth = BoxOAuth(config: config)

				// Run the login flow and store the access token using tokenStorage
				try await oauth.runLoginFlow(options: .init(), context: context)

				pendingPromise.fulfill(BoxCredential(tokenStorage: tokenStorage))
			} catch let error as ASWebAuthenticationSessionError {
				if error.code == .canceledLogin {
					// Handle the login cancellation
					CloudAccessDDLogDebug("BoxAuthenticator: Login flow cancelled by the user.")
					pendingPromise.reject(BoxAuthenticatorError.loginCancelled)
				} else {
					// Handle other authentication errors
					CloudAccessDDLogDebug("BoxAuthenticator: Authentication failed with error: \(error.localizedDescription).")
					pendingPromise.reject(BoxAuthenticatorError.authenticationFailed)
				}
			}
		}

		return pendingPromise
	}
}
