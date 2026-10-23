//
//  GoogleDriveSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 01.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation

/// The registration of the app at Google, and where the Google Drive logins are kept.
public struct GoogleDriveSetup: Sendable {
	public let clientID: String
	public let redirectURL: URL
	/// Where the Google Drive logins are kept. Every process that uses the same logins must pass an equal value.
	public let oauth: OAuthPersistence

	public init(clientID: String, redirectURL: URL, oauth: OAuthPersistence) {
		self.clientID = clientID
		self.redirectURL = redirectURL
		self.oauth = oauth
	}
}
