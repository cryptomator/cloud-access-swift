//
//  DropboxAuthenticator.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 29.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#endif
import AuthenticationServices
import CryptoKit
import Foundation
import os
import UIKit

public enum DropboxAuthenticatorError: Error {
	case authenticationFailed
}

/// Opening the Dropbox app failed, so the login continues in a web authentication session.
private struct AppHandOffFailure: Error {}

/// A hand-off to the Dropbox app that waits for its redirect.
private struct PendingAuthentication {
	let id: UUID
	let expectedState: String
	let continuation: CheckedContinuation<URL, any Error>
}

/// The PKCE code verifier of a login, and the states of its authorize requests.
struct DropboxPKCE: Sendable {
	static let scopes = "files.metadata.read files.metadata.write files.content.read files.content.write account_info.read"
	private static let verifierCharacters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

	let codeVerifier: String
	/// The state of a web login, which only this login knows.
	let webState: String

	/// The `S256` challenge of the verifier, base64url without padding.
	var codeChallenge: String {
		return DropboxPKCE.base64URLEncoded(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
	}

	/// The state of a hand-off to the Dropbox app, which the app reads.
	var dAuthState: String {
		return "oauth2code:\(codeChallenge):S256:offline:\(DropboxPKCE.scopes)"
	}

	/// Draws the verifier and the state from `SystemRandomNumberGenerator`, which is cryptographically secure.
	static func random() -> DropboxPKCE {
		let verifier = String((0 ..< 128).map { _ in verifierCharacters[Int.random(in: 0 ..< verifierCharacters.count)] })
		let state = Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) })
		return DropboxPKCE(codeVerifier: verifier, webState: base64URLEncoded(state))
	}

	private static func base64URLEncoded(_ data: Data) -> String {
		return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
	}
}

/**
 Logs in to Dropbox with the OAuth 2 authorization code grant with PKCE: in the Dropbox app if it is installed, or else in a web authentication session.

 The app must declare `dbapi-2` and `dbapi-8-emm` in `LSApplicationQueriesSchemes` and the URL scheme `db-<app key>`, and pass the URLs that it opens to `handleRedirectURL(_:)`.
 */
@MainActor
public enum DropboxAuthenticator {
	private nonisolated static let pendingAuthentication = OSAllocatedUnfairLock<PendingAuthentication?>(initialState: nil)
	private nonisolated static let dAuthSchemes = ["dbapi-2", "dbapi-8-emm"]

	/**
	 Hands the login off to the Dropbox app, or shows Dropbox's authorize page if the app isn't installed or can't be opened, and stores the token of the login in `DropboxSetup.constants.oauth` under the `uid` of the account.

	 Only one hand-off can be pending at a time, so a new hand-off fails the previous one with `DropboxAuthenticatorError.authenticationFailed`. Cancelling the task while the hand-off is pending ends the call with `CancellationError`, because the Dropbox app may never redirect back. Cancelling it while Dropbox's authorize page is shown dismisses the page and ends the call with `CancellationError` as well.

	 - Throws: `CocoaError(.userCancelled)` if the user cancelled the login, `DropboxAuthenticatorError.authenticationFailed` if the login flow failed, `DropboxCredentialErrors.missingSetup` if `DropboxSetup.constants` isn't set, and otherwise what completing the authentication throws.
	 */
	@available(iOSApplicationExtension, unavailable)
	public static func authenticate(from viewController: UIViewController) async throws -> DropboxCredential {
		guard let window = viewController.view.window else {
			throw authenticationFailed(because: "the view controller isn't part of a window")
		}
		guard let appKey = DropboxSetup.constants?.appKey else {
			throw DropboxCredentialErrors.missingSetup
		}
		let pkce = DropboxPKCE.random()
		let (callbackURL, expectedState) = try await runLoginFlow(appKey: appKey, pkce: pkce, anchor: window)
		let authorizationCode = try authorizationCode(fromCallbackURL: callbackURL, appKey: appKey, expectedState: expectedState)
		return try await DropboxCredential.completeAuthentication(authorizationCode: authorizationCode, codeVerifier: pkce.codeVerifier)
	}

