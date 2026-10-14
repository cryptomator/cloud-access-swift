//
//  GoogleDriveCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 22.09.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

@preconcurrency import AppAuthCore
import Foundation
@preconcurrency import GoogleAPIClientForREST_Drive
@preconcurrency import GTMAppAuth
import os

public enum GoogleDriveCredentialError: Error {
	case notAuthenticated
	case noUsername
	case noAccountID
}

/// Safe to share across threads, because `driveService` may be used from any thread and its authorizer is only replaced together with `authSession` under a lock.
public final class GoogleDriveCredential: Sendable {
	public let driveService: GTLRDriveService
	public var isAuthorized: Bool {
		authSession?.canAuthorize ?? false
	}

	var authSession: AuthSession? {
		lockedAuthSession.withLock { $0 }
	}

	private let lockedAuthSession: OSAllocatedUnfairLock<AuthSession?>
	private static let keychainItemPrefix = "GoogleDriveAuth"

	public init(userID: String? = nil) {
		let authSession: AuthSession?
		if let userID {
			let keychainItemName = GoogleDriveCredential.getKeychainName(forUserID: userID)
			authSession = try? KeychainStore(itemName: keychainItemName).retrieveAuthSession()
		} else {
			authSession = nil
		}
		self.lockedAuthSession = OSAllocatedUnfairLock(initialState: authSession)
		self.driveService = GTLRDriveService()
		driveService.authorizer = authSession
	}

	public func save(authState: OIDAuthState) throws {
		let authSession = AuthSession(authState: authState)
		setAuthSession(authSession)
		if let userID = authSession.userID {
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
		if let authSession, let userID = authSession.userID {
			let keychainItemName = GoogleDriveCredential.getKeychainName(forUserID: userID)
			try? KeychainStore(itemName: keychainItemName).removeAuthSession()
		}
		driveService.fetcherService.resetSession()
		setAuthSession(nil)
	}

	private func setAuthSession(_ authSession: AuthSession?) {
		lockedAuthSession.withLock { lockedAuthSession in
			lockedAuthSession = authSession
			driveService.authorizer = authSession
		}
	}

	private static func getKeychainName(forUserID userID: String) -> String {
		return keychainItemPrefix + userID
	}
}
