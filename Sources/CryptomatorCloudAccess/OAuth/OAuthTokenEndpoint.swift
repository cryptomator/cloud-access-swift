//
//  OAuthTokenEndpoint.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// A token endpoint's failure that isn't a rejected grant, so that it isn't read as a failure of the provider's API.
public enum OAuthTokenEndpointError: Error, Equatable {
	/// The endpoint answered with an unsuccessful status, and the `error` and `error_description` of its body.
	case unsuccessfulResponse(statusCode: Int, error: String?, errorDescription: String?)
}

/// The successful response of a token endpoint (RFC 6749, section 5.1).
struct OAuthTokenResponse: Decodable, Sendable {
	let accessToken: String
	let refreshToken: String?
	let expiresIn: Int64?

	private enum CodingKeys: String, CodingKey {
		case accessToken = "access_token"
		case refreshToken = "refresh_token"
		case expiresIn = "expires_in"
	}

	/// - Parameter fallbackRefreshToken: The refresh token to keep if the response has none.
	func token(now: Date, fallbackRefreshToken: String? = nil) -> OAuthToken {
		return OAuthToken(accessToken: accessToken, refreshToken: refreshToken ?? fallbackRefreshToken, expiresAt: expiresIn.map { now.addingTimeInterval(TimeInterval($0)) })
	}
}

/// The error response of a token endpoint (RFC 6749, section 5.2).
private struct OAuthTokenErrorResponse: Decodable {
	let error: String?
	let errorDescription: String?

	private enum CodingKeys: String, CodingKey {
		case error
		case errorDescription = "error_description"
	}
}

enum OAuthTokenEndpoint {
	/**
	 Posts the form parameters to the endpoint and returns the body of its successful response. The bodies carry tokens, so they are never logged.

	 - Throws: `CloudProviderError.unauthorized` for a 400 with `invalid_grant`, `CloudProviderError.noInternetConnection` without a connection, and `OAuthTokenEndpointError` for any other unsuccessful response.
	 */
	static func post(_ parameters: [(String, String)], host: String, path: String, on session: SplitURLSession) async throws -> Data {
		var components = URLComponents()
		components.scheme = "https"
		components.host = host
		components.path = path
		guard let url = components.url else {
			throw URLError(.badURL)
		}
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
		request.httpBody = Data(HTTPClientSupport.formEncoded(parameters).utf8)
		let outcome = try await session.data(request, bodyLimit: HTTPClientSupport.maxMetadataBodyLength, bodyLogging: .omitted)
		do {
			let httpResponse = try HTTPClientSupport.httpResponse(of: outcome)
			guard (200 ... 299).contains(httpResponse.statusCode) else {
				let errorResponse = outcome.data.flatMap { try? JSONDecoder().decode(OAuthTokenErrorResponse.self, from: $0) }
				if httpResponse.statusCode == 400, errorResponse?.error == "invalid_grant" {
					throw CloudProviderError.unauthorized
				}
				throw OAuthTokenEndpointError.unsuccessfulResponse(statusCode: httpResponse.statusCode, error: errorResponse?.error, errorDescription: errorResponse?.errorDescription)
			}
			return outcome.data ?? Data()
		} catch {
			CloudAccessDDLogDebug("OAuthTokenEndpoint: POST \(host)\(path) failed with \(error)")
			throw isNetworkConnectionError(error) ? CloudProviderError.noInternetConnection : error
		}
	}
}
