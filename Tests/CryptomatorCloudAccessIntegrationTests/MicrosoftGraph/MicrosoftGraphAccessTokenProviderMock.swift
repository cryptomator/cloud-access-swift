//
//  MicrosoftGraphAccessTokenProviderMock.swift
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

enum MicrosoftGraphAccessTokenProviderMockError: Error {
	case invalidRefreshToken
}

final class MicrosoftGraphAccessTokenProviderMock: MicrosoftGraphAccessTokenProvider {
	private let lockedOverrideAccessToken = OSAllocatedUnfairLock<String?>(initialState: nil)
	var overrideAccessToken: String? {
		get { lockedOverrideAccessToken.withLock { $0 } }
		set { lockedOverrideAccessToken.withLock { $0 = newValue } }
	}

	private let lockedAccessToken = OSAllocatedUnfairLock<String?>(initialState: nil)
	var accessToken: String? {
		get { lockedAccessToken.withLock { $0 } }
		set { lockedAccessToken.withLock { $0 = newValue } }
	}

	func getAccessToken() async throws -> String {
		if let accessToken = overrideAccessToken ?? accessToken {
			return accessToken
		}
		let (data, response) = try await URLSession.shared.data(for: getAccessTokenRequest())
		guard (response as? HTTPURLResponse)?.statusCode == 200 else {
			throw MicrosoftGraphAccessTokenProviderMockError.invalidRefreshToken
		}
		let accessTokenResponse = try getAccessTokenResponse(from: data)
		overrideAccessToken = accessTokenResponse.accessToken
		accessToken = accessTokenResponse.accessToken
		return accessTokenResponse.accessToken
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
