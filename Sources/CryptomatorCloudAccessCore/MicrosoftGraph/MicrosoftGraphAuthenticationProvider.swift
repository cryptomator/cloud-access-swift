//
//  MicrosoftGraphAuthenticationProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 23.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
@preconcurrency import MSAL

final class MicrosoftGraphAuthenticationProvider: BearerTokenSource {
	private let identifier: String
	private let clientApplication: MSALPublicClientApplication
	private let scopes: [String]

	init(identifier: String, clientApplication: MSALPublicClientApplication, scopes: [String]) {
		self.identifier = identifier
		self.clientApplication = clientApplication
		self.scopes = scopes
	}

	func accessToken() async throws -> String {
		return try await acquireTokenSilently(forceRefresh: false)
	}

	/// Asks MSAL for a new token instead of the cached one, which Graph rejected.
	func refresh(rejecting accessToken: String) async throws -> String {
		return try await acquireTokenSilently(forceRefresh: true)
	}

	/// MSAL is called on the main actor, because it doesn't document that it may be called from any thread.
	@MainActor
	private func acquireTokenSilently(forceRefresh: Bool) async throws -> String {
		do {
			let parameters = MSALAccountEnumerationParameters(identifier: identifier)
			guard let account = try await clientApplication.accountsFromDevice(for: parameters).first else {
				throw CloudProviderError.unauthorized
			}
			let tokenParameters = MSALSilentTokenParameters(scopes: scopes, account: account)
			tokenParameters.forceRefresh = forceRefresh
			return try await clientApplication.acquireTokenSilent(with: tokenParameters).accessToken
		} catch let error as NSError where error.domain == MSALErrorDomain && error.code == MSALError.interactionRequired.rawValue {
			throw CloudProviderError.unauthorized
		}
	}
}
