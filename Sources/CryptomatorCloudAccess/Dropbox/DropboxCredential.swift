//
//  DropboxCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 23.09.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
@preconcurrency import ObjectiveDropboxOfficial
import os

public enum DropboxCredentialErrors: Error {
	case noUsername
}

/// `@unchecked Sendable`: `tokenUID` is immutable and `authorizedClient` is replaced under a lock, while the requests of that client are issued on the main actor. The class is subclassed in tests.
public class DropboxCredential: @unchecked Sendable {
	private let lockedAuthorizedClient = OSAllocatedUnfairLock<DBUserClient?>(initialState: nil)
	public internal(set) var authorizedClient: DBUserClient? {
		get { lockedAuthorizedClient.withLock { $0 } }
		set { lockedAuthorizedClient.withLock { $0 = newValue } }
	}

	public let tokenUID: String
	public var isAuthorized: Bool {
		authorizedClient?.isAuthorized() ?? false
	}

	public init(tokenUID: String) {
		self.tokenUID = tokenUID
		DropboxClientSetup.oneTimeSetup()
		setAuthorizedClient()
	}

	public func setAuthorizedClient() {
		authorizedClient = DBClientsManager.authorizedClients()[tokenUID]
	}

	public func deauthenticate() {
		authorizedClient = nil
		DBClientsManager.unlinkAndResetClient(tokenUID)
	}

	public func getUsername() async throws -> String {
		guard let authorizedClient else {
			throw CloudProviderError.unauthorized
		}
		return try await withMainActorSDKContinuation { resumer in
			authorizedClient.usersRoutes.getCurrentAccount().setResponseBlock { result, _, networkError in
				if let error = networkError?.nsError {
					resumer.resume(throwing: isCancellationError(error) ? CancellationError() : error)
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
