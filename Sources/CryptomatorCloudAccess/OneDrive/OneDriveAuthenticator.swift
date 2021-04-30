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
		webviewParameters.webviewType = .safariViewController
		let interactiveParameters = MSALInteractiveTokenParameters(scopes: OneDriveCredential.scopes, webviewParameters: webviewParameters)
		return Promise<OneDriveCredential> { fulfill, reject in
			OneDriveSetup.clientApplication.acquireToken(with: interactiveParameters) { result, error in
				if let error = error {
					reject(error)
					return
				}
				guard let result = result, let identifier = result.account.identifier else {
					reject(OneDriveAuthenticatorError.missingAccountIdentifier)
					return
				}
				do {
					let credential = try OneDriveCredential(with: identifier)
					fulfill(credential)
				} catch {
					reject(error)
				}
			}
		}
	}
}
