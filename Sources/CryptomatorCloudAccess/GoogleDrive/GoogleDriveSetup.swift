//
//  GoogleDriveSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 01.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import os

public final class GoogleDriveSetup: Sendable {
	private static let lockedConstants = OSAllocatedUnfairLock<GoogleDriveSetup?>(initialState: nil)
	public static var constants: GoogleDriveSetup! {
		get { lockedConstants.withLock { $0 } }
		set { lockedConstants.withLock { $0 = newValue } }
	}

	public let clientId: String
	public let redirectURL: URL
	public let sharedContainerIdentifier: String?
	/// Where the Google Drive logins are kept. Every process that uses the same logins must pass an equal value.
	public let oauth: OAuthPersistence

	public init(clientId: String, redirectURL: URL, sharedContainerIdentifier: String?, oauth: OAuthPersistence) {
		self.clientId = clientId
		self.redirectURL = redirectURL
		self.sharedContainerIdentifier = sharedContainerIdentifier
		self.oauth = oauth
	}
}
