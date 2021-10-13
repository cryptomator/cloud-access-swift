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
		authorization?.canAuthorize() ?? false
	}

	var authorization: GTMAppAuthFetcherAuthorization?
	private static let keychainItemPrefix = "GoogleDriveAuth"

	public init(userID: String? = nil) {
		if let userID = userID {
			let keychainItemName = GoogleDriveCredential.getKeychainName(forUserID: userID)
			self.authorization = GTMAppAuthFetcherAuthorization(fromKeychainForName: keychainItemName)
		} else {
			self.authorization = nil
		}
		self.driveService = GTLRDriveService()
		driveService.authorizer = authorization
	}

	public func save(authState: OIDAuthState) {
		authorization = GTMAppAuthFetcherAuthorization(authState: authState)
		driveService.authorizer = authorization
		if let authorization = authorization, let userID = authorization.userID {
			let keychainItemName = GoogleDriveCredential.getKeychainName(forUserID: userID)
			GTMAppAuthFetcherAuthorization.save(authorization, toKeychainForName: keychainItemName)
		}
	}

	public func getUsername() throws -> String {
		guard isAuthorized else {
			throw GoogleDriveCredentialError.notAuthenticated
		}
		guard let userEmail = authorization?.userEmail else {
			throw GoogleDriveCredentialError.noUsername
		}
		return userEmail
	}

	public func getAccountID() throws -> String {
		guard isAuthorized else {
			throw GoogleDriveCredentialError.notAuthenticated
		}
		guard let userID = authorization?.userID else {
			throw GoogleDriveCredentialError.noAccountID
		}
		return userID
	}

	public func deauthenticate() {
		if let authorization = authorization, let userID = authorization.userID {
			let keychainItemName = GoogleDriveCredential.getKeychainName(forUserID: userID)
			GTMAppAuthFetcherAuthorization.removeFromKeychain(forName: keychainItemName)
		}
		driveService.fetcherService.resetSession()
		authorization = nil
		driveService.authorizer = nil
	}

	private static func getKeychainName(forUserID userID: String) -> String {
		return keychainItemPrefix + userID
	}
}
