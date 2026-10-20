//
//  BoxTokenSource.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// Supplies the access token of the requests of `BoxClient`.
protocol BoxTokenSource: Sendable {
	func accessToken() async throws -> String
	/// Returns a token that replaces the rejected one.
	func refresh(rejecting accessToken: String) async throws -> String
	func deauthenticate() async throws
}

/// The token of a Box login, which the app's `OAuthTokenStorage` keeps and `OAuthTokenStore` refreshes.
final class BoxOAuthTokenSource: BoxTokenSource {
	private let store: OAuthTokenStore
	private let endpoint: BoxOAuthEndpoint

	init(userID: String, tokenStorage: any OAuthTokenStorage, lockDirectory: URL, endpoint: BoxOAuthEndpoint, assertion: ProcessExecutionAssertion = ProcessExecutionAssertion()) {
		self.store = OAuthTokenStore(provider: "box", account: userID, storage: tokenStorage, lockDirectory: lockDirectory, legacyDecoder: BoxLegacyToken.decode, refresher: { token in
			try await endpoint.refresh(token)
		}, assertion: assertion)
		self.endpoint = endpoint
	}

	func accessToken() async throws -> String {
		return try await store.accessToken()
	}

	func refresh(rejecting accessToken: String) async throws -> String {
		return try await store.refresh(rejecting: accessToken)
	}

	func replace(with token: OAuthToken) async throws {
		try await store.replace(with: token)
	}

	func deauthenticate() async throws {
		let endpoint = endpoint
		try await store.delete(revoking: { token in
			try await endpoint.revoke(token)
		})
	}
}

/// The token of a login that isn't stored yet, for the request that reads the user ID.
struct BoxStaticTokenSource: BoxTokenSource {
	let token: String

	func accessToken() async throws -> String {
		return token
	}

	func refresh(rejecting accessToken: String) async throws -> String {
		throw CloudProviderError.unauthorized
	}

	func deauthenticate() async throws {}
}

/**
 Sends the requests of Box's OAuth endpoints: the code exchange, the refresh grant and the revocation.

 Their bodies carry the client secret and the tokens, so they are never logged. Their timeouts bound how long a refresh holds the token lock.
 */
struct BoxOAuthEndpoint: Sendable {
	private let clientId: String
	private let clientSecret: String
	private let session: SplitURLSession
	private let now: @Sendable () -> Date

	init(clientId: String, clientSecret: String, configuration: URLSessionConfiguration = BoxOAuthEndpoint.defaultConfiguration(), now: @escaping @Sendable () -> Date = Date.init) {
		self.clientId = clientId
		self.clientSecret = clientSecret
		self.session = SplitURLSession(configuration: configuration)
		self.now = now
	}

	init(setup: BoxSetup) {
		self.init(clientId: setup.clientId, clientSecret: setup.clientSecret)
	}

	static func defaultConfiguration() -> URLSessionConfiguration {
		let configuration = HTTPClientSupport.hardened(.default)
		configuration.timeoutIntervalForRequest = 15
		configuration.timeoutIntervalForResource = 20
		return configuration
	}

	func exchange(authorizationCode: String) async throws -> OAuthToken {
		return try await token(for: [("grant_type", "authorization_code"), ("code", authorizationCode)])
	}

	/// - Throws: `CloudProviderError.unauthorized` if the token has no refresh token, or Box rejected it.
	func refresh(_ token: OAuthToken) async throws -> OAuthToken {
		guard let refreshToken = token.refreshToken else {
			throw CloudProviderError.unauthorized
		}
		return try await self.token(for: [("grant_type", "refresh_token"), ("refresh_token", refreshToken)])
	}

	func revoke(_ token: OAuthToken) async throws {
		_ = try await post("/oauth2/revoke", parameters: [("client_id", clientId), ("client_secret", clientSecret), ("token", token.accessToken)])
	}

	func token(for grant: [(String, String)]) async throws -> OAuthToken {
		let body = try await post("/oauth2/token", parameters: grant + [("client_id", clientId), ("client_secret", clientSecret)])
		let response = try BoxJSON.decode(BoxTokenResponse.self, from: body)
		return OAuthToken(accessToken: response.accessToken, refreshToken: response.refreshToken, expiresAt: response.expiresIn.map { now().addingTimeInterval(TimeInterval($0)) })
	}

	/// - Throws: `CloudProviderError.unauthorized` for a 400 with `invalid_grant`, and `BoxError.apiError` with the `error` and `error_description` of any other unsuccessful response.
	private func post(_ path: String, parameters: [(String, String)]) async throws -> Data {
		var components = URLComponents()
		components.scheme = "https"
		components.host = "api.box.com"
		components.path = path
		guard let url = components.url else {
			throw URLError(.badURL)
		}
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
		request.httpBody = Data(HTTPClientSupport.formEncoded(parameters).utf8)
		let outcome = try await session.data(request, bodyLimit: nil, bodyLogging: .omitted)
		do {
			let httpResponse = try HTTPClientSupport.httpResponse(of: outcome)
			guard (200 ... 299).contains(httpResponse.statusCode) else {
				let errorResponse = outcome.data.flatMap { try? JSONDecoder().decode(BoxErrorResponse.self, from: $0) }
				if httpResponse.statusCode == 400, errorResponse?.error == "invalid_grant" {
					throw CloudProviderError.unauthorized
				}
				throw BoxError.apiError(statusCode: httpResponse.statusCode, code: errorResponse?.error, message: errorResponse?.errorDescription)
			}
			return outcome.data ?? Data()
		} catch {
			CloudAccessDDLogDebug("BoxOAuthEndpoint: \(path) failed with \(error)")
			throw isNetworkConnectionError(error) ? CloudProviderError.noInternetConnection : error
		}
	}
}
