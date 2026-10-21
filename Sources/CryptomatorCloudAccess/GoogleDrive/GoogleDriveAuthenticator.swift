//
//  GoogleDriveAuthenticator.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 24.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#endif
@preconcurrency import AppAuth
import Foundation

public enum GoogleDriveAuthenticatorError: Error {
	case authenticationFailed
	/// The user didn't grant access to Google Drive on Google's consent screen.
	case driveAccessNotGranted
}

/// Logs in to Google with AppAuth's authorization code flow with PKCE.
@MainActor
public enum GoogleDriveAuthenticator {
	private nonisolated static let driveScope = "https://www.googleapis.com/auth/drive"
	private static let scopes = [driveScope, OIDScopeEmail]
	/// The running login flow, which the app resumes with the redirect URL.
	public static var currentAuthorizationFlow: OIDExternalUserAgentSession?

	/**
	 Shows Google's sign-in page, and stores the token of the login in `GoogleDriveSetup.constants.oauth` under the user ID of the account. A failed or cancelled login changes no stored login.

	 - Throws: `CocoaError(.userCancelled)` if the user cancelled the login, `GoogleDriveAuthenticatorError.authenticationFailed` if Google returned no complete token, `GoogleDriveAuthenticatorError.driveAccessNotGranted` if the user didn't grant access to Google Drive, `GoogleDriveCredentialError.missingSetup` if `GoogleDriveSetup.constants` isn't set, and otherwise what the login flow or completing the authentication throws.
	 */
	public static func authenticate(from viewController: UIViewController) async throws -> GoogleDriveCredential {
		guard let setup = GoogleDriveSetup.constants else {
			throw GoogleDriveCredentialError.missingSetup
		}
		let configuration = try await createAuthorizationServiceForGoogle()
		let authState = try await getAuthState(for: configuration, clientId: setup.clientId, redirectURL: setup.redirectURL, with: viewController)
		guard let tokenResponse = authState.lastTokenResponse, let accessToken = tokenResponse.accessToken, let refreshToken = authState.refreshToken, let idToken = tokenResponse.idToken else {
			CloudAccessDDLogDebug("GoogleDriveAuthenticator: Authentication failed, because the token response is incomplete.")
			throw GoogleDriveAuthenticatorError.authenticationFailed
		}
		guard grantsDriveAccess(authState.scope) else {
			CloudAccessDDLogDebug("GoogleDriveAuthenticator: Authentication failed, because the granted scopes \(authState.scope ?? "nil") lack Google Drive.")
			throw GoogleDriveAuthenticatorError.driveAccessNotGranted
		}
		return try await GoogleDriveCredential.completeAuthentication(accessToken: accessToken, refreshToken: refreshToken, expiresAt: tokenResponse.accessTokenExpirationDate, idToken: idToken)
	}

	private static func createAuthorizationServiceForGoogle() async throws -> OIDServiceConfiguration {
		let issuer = URL(string: "https://accounts.google.com")!
		return try await withCheckedThrowingContinuation { continuation in
			OIDAuthorizationService.discoverConfiguration(forIssuer: issuer) { @Sendable configuration, error in
				if error != nil {
					return continuation.resume(throwing: error!)
				}
				guard let configuration else {
					return continuation.resume(throwing: GoogleDriveError.unexpectedError) // This should never occur
				}
				continuation.resume(returning: configuration)
			}
		}
	}

	private static func getAuthState(for configuration: OIDServiceConfiguration, clientId: String, redirectURL: URL, with presentingViewController: UIViewController) async throws -> OIDAuthState {
		let request = OIDAuthorizationRequest(configuration: configuration, clientId: clientId, scopes: scopes, redirectURL: redirectURL, responseType: OIDResponseTypeCode, additionalParameters: nil)
		return try await withCheckedThrowingContinuation { continuation in
			GoogleDriveAuthenticator.currentAuthorizationFlow = OIDAuthState.authState(byPresenting: request, presenting: presentingViewController, callback: { @Sendable authState, error in
				guard let authState, error == nil else {
					return continuation.resume(throwing: convertLoginFlowError(error ?? GoogleDriveError.unexpectedError))
				}
				continuation.resume(returning: authState)
			})
		}
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
		return error
	}
}
