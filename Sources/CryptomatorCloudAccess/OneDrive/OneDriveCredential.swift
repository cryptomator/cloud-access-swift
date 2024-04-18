//
//  OneDriveCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 16.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import MSAL
import MSGraphClientSDK
import Promises

public enum OneDriveCredentialError: Error {
	case noUsername
}

public class OneDriveCredential {
	public static let scopes = ["https://graph.microsoft.com/Files.ReadWrite"]

	public let identifier: String
	let authProvider: MSAuthenticationProvider
	private let clientApplication: MSALPublicClientApplication

	public convenience init(with identifier: String) throws {
		let authProvider = OneDriveAuthenticationProvider(identifier: identifier, clientApplication: OneDriveSetup.constants.clientApplication, scopes: OneDriveCredential.scopes)
		try self.init(with: identifier, authProvider: authProvider, clientApplication: OneDriveSetup.constants.clientApplication)
	}

	init(with identifier: String, authProvider: MSAuthenticationProvider, clientApplication: MSALPublicClientApplication) throws {
		self.identifier = identifier
		self.authProvider = authProvider
		self.clientApplication = clientApplication
	}

	public func getUsername() throws -> String {
		let account = try clientApplication.account(forIdentifier: identifier)
		guard let username = account.username else {
			throw OneDriveCredentialError.noUsername
		}
		return username
	}

	public func deauthenticate() throws {
		let account = try clientApplication.account(forIdentifier: identifier)
		try clientApplication.remove(account)
	}
}
