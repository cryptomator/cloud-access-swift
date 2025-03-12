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
import AppAuth
import Foundation
import GoogleAPIClientForREST_Drive
import Promises

public enum GoogleDriveAuthenticator {
	private static let scopes = [kGTLRAuthScopeDrive, OIDScopeEmail]
	public static var currentAuthorizationFlow: OIDExternalUserAgentSession?

	public static func authenticate(credential: GoogleDriveCredential, from viewController: UIViewController) -> Promise<Void> {
		if credential.isAuthorized {
			return Promise(())
		}
		return createAuthorizationServiceForGoogle().then { configuration in
			self.getAuthState(for: configuration, with: viewController, credential: credential)
		}.then { authState in
			try credential.save(authState: authState)
			return Promise(())
		}
	}

	private static func createAuthorizationServiceForGoogle() -> Promise<OIDServiceConfiguration> {
		let issuer = URL(string: "https://accounts.google.com")!
		return Promise<OIDServiceConfiguration> { fulfill, reject in
			OIDAuthorizationService.discoverConfiguration(forIssuer: issuer) { configuration, error in
				if error != nil {
					return reject(error!)
				}
				guard let configuration = configuration else {
					return reject(GoogleDriveError.unexpectedError) // This should never occur
				}
				fulfill(configuration)
			}
		}
	}

	private static func getAuthState(for configuration: OIDServiceConfiguration, with presentingViewController: UIViewController, credential: GoogleDriveCredential) -> Promise<OIDAuthState> {
		let request = OIDAuthorizationRequest(configuration: configuration, clientId: GoogleDriveSetup.constants.clientId, scopes: scopes, redirectURL: GoogleDriveSetup.constants.redirectURL, responseType: OIDResponseTypeCode, additionalParameters: nil)
		return Promise<OIDAuthState> { fulfill, reject in
			GoogleDriveAuthenticator.currentAuthorizationFlow = OIDAuthState.authState(byPresenting: request, presenting: presentingViewController, callback: { authState, error in
				guard let authState = authState, error == nil else {
					credential.deauthenticate()
					if let error = error as NSError? {
						if error.domain == OIDGeneralErrorDomain, error.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue || error.code == OIDErrorCode.programCanceledAuthorizationFlow.rawValue {
							return reject(CocoaError(.userCancelled))
						}
						return reject(error)
					}
					return reject(GoogleDriveError.unexpectedError) // This should never occur
				}
				fulfill(authState)
			})
		}
	}
}
