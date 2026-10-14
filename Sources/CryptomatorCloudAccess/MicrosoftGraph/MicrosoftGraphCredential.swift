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

/// `@unchecked Sendable`: all stored properties are immutable. `authProvider` is a `Sendable` `MicrosoftGraphAuthenticationProvider`, or a `Sendable` mock in tests. `clientApplication` is only called by `getUsername()` and `deauthenticate()`, which are isolated to the main actor because MSAL doesn't document that it may be called from any thread. The class isn't `final` because tests subclass it.
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

	@MainActor
	public func getUsername() throws -> String {
		let account = try clientApplication.account(forIdentifier: identifier)
		guard let username = account.username else {
			throw MicrosoftGraphCredentialError.noUsername
		}
		return username
	}

	@MainActor
	public func deauthenticate() throws {
		let account = try clientApplication.account(forIdentifier: identifier)
		try clientApplication.remove(account)
	}
}
