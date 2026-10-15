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
@preconcurrency import GoogleAPIClientForREST_Drive

@MainActor
public enum GoogleDriveAuthenticator {
	private static let scopes = [kGTLRAuthScopeDrive, OIDScopeEmail]
	public static var currentAuthorizationFlow: OIDExternalUserAgentSession?

	public static func authenticate(credential: GoogleDriveCredential, from viewController: UIViewController) async throws {
		if credential.isAuthorized {
			return
		}
		let configuration = try await createAuthorizationServiceForGoogle()
		let authState = try await getAuthState(for: configuration, with: viewController, credential: credential)
		try credential.save(authState: authState)
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

	private static func getAuthState(for configuration: OIDServiceConfiguration, with presentingViewController: UIViewController, credential: GoogleDriveCredential) async throws -> OIDAuthState {
		let request = OIDAuthorizationRequest(configuration: configuration, clientId: GoogleDriveSetup.constants.clientId, scopes: scopes, redirectURL: GoogleDriveSetup.constants.redirectURL, responseType: OIDResponseTypeCode, additionalParameters: nil)
		return try await withCheckedThrowingContinuation { continuation in
			GoogleDriveAuthenticator.currentAuthorizationFlow = OIDAuthState.authState(byPresenting: request, presenting: presentingViewController, callback: { @Sendable authState, error in
				guard let authState, error == nil else {
					credential.deauthenticate()
					if let error = error as NSError? {
						if error.domain == OIDGeneralErrorDomain, error.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue || error.code == OIDErrorCode.programCanceledAuthorizationFlow.rawValue {
							return continuation.resume(throwing: CocoaError(.userCancelled))
						}
						return continuation.resume(throwing: error)
					}
					return continuation.resume(throwing: GoogleDriveError.unexpectedError) // This should never occur
				}
				continuation.resume(returning: authState)
			})
		}
	}
}
