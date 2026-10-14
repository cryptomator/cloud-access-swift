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
@preconcurrency import MSAL
import UIKit

public enum MicrosoftGraphAuthenticatorError: Error {
	case missingAccountIdentifier
	case serverDeclinedScopes
}

@MainActor
public final class MicrosoftGraphAuthenticator {
	public static func authenticate(from viewController: UIViewController, with scopes: [String]) async throws -> MicrosoftGraphCredential {
		let webviewParameters = MSALWebviewParameters(authPresentationViewController: viewController)
		let interactiveParameters = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: webviewParameters)
		interactiveParameters.promptType = .login
		do {
			let result = try await MicrosoftGraphSetup.constants.clientApplication.acquireToken(with: interactiveParameters)
			guard let identifier = result.account.identifier else {
				throw MicrosoftGraphAuthenticatorError.missingAccountIdentifier
			}
			return MicrosoftGraphCredential(identifier: identifier, scopes: scopes)
		} catch {
			if let error = error as NSError?, error.domain == MSALErrorDomain {
				if error.code == MSALError.serverDeclinedScopes.rawValue {
					throw MicrosoftGraphAuthenticatorError.serverDeclinedScopes
				} else if error.code == MSALError.userCanceled.rawValue {
					throw CocoaError(.userCancelled)
				}
			}
			throw error
		}
	}

	public static func authenticate(from viewController: UIViewController, for type: MicrosoftGraphType) async throws -> MicrosoftGraphCredential {
		return try await authenticate(from: viewController, with: type.scopes)
	}
}
