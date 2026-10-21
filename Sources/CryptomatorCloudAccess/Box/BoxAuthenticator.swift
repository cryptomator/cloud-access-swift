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
import UIKit

public enum BoxAuthenticatorError: Error {
	case authenticationFailed
}

/// Logs in to Box with the OAuth 2 authorization code grant in a web authentication session.
@MainActor
public enum BoxAuthenticator {
	private nonisolated static let redirectHost = "boxsdkoauth2redirect"

	/**
	 Shows Box's authorize page, and stores the token of the login in `BoxSetup.constants.oauth` under the user ID of the account.

	 - Throws: `CocoaError(.userCancelled)` if the user cancelled the login, `BoxAuthenticatorError.authenticationFailed` if the login flow failed, `BoxCredentialErrors.missingSetup` if `BoxSetup.constants` isn't set, and otherwise what completing the authentication throws.
	 */
	public static func authenticate(from viewController: UIViewController) async throws -> BoxCredential {
		guard let window = viewController.view.window else {
			throw authenticationFailed(because: "the view controller isn't part of a window")
		}
		guard let clientId = BoxSetup.constants?.clientId else {
			throw BoxCredentialErrors.missingSetup
		}
		let state = UUID().uuidString
		let callbackURL = try await runLoginFlow(url: authorizeURL(clientId: clientId, state: state), callbackURLScheme: redirectScheme(clientId: clientId), anchor: window)
		let authorizationCode = try authorizationCode(fromCallbackURL: callbackURL, clientId: clientId, expectedState: state)
		return try await BoxCredential.completeAuthentication(authorizationCode: authorizationCode)
	}

	private static func authorizeURL(clientId: String, state: String) throws -> URL {
		var components = URLComponents()
		components.scheme = "https"
		components.host = "account.box.com"
		components.path = "/api/oauth2/authorize"
		components.queryItems = [
			URLQueryItem(name: "client_id", value: clientId),
			URLQueryItem(name: "response_type", value: "code"),
			URLQueryItem(name: "redirect_uri", value: "\(redirectScheme(clientId: clientId))://\(redirectHost)"),
			URLQueryItem(name: "state", value: state)
		]
		guard let url = components.url else {
			throw BoxAuthenticatorError.authenticationFailed
		}
		return url
	}

	private nonisolated static func redirectScheme(clientId: String) -> String {
		return "boxsdk-\(clientId)"
	}

	/// The session is shared with the browser, which lets the user sign in to another account on Box's authorize page.
	private static func runLoginFlow(url: URL, callbackURLScheme: String, anchor: ASPresentationAnchor) async throws -> URL {
		return try await runWebAuthenticationSession(url: url, callbackURLScheme: callbackURLScheme, anchor: anchor, prefersEphemeralWebBrowserSession: false, logPrefix: "BoxAuthenticator", convertError: { convertLoginFlowError($0 ?? BoxAuthenticatorError.authenticationFailed) })
	}

	/// Reads the authorization code from the query of the callback URL, which also carries the `state` of the request, or an `error` if the user denied access.
	nonisolated static func authorizationCode(fromCallbackURL callbackURL: URL, clientId: String, expectedState: String) throws -> String {
		guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false), components.scheme?.lowercased() == redirectScheme(clientId: clientId).lowercased(), components.host?.lowercased() == redirectHost else {
			throw authenticationFailed(because: "the callback URL doesn't match the redirect URI")
		}
		let queryItems = components.queryItems ?? []
		let value: (String) -> String? = { name in
			queryItems.first(where: { $0.name == name })?.value
		}
		guard value("error") == nil else {
			throw authenticationFailed(because: "Box returned an error")
		}
		guard value("state") == expectedState else {
			throw authenticationFailed(because: "the state doesn't match")
		}
		guard let authorizationCode = value("code"), !authorizationCode.isEmpty else {
			throw authenticationFailed(because: "the code is missing")
		}
		return authorizationCode
	}

	nonisolated static func convertLoginFlowError(_ error: Error) -> Error {
		guard let sessionError = error as? ASWebAuthenticationSessionError else {
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

	private nonisolated static func authenticationFailed(because reason: String) -> BoxAuthenticatorError {
		CloudAccessDDLogDebug("BoxAuthenticator: Authentication failed, because \(reason).")
		return .authenticationFailed
	}
}
