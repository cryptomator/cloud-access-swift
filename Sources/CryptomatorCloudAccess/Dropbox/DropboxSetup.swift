//
//  DropboxSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 01.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import os

public final class DropboxSetup: Sendable {
	private static let lockedConstants = OSAllocatedUnfairLock<DropboxSetup?>(initialState: nil)
	public static var constants: DropboxSetup! {
		get { lockedConstants.withLock { $0 } }
		set { lockedConstants.withLock { $0 = newValue } }
	}

	/// The app key of the Dropbox app, whose redirect URL scheme is `db-` followed by the app key.
	public let appKey: String
	/// The container into which a background URL session downloads files, which an app extension shares with the app.
	public let sharedContainerIdentifier: String?
	/// Where the Dropbox logins are kept. Every process that uses the same logins must pass an equal value.
	public let oauth: OAuthPersistence

	public init(appKey: String, sharedContainerIdentifier: String?, oauth: OAuthPersistence) {
		self.appKey = appKey
		self.sharedContainerIdentifier = sharedContainerIdentifier
		self.oauth = oauth
	}
}
