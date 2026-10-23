//
//  GoogleDriveAuthenticator.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 24.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
@_spi(Authentication) import CryptomatorCloudAccessCore
#endif
@preconcurrency import AppAuth
import Foundation

public enum GoogleDriveAuthenticatorError: Error {
	case authenticationFailed
	/// The user didn't grant access to Google Drive on Google's consent screen.
	case driveAccessNotGranted
}

/// The tokens of a finished login flow and the scopes that the user granted.
struct GoogleDriveLogin: Sendable {
	let accessToken: String?
	let refreshToken: String?
	let expiresAt: Date?
	let idToken: String?
	/// The granted scopes, separated by spaces.
	let scope: String?
}

extension GoogleDriveLogin {
	init(authState: OIDAuthState) {
		self.init(accessToken: authState.lastTokenResponse?.accessToken, refreshToken: authState.refreshToken, expiresAt: authState.lastTokenResponse?.accessTokenExpirationDate, idToken: authState.lastTokenResponse?.idToken, scope: authState.scope)
	}
}

/// Logs in to Google with AppAuth's authorization code flow with PKCE.
@MainActor
public enum GoogleDriveAuthenticator {
	private nonisolated static let driveScope = "https://www.googleapis.com/auth/drive"
	private static let scopes = [driveScope, OIDScopeEmail]

	/**
	 Shows Google's sign-in page, and stores the token of the login in the setup's `oauth` under the user ID of the account. A failed or cancelled login changes no stored login.

	 Cancelling the task while the sign-in page is shown dismisses it and ends the call with `CancellationError`.

	 - Throws: `CocoaError(.userCancelled)` if the user cancelled the login, `GoogleDriveAuthenticatorError.authenticationFailed` if Google returned no complete token, `GoogleDriveAuthenticatorError.driveAccessNotGranted` if the user didn't grant access to Google Drive, and otherwise what the login flow or completing the authentication throws.
	 */
	public static func authenticate(from viewController: UIViewController, setup: GoogleDriveSetup) async throws -> GoogleDriveCredential {
		let configuration = try await createAuthorizationServiceForGoogle()
		let request = OIDAuthorizationRequest(configuration: configuration, clientId: setup.clientID, scopes: scopes, redirectURL: setup.redirectURL, responseType: OIDResponseTypeCode, additionalParameters: nil)
		let login = try await runLoginFlow { callback in
			let flow = OIDAuthState.authState(byPresenting: request, presenting: viewController, callback: { @Sendable authState, error in
				callback(authState.map(GoogleDriveLogin.init(authState:)), error)
			})
			return { flow.cancel() }
		}
		guard let accessToken = login.accessToken, let refreshToken = login.refreshToken, let idToken = login.idToken else {
			CloudAccessDDLogDebug("GoogleDriveAuthenticator: Authentication failed, because the token response is incomplete.")
			throw GoogleDriveAuthenticatorError.authenticationFailed
		}
		guard grantsDriveAccess(login.scope) else {
			CloudAccessDDLogDebug("GoogleDriveAuthenticator: Authentication failed, because the granted scopes \(login.scope ?? "nil") lack Google Drive.")
			throw GoogleDriveAuthenticatorError.driveAccessNotGranted
		}
		return try await GoogleDriveCredential.completeAuthentication(accessToken: accessToken, refreshToken: refreshToken, expiresAt: login.expiresAt, idToken: idToken, setup: setup)
	}

	private static func createAuthorizationServiceForGoogle() async throws -> OIDServiceConfiguration {
		let issuer = URL(string: "https://accounts.google.com")!
		return try await withCheckedThrowingContinuation { continuation in
			OIDAuthorizationService.discoverConfiguration(forIssuer: issuer) { @Sendable configuration, error in
				if error != nil {
					return continuation.resume(throwing: error!)
				}
				guard let configuration else {
					return continuation.resume(throwing: GoogleDriveAuthenticatorError.authenticationFailed)
				}
				continuation.resume(returning: configuration)
			}
		}
	}

	/**
	 Runs the login flow that `startFlow` starts, and waits until it completes or the task is cancelled. Cancelling the task cancels the flow, which dismisses its page, and ends the call with `CancellationError`.

	 - Parameter startFlow: Starts the flow with its callback, and returns the function that cancels the flow.
	 */
	static func runLoginFlow(startingWith startFlow: @escaping @MainActor (_ callback: @escaping @Sendable (GoogleDriveLogin?, Error?) -> Void) -> @MainActor () -> Void) async throws -> GoogleDriveLogin {
		return try await runWebAuthenticationSession(logPrefix: "GoogleDriveAuthenticator", convertError: { convertLoginFlowError($0 ?? GoogleDriveAuthenticatorError.authenticationFailed) }, makeSession: { completion in
			SDKLoginSession {
				startFlow(completion)
			}
		})
	}

	/// Google lets the user leave out scopes on its consent screen, and returns the granted ones separated by spaces.
	nonisolated static func grantsDriveAccess(_ grantedScopes: String?) -> Bool {
		return grantedScopes?.split(separator: " ").contains { $0 == driveScope } ?? false
	}

	nonisolated static func convertLoginFlowError(_ error: Error) -> Error {
		let nsError = error as NSError
		if nsError.domain == OIDGeneralErrorDomain, nsError.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue || nsError.code == OIDErrorCode.programCanceledAuthorizationFlow.rawValue {
			CloudAccessDDLogDebug("GoogleDriveAuthenticator: Login flow canceled.")
			return CocoaError(.userCancelled)
		}
		if nsError.domain == OIDOAuthAuthorizationErrorDomain, nsError.code == OIDErrorCodeOAuth.accessDenied.rawValue {
			CloudAccessDDLogDebug("GoogleDriveAuthenticator: Access denied by the user.")
			return CocoaError(.userCancelled)
		}
		return error
	}
}
