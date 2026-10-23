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

/// Logs in to a Microsoft account with MSAL's interactive token acquisition.
@MainActor
public enum MicrosoftGraphAuthenticator {
	/**
	 Shows Microsoft's sign-in sheet for the scopes of the account type.

	 Cancelling the task while the sheet is shown dismisses it and ends the call with `CancellationError`.

	 - Throws: `CocoaError(.userCancelled)` if the user cancelled the login, `MicrosoftGraphAuthenticatorError` if the login didn't grant the scopes or named no account, and otherwise MSAL's error.
	 */
	public static func authenticate(from viewController: UIViewController, for type: MicrosoftGraphType, setup: MicrosoftGraphSetup) async throws -> MicrosoftGraphCredential {
		let webviewParameters = MSALWebviewParameters(authPresentationViewController: viewController)
		let interactiveParameters = MSALInteractiveTokenParameters(scopes: type.scopes, webviewParameters: webviewParameters)
		interactiveParameters.promptType = .login
		let identifier = try await acquireAccountIdentifier(acquire: { completion in
			setup.clientApplication.acquireToken(with: interactiveParameters) { result, error in
				completion(result?.account.identifier, error)
			}
		}, cancel: {
			_ = MSALPublicClientApplication.cancelCurrentWebAuthSession()
		})
		return MicrosoftGraphCredential(identifier: identifier, type: type, setup: setup)
	}

	/**
	 Runs the token acquisition that `acquire` starts, and waits until it completes or the task is cancelled. Cancelling the task calls `cancel`, which dismisses MSAL's sheet, and ends the call with `CancellationError`.

	 - Parameter acquire: Starts the acquisition with its completion, which gets the identifier of the account or else the error.
	 */
	static func acquireAccountIdentifier(acquire: @escaping @MainActor (_ completion: @escaping @Sendable (String?, Error?) -> Void) -> Void, cancel: @escaping @MainActor () -> Void) async throws -> String {
		return try await runWebAuthenticationSession(logPrefix: "MicrosoftGraphAuthenticator", convertError: convertLoginFlowError) { completion in
			SDKLoginSession {
				acquire(completion)
				return cancel
			}
		}
	}

	nonisolated static func convertLoginFlowError(_ error: Error?) -> Error {
		guard let error = error as NSError?, error.domain == MSALErrorDomain else {
			return error ?? MicrosoftGraphAuthenticatorError.missingAccountIdentifier
		}
		if error.code == MSALError.serverDeclinedScopes.rawValue {
			return MicrosoftGraphAuthenticatorError.serverDeclinedScopes
		} else if error.code == MSALError.userCanceled.rawValue {
			CloudAccessDDLogDebug("MicrosoftGraphAuthenticator: Login flow canceled by the user.")
			return CocoaError(.userCancelled)
		}
		return error
	}
}
