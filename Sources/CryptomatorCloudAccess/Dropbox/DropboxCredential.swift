//
//  DropboxCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 23.09.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
@preconcurrency import SwiftyDropbox

public enum DropboxCredentialErrors: Error {
	case noUsername
}

/**
 The Dropbox clients of an account, which share its access token.

 Downloads and single-request uploads run on `transferClient`, which uses a background session unless `DropboxSetup.constants.forceForegroundSession` is set. All other requests run on `client`, because a background session supports only downloads and uploads from a file, while the chunks of an upload session are uploaded from memory.
 */
struct DropboxAuthorizedClient {
	let client: DropboxClient
	let transferClient: DropboxClient

	init(accessTokenProvider: AccessTokenProvider) {
		self.client = DropboxClient(accessTokenProvider: accessTokenProvider)
		if DropboxSetup.constants.forceForegroundSession {
			self.transferClient = client
		} else {
			let sessionConfiguration = NetworkSessionConfiguration.background(withIdentifier: "CryptomatorCloudAccess.Dropbox.\(UUID().uuidString)", sharedContainerIdentifier: DropboxSetup.constants.sharedContainerIdentifier)
			self.transferClient = DropboxClient(accessTokenProvider: accessTokenProvider, sessionConfiguration: sessionConfiguration)
		}
	}
}

/// `@unchecked Sendable`: `tokenUID` is immutable and `authorizedClient` is replaced under a lock, while the requests of its clients are issued on the main actor. The class is subclassed in tests.
public class DropboxCredential: @unchecked Sendable {
	/// The clients of each account with the refresh token, or the long-lived access token, that they were created for. The credentials of an account share them, and with them one token refresh and one set of URL sessions, which are never invalidated.
	private static let lockedAuthorizedClients = OSAllocatedUnfairLock<[String: (token: String, authorizedClient: DropboxAuthorizedClient)]>(uncheckedState: [:])

	private let lockedAuthorizedClient = OSAllocatedUnfairLock<DropboxAuthorizedClient?>(uncheckedState: nil)
	var authorizedClient: DropboxAuthorizedClient? {
		get { lockedAuthorizedClient.withLockUnchecked { $0 } }
		set { lockedAuthorizedClient.withLockUnchecked { $0 = newValue } }
	}

	public let tokenUID: String
	public var isAuthorized: Bool {
		authorizedClient != nil
	}

	public init(tokenUID: String) {
		self.tokenUID = tokenUID
		DropboxClientSetup.oneTimeSetup()
		setAuthorizedClient()
	}

	public func setAuthorizedClient() {
		guard let accessToken = DropboxOAuthManager.sharedOAuthManager.getAccessToken(tokenUID) else {
			authorizedClient = nil
			return
		}
		// A token refresh keeps the refresh token, so only a new login replaces the clients of the account.
		let token = accessToken.refreshToken ?? accessToken.accessToken
		authorizedClient = DropboxCredential.lockedAuthorizedClients.withLockUnchecked { authorizedClients in
			if let cached = authorizedClients[tokenUID], cached.token == token {
				return cached.authorizedClient
			}
			let authorizedClient = DropboxAuthorizedClient(accessTokenProvider: DropboxOAuthManager.sharedOAuthManager.accessTokenProviderForToken(accessToken))
			authorizedClients[tokenUID] = (token, authorizedClient)
			return authorizedClient
		}
	}

	public func deauthenticate() {
		authorizedClient = nil
		DropboxCredential.lockedAuthorizedClients.withLockUnchecked { authorizedClients in
			authorizedClients[tokenUID] = nil
		}
		_ = DropboxClientSetup.keychainStorage.deleteInfo(for: tokenUID)
	}

	public func getUsername() async throws -> String {
		guard let authorizedClient else {
			throw CloudProviderError.unauthorized
		}
		return try await withMainActorSDKContinuation { resumer in
			authorizedClient.client.users.getCurrentAccount().response { result, error in
				if let error {
					resumer.resume(throwing: error.converted())
					return
				}
				guard let result else {
					resumer.resume(throwing: DropboxCredentialErrors.noUsername)
					return
				}
				resumer.resume(returning: result.email)
			}
		}
	}
}
