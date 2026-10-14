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
@preconcurrency import BoxSdkGen
import UIKit

public enum BoxAuthenticatorError: Error {
	case authenticationFailed
	case invalidContext
}

@MainActor
public enum BoxAuthenticator {
	public static func authenticate(from viewController: UIViewController, tokenStorage: TokenStorage) async throws -> BoxCredential {
		guard let context = viewController as? UIViewController & ASWebAuthenticationPresentationContextProviding else {
			throw BoxAuthenticatorError.invalidContext
		}
		let config = OAuthConfig(clientId: BoxSetup.constants.clientId, clientSecret: BoxSetup.constants.clientSecret, tokenStorage: tokenStorage)
		let oauth = BoxOAuth(config: config)
		do {
			// Awaited in a task that doesn't inherit cancellation, because the Box SDK would otherwise return before its request has terminated.
			try await _Concurrency.Task { _ = try await oauth.runLoginFlow(options: .init(), context: context) }.value // access token is implicitly saved in token storage
		} catch {
			throw convertLoginFlowError(error)
		}
		return BoxCredential(tokenStorage: tokenStorage)
	}

	static func convertLoginFlowError(_ error: Error) -> Error {
		// The Box SDK wraps the error of its web authentication session.
		guard let sessionError = (error as? BoxSDKError)?.error as? ASWebAuthenticationSessionError else {
			return error
		}
		if sessionError.code == .canceledLogin {
			CloudAccessDDLogDebug("BoxAuthenticator: Login flow canceled by the user.")
			return CocoaError(.userCancelled)
		} else {
			CloudAccessDDLogDebug("BoxAuthenticator: Authentication failed with error: \(sessionError.localizedDescription).")
			return BoxAuthenticatorError.authenticationFailed
		}
	}
}
