//
//  OneDriveAuthenticator.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 16.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#endif
import MSAL
import Promises
import UIKit

public enum OneDriveAuthenticatorError: Error {
	case missingAccountIdentifier
}

public enum OneDriveAuthenticator {
	public static func authenticate(from viewController: UIViewController) -> Promise<OneDriveCredential> {
		let webviewParameters = MSALWebviewParameters(authPresentationViewController: viewController)
		let interactiveParameters = MSALInteractiveTokenParameters(scopes: OneDriveCredential.scopes, webviewParameters: webviewParameters)
		return OneDriveSetup.clientApplication.acquireToken(with: interactiveParameters).then { result -> OneDriveCredential in
			guard let identifier = result.account.identifier else {
				throw OneDriveAuthenticatorError.missingAccountIdentifier
			}
			return try OneDriveCredential(with: identifier)
		}
	}
}

private extension MSALPublicClientApplication {
	func acquireToken(with interactiveParameters: MSALInteractiveTokenParameters) -> Promise<MSALResult> {
		return Promise<MSALResult> { fulfill, reject in
			self.acquireToken(with: interactiveParameters) { result, error in
				switch (result, error) {
				case let (.some(result), nil):
					fulfill(result)
				case let (_, .some(error)):
					reject(error)
				default:
					reject(OneDriveError.unexpectedResult)
				}
			}
		}
	}
}