	/**
	 Completes the pending hand-off to the Dropbox app with the redirect URL that the app received.

	 A `/connect` redirect, which passes the authorization code, completes the hand-off only if it carries the hand-off's `state`. Otherwise it is ignored, e.g., as the late redirect of an earlier hand-off, and the pending hand-off keeps waiting for its own. Any other path is a cancel, which carries no `state` and completes the hand-off without a check.

	 - Returns: Whether the URL was a redirect of the Dropbox app that completed the pending hand-off.
	 */
	public static func handleRedirectURL(_ url: URL) -> Bool {
		guard let appKey = DropboxSetup.constants?.appKey, let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme?.lowercased() == redirectScheme(appKey: appKey).lowercased(), components.host == "1" else {
			return false
		}
		let isConnectRedirect = components.path == "/connect"
		let state = components.queryItems?.first(where: { $0.name == "state" })?.value
		guard let pendingAuthentication = takePendingAuthentication(where: { !isConnectRedirect || $0.expectedState == state }) else {
			CloudAccessDDLogDebug("DropboxAuthenticator: Ignored a redirect of the Dropbox app that no pending hand-off expects.")
			return false
		}
		pendingAuthentication.resume(returning: url)
		return true
	}

	@available(iOSApplicationExtension, unavailable)
	private static func runLoginFlow(appKey: String, pkce: DropboxPKCE, anchor: ASPresentationAnchor) async throws -> (callbackURL: URL, expectedState: String) {
		let dAuthURLs = try dAuthSchemes.map { try dAuthURL(scheme: $0, appKey: appKey, pkce: pkce) }
		if let dAuthURL = dAuthURLs.first(where: { UIApplication.shared.canOpenURL($0) }) {
			do {
				let callbackURL = try await awaitRedirect(expectedState: pkce.dAuthState) { fail in
					UIApplication.shared.open(dAuthURL, options: [:]) { opened in
						if !opened {
							fail(AppHandOffFailure())
						}
					}
				}
				return (callbackURL, pkce.dAuthState)
			} catch is AppHandOffFailure {
				CloudAccessDDLogDebug("DropboxAuthenticator: Opening the Dropbox app failed, continuing in the browser.")
			}
		}
		// The session is ephemeral, so that adding an account asks which account to add. Otherwise Dropbox's authorize page preselects the account that the browser remembers.
		let callbackURL = try await runWebAuthenticationSession(url: authorizeURL(appKey: appKey, pkce: pkce), callbackURLScheme: redirectScheme(appKey: appKey), anchor: anchor, prefersEphemeralWebBrowserSession: true, logPrefix: "DropboxAuthenticator", convertError: { convertLoginFlowError($0 ?? DropboxAuthenticatorError.authenticationFailed) })
		return (callbackURL, pkce.webState)
	}

