//
//  MicrosoftGraphCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 16.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
@preconcurrency import MSAL

public enum MicrosoftGraphCredentialError: Error {
	case noUsername
}

/// `@unchecked Sendable`: all stored properties are immutable. `clientApplication` is only called by `getUsername()` and `deauthenticate()`, which are isolated to the main actor because MSAL doesn't document that it may be called from any thread. The class isn't `final` because tests subclass it.
public class MicrosoftGraphCredential: @unchecked Sendable {
	public let identifier: String
	public let scopes: [String]
	let tokenSource: any BearerTokenSource
	private let clientApplication: MSALPublicClientApplication

	public convenience init(identifier: String, type: MicrosoftGraphType, setup: MicrosoftGraphSetup) {
		let tokenSource = MicrosoftGraphAuthenticationProvider(identifier: identifier, clientApplication: setup.clientApplication, scopes: type.scopes)
		self.init(identifier: identifier, scopes: type.scopes, tokenSource: tokenSource, clientApplication: setup.clientApplication)
	}

	init(identifier: String, scopes: [String], tokenSource: any BearerTokenSource, clientApplication: MSALPublicClientApplication) {
		self.identifier = identifier
		self.scopes = scopes
		self.tokenSource = tokenSource
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
