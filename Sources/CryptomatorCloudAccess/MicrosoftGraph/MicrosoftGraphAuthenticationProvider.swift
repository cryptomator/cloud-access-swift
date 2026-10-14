//
//  MicrosoftGraphAuthenticationProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 23.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
@preconcurrency import MSAL
@preconcurrency import MSGraphClientSDK

enum MicrosoftGraphAuthenticationProviderError: Error {
	case accountNotFound
}

final class MicrosoftGraphAuthenticationProvider: NSObject, MSAuthenticationProvider, Sendable {
	private let identifier: String
	private let clientApplication: MSALPublicClientApplication
	private let scopes: [String]

	init(identifier: String, clientApplication: MSALPublicClientApplication, scopes: [String]) {
		self.identifier = identifier
		self.clientApplication = clientApplication
		self.scopes = scopes
	}

	func getAccessToken(for authProviderOptions: MSAuthenticationProviderOptions!, andCompletion completion: (@Sendable (String?, Error?) -> Void)!) {
		let scopes: [String] = if let authProviderOptions {
			authProviderOptions.scopesArray
		} else {
			self.scopes
		}

		// MSAL is called on the main actor, because it doesn't document that it may be called from any thread.
		Task { @MainActor in
			do {
				let parameters = MSALAccountEnumerationParameters(identifier: identifier)
				guard let account = try await clientApplication.accountsFromDevice(for: parameters).first else {
					throw MicrosoftGraphAuthenticationProviderError.accountNotFound
				}
				let tokenParameters = MSALSilentTokenParameters(scopes: scopes, account: account)
				let result = try await clientApplication.acquireTokenSilent(with: tokenParameters)
				completion(result.accessToken, nil)
			} catch let error as NSError where error.domain == MSALErrorDomain && error.code == MSALError.interactionRequired.rawValue {
				completion(nil, CloudProviderError.unauthorized)
			} catch {
				completion(nil, error)
			}
		}
	}
}
