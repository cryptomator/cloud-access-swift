//
//  MicrosoftGraphAuthenticator.swift
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

public enum MicrosoftGraphAuthenticatorError: Error {
	case missingAccountIdentifier
}

public class MicrosoftGraphAuthenticator {
	public static func authenticate(from viewController: UIViewController, with scopes: [String]) -> Promise<MicrosoftGraphCredential> {
		let webviewParameters = MSALWebviewParameters(authPresentationViewController: viewController)
		let interactiveParameters = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: webviewParameters)
		interactiveParameters.promptType = .login
		return MicrosoftGraphSetup.constants.clientApplication.acquireToken(with: interactiveParameters).then { result -> MicrosoftGraphCredential in
			guard let identifier = result.account.identifier else {
				throw MicrosoftGraphAuthenticatorError.missingAccountIdentifier
			}
			return MicrosoftGraphCredential(identifier: identifier, scopes: scopes)
		}
	}

	public static func authenticate(from viewController: UIViewController, for type: MicrosoftGraphType) -> Promise<MicrosoftGraphCredential> {
		return authenticate(from: viewController, with: type.scopes)
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
					reject(MicrosoftGraphError.unexpectedResult)
				}
			}
		}
	}
}
