//
//  MSAuthenticationProviderMock.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 20.05.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import MSGraphClientSDK
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

enum MSAuthenticationProviderMockError: Error {
	case invalidRefreshToken
}

class MSAuthenticationProviderMock: NSObject, MSAuthenticationProvider {
	var overrideAccessToken: String?
	var accessToken: String?

	func getAccessToken(for authProviderOptions: MSAuthenticationProviderOptions!, andCompletion completion: ((String?, Error?) -> Void)!) {
		if let accessToken = overrideAccessToken {
			completion(accessToken, nil)
			return
		} else if let accessToken = accessToken {
			completion(accessToken, nil)
			return
		}
		let request = getAccessTokenRequest()
		URLSession.shared.performDataTask(with: request).then { response, data -> String in
			guard response.statusCode == 200, let data = data else {
				throw MSAuthenticationProviderMockError.invalidRefreshToken
			}
			let accessTokenResponse = try self.getAccessTokenResponse(from: data)
			return accessTokenResponse.accessToken
		}.then { accessToken in
			self.overrideAccessToken = accessToken
			self.accessToken = accessToken
			completion(accessToken, nil)
		}.catch { error in
			completion(nil, error)
		}
	}

	private func getAccessTokenRequest() -> URLRequest {
		let url = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
		components.queryItems = [
			URLQueryItem(name: "client_id", value: IntegrationTestSecrets.oneDriveClientId),
			URLQueryItem(name: "scope", value: "https://graph.microsoft.com/Files.ReadWrite"),
			URLQueryItem(name: "refresh_token", value: IntegrationTestSecrets.oneDriveRefreshToken),
			URLQueryItem(name: "redirect_uri", value: IntegrationTestSecrets.oneDriveRedirectUri),
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
