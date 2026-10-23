//
//  DropboxSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 01.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation

/// The registration of the app at Dropbox, and where the Dropbox logins are kept.
public struct DropboxSetup: Sendable {
	/// The app key of the Dropbox app, whose redirect URL scheme is `db-` followed by the app key.
	public let appKey: String
	/// Where the Dropbox logins are kept. Every process that uses the same logins must pass an equal value.
	public let oauth: OAuthPersistence

	public init(appKey: String, oauth: OAuthPersistence) {
		self.appKey = appKey
		self.oauth = oauth
	}
}
