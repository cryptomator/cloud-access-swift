//
//  BoxSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 18.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation

/// The registration of the app at Box, and where the Box logins are kept.
public struct BoxSetup: Sendable {
	public let clientID: String
	public let clientSecret: String
	/// Where the Box logins are kept. Every process that uses the same logins must pass an equal value.
	public let oauth: OAuthPersistence

	public init(clientID: String, clientSecret: String, oauth: OAuthPersistence) {
		self.clientID = clientID
		self.clientSecret = clientSecret
		self.oauth = oauth
	}
}
