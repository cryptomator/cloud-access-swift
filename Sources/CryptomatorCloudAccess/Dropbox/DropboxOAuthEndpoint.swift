//
//  DropboxOAuthEndpoint.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Sends the requests of Dropbox's OAuth endpoints: the code exchange, the refresh grant and the revocation. A PKCE login has no client secret.

 Their bodies carry the tokens, so they are never logged. Their timeouts bound how long a refresh holds the token lock.
 */
struct DropboxOAuthEndpoint: Sendable {
	private static let host = "api.dropboxapi.com"

	private let appKey: String
	private let session: SplitURLSession
	private let now: @Sendable () -> Date

	init(appKey: String, configuration: URLSessionConfiguration = HTTPClientSupport.tokenEndpointConfiguration(), now: @escaping @Sendable () -> Date = Date.init) {
		self.appKey = appKey
		self.session = SplitURLSession(configuration: configuration)
		self.now = now
	}

	init(setup: DropboxSetup) {
		self.init(appKey: setup.appKey)
	}

	/// The `redirect_uri` of the web login, which the code exchange sends for either login flow. `DropboxAuthenticator.authorizeURL(appKey:pkce:)` builds the same string, because its module can't call this.
	static func redirectURI(appKey: String) -> String {
		return "db-\(appKey)://2/token"
	}

	/**
	 Exchanges the authorization code of a login.

	 - Returns: The token and the `uid` of the account.
	 - Throws: `DropboxCredentialErrors.missingUserID` if the response has no `uid`, `DropboxError.unexpectedContent` if it has no refresh token, `CloudProviderError.unauthorized` if Dropbox rejected the code, and `OAuthTokenEndpointError` for any other unsuccessful response.
	 */
	func exchange(code: String, codeVerifier: String) async throws -> (token: OAuthToken, userID: String) {
		let body = try await OAuthTokenEndpoint.post([("grant_type", "authorization_code"), ("code", code), ("code_verifier", codeVerifier), ("client_id", appKey), ("redirect_uri", DropboxOAuthEndpoint.redirectURI(appKey: appKey))], host: DropboxOAuthEndpoint.host, path: "/oauth2/token", on: session)
		let token = try DropboxJSON.decode(OAuthTokenResponse.self, from: body).token(now: now())
		guard let userID = try DropboxJSON.decode(DropboxAccountID.self, from: body).uid, !userID.isEmpty else {
			throw DropboxCredentialErrors.missingUserID
		}
		guard token.refreshToken != nil else {
			throw DropboxError.unexpectedContent
		}
		return (token, userID)
	}

	/**
	 Returns the refreshed token. Dropbox leaves the refresh token out of the response, so the refreshed token keeps the old one.

	 - Throws: `CloudProviderError.unauthorized` if the token has no refresh token or Dropbox rejected it, and `OAuthTokenEndpointError` for any other unsuccessful response.
	 */
	func refresh(_ token: OAuthToken) async throws -> OAuthToken {
		guard let refreshToken = token.refreshToken else {
			throw CloudProviderError.unauthorized
		}
		let body = try await OAuthTokenEndpoint.post([("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", appKey)], host: DropboxOAuthEndpoint.host, path: "/oauth2/token", on: session)
		return try DropboxJSON.decode(OAuthTokenResponse.self, from: body).token(now: now(), fallbackRefreshToken: refreshToken)
	}

	/**
	 Revokes the login's tokens: the access token sent, its refresh token and every other access token of that refresh token.

	 A token with a refresh token is refreshed first, because Dropbox rejects an expired access token, whatever its stored expiry says. The refreshed token isn't stored, because the login was deleted already. A login whose refresh token Dropbox rejects, or whose access token it reports as invalid, is revoked already.

	 - Throws: `DropboxError.apiError` for an unsuccessful status other than a 401 `invalid_access_token`, e.g., for an expired access token or a suspended account, `CloudProviderError.noInternetConnection` or the transport error if the revocation request fails, and otherwise what the refresh throws.
	 */
	func revoke(_ token: OAuthToken) async throws {
		var accessToken = token.accessToken
		if token.refreshToken != nil {
			do {
				accessToken = try await refresh(token).accessToken
			} catch CloudProviderError.unauthorized {
				return
			}
		}
		var request = try DropboxClient.rpcRequest("auth/token/revoke", body: Data("null".utf8))
		request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
		let outcome = try await session.data(request, bodyLimit: nil, bodyLogging: .omitted)
		do {
			let response = try HTTPClientSupport.httpResponse(of: outcome)
			if response.statusCode == 401, DropboxErrorResponse.tags(of: DropboxErrorResponse.decode(from: outcome.data)?.errorSummary).first == "invalid_access_token" {
				return
			}
			guard (200 ... 299).contains(response.statusCode) else {
				throw DropboxClient.apiError(of: response, outcome)
			}
		} catch {
			CloudAccessDDLogDebug("DropboxOAuthEndpoint: POST \(request.url?.path ?? "") failed with \(error)")
			throw isNetworkConnectionError(error) ? CloudProviderError.noInternetConnection : error
		}
	}
}