	/**
	 Waits until `handleRedirectURL(_:)` passes the redirect of the Dropbox app.

	 - Parameter expectedState: The `state` of the hand-off. `handleRedirectURL(_:)` passes a `/connect` redirect only if it carries it.
	 - Parameter start: Opens the Dropbox app. It gets a function that fails this call, and only this one, e.g., if the app couldn't be opened.
	 */
	static func awaitRedirect(expectedState: String, startingWith start: (_ fail: @escaping @Sendable (Error) -> Void) -> Void) async throws -> URL {
		let id = UUID()
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				let supersededAuthentication = DropboxAuthenticator.pendingAuthentication.withLock { pendingAuthentication in
					defer { pendingAuthentication = PendingAuthentication(id: id, expectedState: expectedState, continuation: continuation) }
					return pendingAuthentication?.continuation
				}
				supersededAuthentication?.resume(throwing: DropboxAuthenticatorError.authenticationFailed)
				// The cancellation handler finds nothing to resume if it ran before the authentication was stored.
				guard !Task.isCancelled else {
					DropboxAuthenticator.takePendingAuthentication(where: { $0.id == id })?.resume(throwing: CancellationError())
					return
				}
				start { error in
					DropboxAuthenticator.takePendingAuthentication(where: { $0.id == id })?.resume(throwing: error)
				}
			}
		} onCancel: {
			DropboxAuthenticator.takePendingAuthentication(where: { $0.id == id })?.resume(throwing: CancellationError())
		}
	}

	/// Hands out the pending authentication if `matches` accepts it, at most once, so that only one of redirect, cancellation, failure and a newer authentication resumes it.
	private nonisolated static func takePendingAuthentication(where matches: @Sendable (PendingAuthentication) -> Bool) -> CheckedContinuation<URL, any Error>? {
		return pendingAuthentication.withLock { pendingAuthentication in
			guard let authentication = pendingAuthentication, matches(authentication) else {
				return nil
			}
			pendingAuthentication = nil
			return authentication.continuation
		}
	}

	// MARK: - URLs

	/// The URL that hands the login off to the Dropbox app, which reads the PKCE parameters from `extra_query_params`.
	nonisolated static func dAuthURL(scheme: String, appKey: String, pkce: DropboxPKCE) throws -> URL {
		var components = URLComponents()
		components.scheme = scheme
		components.host = "1"
		components.path = "/connect"
		components.queryItems = [
			URLQueryItem(name: "k", value: appKey),
			URLQueryItem(name: "s", value: ""),
			URLQueryItem(name: "state", value: pkce.dAuthState),
			URLQueryItem(name: "extra_query_params", value: "code_challenge=\(pkce.codeChallenge)&code_challenge_method=S256&token_access_type=offline&response_type=code&scope=\(DropboxPKCE.scopes)")
		]
		guard let url = components.url else {
			throw DropboxAuthenticatorError.authenticationFailed
		}
		return url
	}

	nonisolated static func authorizeURL(appKey: String, pkce: DropboxPKCE) throws -> URL {
		var components = URLComponents()
		components.scheme = "https"
		components.host = "www.dropbox.com"
		components.path = "/oauth2/authorize"
		components.queryItems = [
			URLQueryItem(name: "client_id", value: appKey),
			URLQueryItem(name: "redirect_uri", value: "\(redirectScheme(appKey: appKey))://2/token"),
			URLQueryItem(name: "response_type", value: "code"),
			URLQueryItem(name: "token_access_type", value: "offline"),
			URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
			URLQueryItem(name: "code_challenge_method", value: "S256"),
			URLQueryItem(name: "scope", value: DropboxPKCE.scopes),
			URLQueryItem(name: "state", value: pkce.webState),
			URLQueryItem(name: "disable_signup", value: "true")
		]
		guard let url = components.url else {
			throw DropboxAuthenticatorError.authenticationFailed
		}
		return url
	}

	private nonisolated static func redirectScheme(appKey: String) -> String {
		return "db-\(appKey)"
	}

	/**
	 Reads the authorization code from the redirect of the Dropbox app (host `1`) or of the authorize page (host `2`), which also carries the `state` of the request.

	 The Dropbox app redirects to `/connect` with `oauth_code`, or, in older versions, with `oauth_token=oauth2code:` and the code in `oauth_token_secret`. Any other path of the Dropbox app means that the user cancelled, and so do the path `/cancel` and `error=access_denied` from the authorize page.
	 */
	nonisolated static func authorizationCode(fromCallbackURL callbackURL: URL, appKey: String, expectedState: String) throws -> String {
		guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false), components.scheme?.lowercased() == redirectScheme(appKey: appKey).lowercased() else {
			throw authenticationFailed(because: "the callback URL doesn't match the redirect URI")
		}
		let queryItems = components.queryItems ?? []
		let value: (String) -> String? = { name in
			queryItems.first(where: { $0.name == name })?.value
		}
		let authorizationCode: String?
		switch (components.host ?? "", components.path) {
		case ("1", "/connect"):
			authorizationCode = value("oauth_code") ?? (value("oauth_token") == "oauth2code:" ? value("oauth_token_secret") : nil)
		case ("1", _), ("2", "/cancel"):
			throw userCancelled()
		case ("2", "/token"):
			if value("error") == "access_denied" {
				throw userCancelled()
			}
			guard value("error") == nil else {
				throw authenticationFailed(because: "Dropbox returned an error")
			}
			authorizationCode = value("code")
		default:
			throw authenticationFailed(because: "the callback URL doesn't match the redirect URI")
		}
		guard value("state") == expectedState else {
			throw authenticationFailed(because: "the state doesn't match")
		}
		guard let authorizationCode, !authorizationCode.isEmpty else {
			throw authenticationFailed(because: "the code is missing")
		}
		return authorizationCode
	}

	nonisolated static func convertLoginFlowError(_ error: Error) -> Error {
		guard let sessionError = error as? ASWebAuthenticationSessionError else {
			return error
		}
		if sessionError.code == .canceledLogin {
			return userCancelled()
		} else {
			CloudAccessDDLogDebug("DropboxAuthenticator: Authentication failed with error: \(sessionError.localizedDescription).")
			return DropboxAuthenticatorError.authenticationFailed
		}
	}

	private nonisolated static func userCancelled() -> CocoaError {
		CloudAccessDDLogDebug("DropboxAuthenticator: Login flow canceled by the user.")
		return CocoaError(.userCancelled)
	}

	private nonisolated static func authenticationFailed(because reason: String) -> DropboxAuthenticatorError {
		CloudAccessDDLogDebug("DropboxAuthenticator: Authentication failed, because \(reason).")
		return .authenticationFailed
	}
}
