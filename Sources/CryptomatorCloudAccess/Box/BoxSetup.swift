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
	/// Where the Box logins are kept. Every process that uses the same logins must pass an equal value.
	public let oauth: OAuthPersistence

	public init(clientId: String, clientSecret: String, sharedContainerIdentifier: String?, oauth: OAuthPersistence) {
		self.clientId = clientId
		self.clientSecret = clientSecret
		self.sharedContainerIdentifier = sharedContainerIdentifier
		self.oauth = oauth
	}
}
