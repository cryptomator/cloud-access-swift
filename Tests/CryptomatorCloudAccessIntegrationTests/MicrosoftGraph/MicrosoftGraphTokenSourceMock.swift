//
//  MicrosoftGraphTokenSourceMock.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 20.05.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

enum MicrosoftGraphTokenSourceMockError: Error {
	case tokenRequestFailed(statusCode: Int)
}

final class MicrosoftGraphTokenSourceMock: BearerTokenSource {
	private let lockedOverrideAccessToken = OSAllocatedUnfairLock<String?>(initialState: nil)
	var overrideAccessToken: String? {
		get { lockedOverrideAccessToken.withLock { $0 } }
		set { lockedOverrideAccessToken.withLock { $0 = newValue } }
	}

	/// The request for the access token, shared by concurrent callers so that the refresh token is redeemed once.
	private let lockedAccessTokenTask = OSAllocatedUnfairLock<Task<String, Error>?>(initialState: nil)

	func accessToken() async throws -> String {
		if let overrideAccessToken {
			return overrideAccessToken
		}
		let accessTokenTask = lockedAccessTokenTask.withLock { accessTokenTask in
			if let accessTokenTask {
				return accessTokenTask
			}
			let newAccessTokenTask = Task { try await self.requestAccessToken() }
			accessTokenTask = newAccessTokenTask
			return newAccessTokenTask
		}
		do {
			return try await accessTokenTask.value
		} catch {
			lockedAccessTokenTask.withLock { lockedTask in
				if lockedTask == accessTokenTask {
					lockedTask = nil
				}
			}
			throw error
		}
	}

	/// A token that was invalidated stays invalid, so that a refresh can't hand an unauthorized provider a valid token.
	func refresh(rejecting accessToken: String) async throws -> String {
		guard overrideAccessToken == nil else {
			throw CloudProviderError.unauthorized
		}
		return try await self.accessToken()
	}

	private func requestAccessToken() async throws -> String {
		let (data, response) = try await URLSession.shared.data(for: getAccessTokenRequest())
		let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
		guard statusCode == 200 else {
			throw MicrosoftGraphTokenSourceMockError.tokenRequestFailed(statusCode: statusCode)
		}
		return try getAccessTokenResponse(from: data).accessToken
	}

	private func getAccessTokenRequest() -> URLRequest {
		let url = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
		components.queryItems = [
			URLQueryItem(name: "client_id", value: IntegrationTestSecrets.microsoftGraphClientId),
			URLQueryItem(name: "scope", value: "https://graph.microsoft.com/Files.ReadWrite"),
			URLQueryItem(name: "refresh_token", value: IntegrationTestSecrets.microsoftGraphRefreshToken),
			URLQueryItem(name: "redirect_uri", value: IntegrationTestSecrets.microsoftGraphRedirectUri),
			URLQueryItem(name: "grant_type", value: "refresh_token")
		]
		request.httpBody = Data(components.url!.query!.utf8)
		return request
	}

	private func getAccessTokenResponse(from data: Data) throws -> AccessTokenResponse {
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		return try decoder.decode(AccessTokenResponse.self, from: data)
	}
}

struct AccessTokenResponse: Codable {
	let accessToken: String
}
