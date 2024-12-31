//
//  MicrosoftGraphCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 16.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import MSAL
import MSGraphClientSDK
import Promises

public enum MicrosoftGraphCredentialError: Error {
	case noUsername
}

public class MicrosoftGraphCredential {
	public let identifier: String
	public let scopes: [String]
	let authProvider: MSAuthenticationProvider
	private let clientApplication: MSALPublicClientApplication

	public convenience init(identifier: String, scopes: [String]) {
		let authProvider = MicrosoftGraphAuthenticationProvider(identifier: identifier, clientApplication: MicrosoftGraphSetup.constants.clientApplication, scopes: scopes)
		self.init(identifier: identifier, scopes: scopes, authProvider: authProvider, clientApplication: MicrosoftGraphSetup.constants.clientApplication)
	}

	init(identifier: String, scopes: [String], authProvider: MSAuthenticationProvider, clientApplication: MSALPublicClientApplication) {
		self.identifier = identifier
		self.scopes = scopes
		self.authProvider = authProvider
		self.clientApplication = clientApplication
	}

	public func getUsername() throws -> String {
		let account = try clientApplication.account(forIdentifier: identifier)
		guard let username = account.username else {
			throw MicrosoftGraphCredentialError.noUsername
		}
		return username
	}

	public func deauthenticate() throws {
		let account = try clientApplication.account(forIdentifier: identifier)
		try clientApplication.remove(account)
	}
}

public extension MicrosoftGraphCredential {
	static func createForOneDrive(with identifier: String) -> MicrosoftGraphCredential {
		return MicrosoftGraphCredential(identifier: identifier, scopes: MicrosoftGraphScopes.oneDrive)
	}

	static func createForSharePoint(with identifier: String) -> MicrosoftGraphCredential {
		return MicrosoftGraphCredential(identifier: identifier, scopes: MicrosoftGraphScopes.sharePoint)
	}
}
