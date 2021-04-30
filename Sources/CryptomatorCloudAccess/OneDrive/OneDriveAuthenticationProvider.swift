//
//  OneDriveAuthenticationProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 23.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import MSAL
import MSGraphClientSDK
import Promises

enum OneDriveAuthenticationProviderError: Error {
	case noAccounts
	case accountNotFound
	case invalidAuthProviderOptions
}

class OneDriveAuthenticationProvider: NSObject, MSAuthenticationProvider {
	private let identifier: String
	private let clientApplication: MSALPublicClientApplication
	private let authProviderOptions: MSAuthenticationProviderOptions

	init(identifier: String, clientApplication: MSALPublicClientApplication, authProviderOptions: MSAuthenticationProviderOptions) {
		self.identifier = identifier
		self.clientApplication = clientApplication
		self.authProviderOptions = authProviderOptions
	}

	func getAccessToken(for authProviderOptions: MSAuthenticationProviderOptions!, andCompletion completion: ((String?, Error?) -> Void)!) {
		let scopes: [String]
		if let authProviderOptions = authProviderOptions {
			scopes = authProviderOptions.scopesArray
		} else {
			scopes = self.authProviderOptions.scopesArray
		}

		let parameters = MSALAccountEnumerationParameters(identifier: identifier)
		clientApplication.accountsFromDevice(for: parameters).then { accounts -> Promise<MSALResult> in
			guard let account = accounts.first else {
				return Promise(OneDriveAuthenticationProviderError.accountNotFound)
			}
			let tokenParameters = MSALSilentTokenParameters(scopes: scopes, account: account)
			return self.clientApplication.acquireTokenSilent(with: tokenParameters)
		}.recover { error -> MSALResult in
			switch error {
			case let error as NSError where error.domain == MSALErrorDomain && error.code == MSALError.interactionRequired.rawValue:
				throw CloudProviderError.unauthorized
			default:
				throw error
			}
		}
		.then { result in
			completion(result.accessToken, nil)
		}.catch { error in
			completion(nil, error)
		}
	}
}

private extension MSALPublicClientApplication {
	func accountsFromDevice(for parameters: MSALAccountEnumerationParameters) -> Promise<[MSALAccount]> {
		return Promise<[MSALAccount]> { fulfill, reject in
			self.accountsFromDevice(for: parameters) { accounts, error in
				switch (accounts, error) {
				case let (.some(accounts), nil):
					fulfill(accounts)
				case let (_, .some(error)):
					reject(error)
				default:
					reject(OneDriveAuthenticationProviderError.noAccounts)
				}
			}
		}
	}

	func acquireTokenSilent(with tokenParameters: MSALSilentTokenParameters) -> Promise<MSALResult> {
		return Promise<MSALResult> { fulfill, reject in
			self.acquireTokenSilent(with: tokenParameters) { result, error in
				switch (result, error) {
				case let (.some(result), nil):
					fulfill(result)
				case let (_, .some(error)):
					reject(error)
				default:
					reject(OneDriveError.unexpectedResult)
				}
			}
		}
	}
}
