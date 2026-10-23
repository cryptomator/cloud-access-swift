//
//  PCloudAuthenticator.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 15.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
@_spi(Authentication) import CryptomatorCloudAccessCore
#endif
import AuthenticationServices
import UIKit

public enum PCloudAuthenticatorError: Error {
	case authenticationFailed
}

/// The login that the callback URL of pCloud's authorize page passes.
struct PCloudCallback: Equatable {
	let accessToken: String
	let userID: String
	/// The host of the account's API, as the callback names it.
	let apiHostName: String
}

/// Logs in to pCloud with the OAuth 2 implicit grant in a web authentication session.
@MainActor
public enum PCloudAuthenticator {
	private nonisolated static let redirectHost = "oauth2redirect"

	/**
	 Shows pCloud's authorize page, and stores the token of the login in the setup's `oauth` under the user ID of the account.

	 Cancelling the task while the page is shown dismisses it and ends the call with `CancellationError`.

	 - Throws: `CocoaError(.userCancelled)` if the user cancelled the login, `PCloudAuthenticatorError.authenticationFailed` if the login flow failed, and otherwise what completing the authentication throws.
	 */
	public static func authenticate(from viewController: UIViewController, setup: PCloudSetup) async throws -> PCloudCredential {
		guard let window = viewController.view.window else {
			throw authenticationFailed(because: "the view controller isn't part of a window")
		}
		let appKey = setup.appKey
		let state = UUID().uuidString
		let callbackURL = try await runLoginFlow(url: authorizeURL(appKey: appKey, state: state), callbackURLScheme: redirectScheme(appKey: appKey), anchor: window)
		let callback = try callback(fromCallbackURL: callbackURL, appKey: appKey, expectedState: state)
		return try await PCloudCredential.completeAuthentication(accessToken: callback.accessToken, userID: callback.userID, apiHostName: callback.apiHostName, setup: setup)
	}

	private static func authorizeURL(appKey: String, state: String) throws -> URL {
		var components = URLComponents()
		components.scheme = "https"
		components.host = "e.pcloud.com"
		components.path = "/oauth2/authorize"
		components.queryItems = [
			URLQueryItem(name: "client_id", value: appKey),
			URLQueryItem(name: "response_type", value: "token"),
			URLQueryItem(name: "redirect_uri", value: "\(redirectScheme(appKey: appKey))://\(redirectHost)"),
			URLQueryItem(name: "state", value: state)
		]
		guard let url = components.url else {
			throw PCloudAuthenticatorError.authenticationFailed
		}
		return url
	}

	private nonisolated static func redirectScheme(appKey: String) -> String {
		return "pclsdk-w-\(appKey.lowercased())"
	}

	/// The session is ephemeral, because pCloud's authorize page approves a remembered browser login without offering to switch accounts, which would make adding another account impossible.
	private static func runLoginFlow(url: URL, callbackURLScheme: String, anchor: ASPresentationAnchor) async throws -> URL {
		return try await runWebAuthenticationSession(url: url, callbackURLScheme: callbackURLScheme, anchor: anchor, prefersEphemeralWebBrowserSession: true, logPrefix: "PCloudAuthenticator", convertError: { convertLoginFlowError($0 ?? PCloudAuthenticatorError.authenticationFailed) })
	}

	/// Reads the login from the fragment of the callback URL, which carries `access_token`, `userid`, `hostname` and the `state` of the request. Completing the authentication validates the host.
	nonisolated static func callback(fromCallbackURL callbackURL: URL, appKey: String, expectedState: String) throws -> PCloudCallback {
		guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false), components.scheme?.lowercased() == redirectScheme(appKey: appKey), components.host?.lowercased() == redirectHost else {
			throw authenticationFailed(because: "the callback URL doesn't match the redirect URI")
		}
		guard let fragment = components.percentEncodedFragment else {
			throw authenticationFailed(because: "the callback URL has no fragment")
		}
		var parameters = [String: String]()
		for pair in fragment.split(separator: "&") {
			let nameAndValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
			guard let name = nameAndValue[0].removingPercentEncoding, let value = (nameAndValue.count > 1 ? nameAndValue[1] : "").removingPercentEncoding else {
				throw authenticationFailed(because: "the fragment isn't percent-encoded")
			}
			if parameters[name] == nil {
				parameters[name] = value
			}
		}
		if parameters["error"] == "access_denied" {
			throw userCancelled()
		}
		guard parameters["error"] == nil else {
			throw authenticationFailed(because: "pCloud returned an error")
		}
		guard parameters["state"] == expectedState else {
			throw authenticationFailed(because: "the state doesn't match")
		}
		guard let accessToken = parameters["access_token"], !accessToken.isEmpty, let userID = parameters["userid"].flatMap(UInt64.init), let apiHostName = parameters["hostname"] else {
			throw authenticationFailed(because: "a field is missing or invalid")
		}
		return PCloudCallback(accessToken: accessToken, userID: String(userID), apiHostName: apiHostName)
	}

	nonisolated static func convertLoginFlowError(_ error: Error) -> Error {
		if let sessionError = error as? ASWebAuthenticationSessionError, sessionError.code == .canceledLogin {
			return userCancelled()
		} else {
			CloudAccessDDLogDebug("PCloudAuthenticator: Authentication failed with error: \(error.localizedDescription).")
			return PCloudAuthenticatorError.authenticationFailed
		}
	}

	private nonisolated static func userCancelled() -> CocoaError {
		CloudAccessDDLogDebug("PCloudAuthenticator: Login flow canceled by the user.")
		return CocoaError(.userCancelled)
	}

	private nonisolated static func authenticationFailed(because reason: String) -> PCloudAuthenticatorError {
		CloudAccessDDLogDebug("PCloudAuthenticator: Authentication failed, because \(reason).")
		return .authenticationFailed
	}
}
