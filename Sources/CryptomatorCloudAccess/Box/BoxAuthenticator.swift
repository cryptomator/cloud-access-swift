//
//  BoxAuthenticator.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 18.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import AuthenticationServices
@_spi(Authentication) import CryptomatorCloudAccessCore
import UIKit

public enum BoxAuthenticatorError: Error {
	case authenticationFailed
}

/// Logs in to Box with the OAuth 2 authorization code grant in a web authentication session.
@MainActor
public enum BoxAuthenticator {
	private nonisolated static let redirectHost = "boxsdkoauth2redirect"
	private nonisolated static let loginCallback = WebLoginCallback(logPrefix: "BoxAuthenticator", failure: BoxAuthenticatorError.authenticationFailed)

	/**
	 Shows Box's authorize page, and stores the token of the login in the setup's `oauth` under the user ID of the account.

	 Cancelling the task while the authorize page is shown dismisses it and ends the call with `CancellationError`.

	 - Throws: `CocoaError(.userCancelled)` if the user cancelled the login, `BoxAuthenticatorError.authenticationFailed` if the login flow failed, and otherwise what completing the authentication throws.
	 */
	public static func authenticate(from viewController: UIViewController, setup: BoxSetup) async throws -> BoxCredential {
		guard let window = viewController.view.window else {
			throw loginCallback.authenticationFailed(because: "the view controller isn't part of a window")
		}
		let clientID = setup.clientID
		let state = UUID().uuidString
		let callbackURL = try await runLoginFlow(url: authorizeURL(clientID: clientID, state: state), callbackURLScheme: redirectScheme(clientID: clientID), anchor: window)
		let authorizationCode = try authorizationCode(fromCallbackURL: callbackURL, clientID: clientID, expectedState: state)
		return try await BoxCredential.completeAuthentication(authorizationCode: authorizationCode, setup: setup)
	}

	private static func authorizeURL(clientID: String, state: String) throws -> URL {
		var components = URLComponents()
		components.scheme = "https"
		components.host = "account.box.com"
		components.path = "/api/oauth2/authorize"
		components.queryItems = [
			URLQueryItem(name: "client_id", value: clientID),
			URLQueryItem(name: "response_type", value: "code"),
			URLQueryItem(name: "redirect_uri", value: "\(redirectScheme(clientID: clientID))://\(redirectHost)"),
			URLQueryItem(name: "state", value: state)
		]
		guard let url = components.url else {
			throw BoxAuthenticatorError.authenticationFailed
		}
		return url
	}

	private nonisolated static func redirectScheme(clientID: String) -> String {
		return "boxsdk-\(clientID)"
	}

	/// The session is shared with the browser, which lets the user sign in to another account on Box's authorize page.
	private static func runLoginFlow(url: URL, callbackURLScheme: String, anchor: ASPresentationAnchor) async throws -> URL {
		return try await runWebAuthenticationSession(url: url, callbackURLScheme: callbackURLScheme, anchor: anchor, prefersEphemeralWebBrowserSession: false, logPrefix: loginCallback.logPrefix, convertError: { convertLoginFlowError($0 ?? loginCallback.failure) })
	}

	/// Reads the authorization code from the query of the callback URL if its `state` matches the request's. An `error` of `access_denied`, which means that the user denied access, throws `CocoaError(.userCancelled)`.
	nonisolated static func authorizationCode(fromCallbackURL callbackURL: URL, clientID: String, expectedState: String) throws -> String {
		let components = try loginCallback.components(ofCallbackURL: callbackURL, scheme: redirectScheme(clientID: clientID), host: redirectHost)
		let queryItems = components.queryItems ?? []
		let value: (String) -> String? = { name in
			queryItems.first(where: { $0.name == name })?.value
		}
		try loginCallback.checkError(value("error"), providerName: "Box")
		try loginCallback.checkState(value("state"), expected: expectedState)
		guard let authorizationCode = value("code"), !authorizationCode.isEmpty else {
			throw loginCallback.authenticationFailed(because: "the code is missing")
		}
		return authorizationCode
	}

	nonisolated static func convertLoginFlowError(_ error: Error) -> Error {
		return loginCallback.convertSessionError(error) ?? error
	}
}
