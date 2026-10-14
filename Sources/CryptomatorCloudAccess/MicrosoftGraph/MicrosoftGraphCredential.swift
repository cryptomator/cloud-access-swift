//
//  MicrosoftGraphCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 16.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
@preconcurrency import MSAL
@preconcurrency import MSGraphClientSDK

public enum MicrosoftGraphCredentialError: Error {
	case noUsername
}

/// `@unchecked Sendable`: all stored properties are immutable. `authProvider` is only called by the HTTP clients it is handed to, and `clientApplication` only for the account lookups of `getUsername()` and `deauthenticate()`. The class is subclassed in tests.
public class MicrosoftGraphCredential: @unchecked Sendable {
	public let identifier: String
	public let scopes: [String]
	let authProvider: MSAuthenticationProvider
	private let clientApplication: MSALPublicClientApplication

	public convenience init(identifier: String, type: MicrosoftGraphType) {
		self.init(identifier: identifier, scopes: type.scopes)
	}

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
