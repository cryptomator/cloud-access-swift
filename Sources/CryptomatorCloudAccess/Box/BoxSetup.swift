//
//  BoxSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 18.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation
import os

public final class BoxSetup: Sendable {
	private static let lockedConstants = OSAllocatedUnfairLock<BoxSetup?>(initialState: nil)
	public static var constants: BoxSetup! {
		get { lockedConstants.withLock { $0 } }
		set { lockedConstants.withLock { $0 = newValue } }
	}

	public let clientId: String
	public let clientSecret: String
	public let sharedContainerIdentifier: String?
	/// The directory of the lock that serializes token refreshes. Every process that uses the same `OAuthTokenStorage` must pass the same directory, e.g., one in the App Group container.
	public let tokenLockDirectory: URL

	/// - Throws: `OAuthTokenStoreError.invalidLockDirectory` if `tokenLockDirectory` isn't a file URL.
	public init(clientId: String, clientSecret: String, sharedContainerIdentifier: String?, tokenLockDirectory: URL) throws {
		guard tokenLockDirectory.isFileURL else {
			throw OAuthTokenStoreError.invalidLockDirectory
		}
		self.clientId = clientId
		self.clientSecret = clientSecret
		self.sharedContainerIdentifier = sharedContainerIdentifier
		self.tokenLockDirectory = tokenLockDirectory
	}
}
