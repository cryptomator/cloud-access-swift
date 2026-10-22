//
//  PCloudAuthenticator.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 15.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#endif
import AuthenticationServices
import UIKit

public enum PCloudAuthenticatorError: Error {
	case missingWindow
	case authenticationFailed
}

/// Logs in to pCloud with the OAuth 2 implicit grant in a web authentication session.
@MainActor
public final class PCloudAuthenticator {
	private nonisolated static let redirectHost = "oauth2redirect"

	public static func authenticate(from viewController: UIViewController) async throws -> PCloudCredential {
		guard let window = viewController.view.window else {
			assertionFailure("Cannot present from a view controller that is not part of the view hierarchy.")
			throw PCloudAuthenticatorError.missingWindow
		}
		let appKey = PCloudSetup.constants.appKey
		let state = UUID().uuidString
		let callbackURL = try await runLoginFlow(url: authorizeURL(appKey: appKey, state: state), callbackURLScheme: redirectScheme(appKey: appKey), anchor: window)
		return try credential(fromCallbackURL: callbackURL, appKey: appKey, expectedState: state)
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

	/// Reads the credential from the fragment of the callback URL, which carries `access_token`, `userid`, `locationid`, `hostname` and the `state` of the request.
	nonisolated static func credential(fromCallbackURL callbackURL: URL, appKey: String, expectedState: String) throws -> PCloudCredential {
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
		guard parameters["error"] == nil else {
			throw authenticationFailed(because: "pCloud returned an error")
		}
		guard parameters["state"] == expectedState else {
			throw authenticationFailed(because: "the state doesn't match")
		}
		guard let accessToken = parameters["access_token"], !accessToken.isEmpty, let userID = parameters["userid"].flatMap(UInt64.init), let locationID = parameters["locationid"].flatMap(UInt.init), let apiHostName = parameters["hostname"]?.lowercased() else {
			throw authenticationFailed(because: "a field is missing or invalid")
		}
		guard apiHostName == "pcloud.com" || apiHostName.hasSuffix(".pcloud.com"), let credential = try? PCloudCredential(id: userID, accessToken: accessToken, apiHostName: apiHostName, locationID: locationID) else {
			throw authenticationFailed(because: "the API host isn't a pCloud host name")
		}
		return credential
	}

	nonisolated static func convertLoginFlowError(_ error: Error) -> Error {
		if let sessionError = error as? ASWebAuthenticationSessionError, sessionError.code == .canceledLogin {
			CloudAccessDDLogDebug("PCloudAuthenticator: Login flow canceled by the user.")
			return CocoaError(.userCancelled)
		} else {
			CloudAccessDDLogDebug("PCloudAuthenticator: Authentication failed with error: \(error.localizedDescription).")
			return PCloudAuthenticatorError.authenticationFailed
		}
	}

	private nonisolated static func authenticationFailed(because reason: String) -> PCloudAuthenticatorError {
		CloudAccessDDLogDebug("PCloudAuthenticator: Authentication failed, because \(reason).")
		return .authenticationFailed
	}
}
