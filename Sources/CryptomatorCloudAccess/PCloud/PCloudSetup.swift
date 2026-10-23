//
//  PCloudSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 18.04.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation

/// The registration of the app at pCloud, and where the pCloud logins are kept.
public struct PCloudSetup: Sendable {
	public let appKey: String
	/// Where the pCloud logins are kept. Every process that uses the same logins must pass an equal value.
	public let oauth: OAuthPersistence

	public init(appKey: String, oauth: OAuthPersistence) {
		self.appKey = appKey
		self.oauth = oauth
	}
}
