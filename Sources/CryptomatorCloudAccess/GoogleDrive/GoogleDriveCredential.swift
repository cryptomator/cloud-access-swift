//
//  GoogleDriveCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 22.09.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import AppAuthCore
import Foundation
import GoogleAPIClientForREST_Drive
import GTMAppAuth
import Promises

public enum GoogleDriveCredentialError: Error {
	case notAuthenticated
	case noUsername
	case noAccountID
}

public class GoogleDriveCredential {
	public let driveService: GTLRDriveService
	public var isAuthorized: Bool {
		authSession?.canAuthorize ?? false
	}

	var authSession: AuthSession?
	private static let keychainItemPrefix = "GoogleDriveAuth"

	public init(userID: String? = nil) {
		if let userID = userID {
			let keychainItemName = GoogleDriveCredential.getKeychainName(forUserID: userID)
			self.authSession = try? KeychainStore(itemName: keychainItemName).retrieveAuthSession()
		} else {
			self.authSession = nil
		}
		self.driveService = GTLRDriveService()
		driveService.authorizer = authSession
	}

	public func save(authState: OIDAuthState) throws {
		authSession = AuthSession(authState: authState)
		driveService.authorizer = authSession
		if let authSession = authSession, let userID = authSession.userID {
			let keychainItemName = GoogleDriveCredential.getKeychainName(forUserID: userID)
			try KeychainStore(itemName: keychainItemName).save(authSession: authSession)
		}
	}

	public func getUsername() throws -> String {
		guard isAuthorized else {
			throw GoogleDriveCredentialError.notAuthenticated
		}
		guard let userEmail = authSession?.userEmail else {
			throw GoogleDriveCredentialError.noUsername
		}
		return userEmail
	}

	public func getAccountID() throws -> String {
		guard isAuthorized else {
			throw GoogleDriveCredentialError.notAuthenticated
		}
		guard let userID = authSession?.userID else {
			throw GoogleDriveCredentialError.noAccountID
		}
		return userID
	}

	public func deauthenticate() {
		if let authSession = authSession, let userID = authSession.userID {
			let keychainItemName = GoogleDriveCredential.getKeychainName(forUserID: userID)
			try? KeychainStore(itemName: keychainItemName).removeAuthSession()
		}
		driveService.fetcherService.resetSession()
		authSession = nil
		driveService.authorizer = nil
	}

	private static func getKeychainName(forUserID userID: String) -> String {
		return keychainItemPrefix + userID
	}
}
