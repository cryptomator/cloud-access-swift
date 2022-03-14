//
//  PCloudCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 15.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import PCloudSDKSwift
import Promises

public class PCloudCredential {
	public let client: PCloudClient
	public let user: OAuth.User
	public var userID: String {
		return String(user.id)
	}

	public init(user: OAuth.User) {
		self.user = user
		self.client = PCloud.createClient(with: user)
	}

	public func getUsername() -> Promise<String> {
		return client.fetchUserInfo().execute().then { metadata in
			return metadata.emailAddress
		}
	}
}
