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
	public class var scopes: [String] {
		return ["https://graph.microsoft.com/Files.ReadWrite"] 
	}

	let authProvider: MSAuthenticationProvider
	private let clientApplication: MSALPublicClientApplication

	public required init(with identifier: String) throws {
		self.identifier = identifier
		let clientApplication = MicrosoftGraphSetup.constants.clientApplication
		let authProvider = MicrosoftGraphAuthenticationProvider(identifier: identifier, clientApplication: clientApplication, scopes: Self.scopes)
		self.clientApplication = clientApplication
		self.authProvider = authProvider
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

