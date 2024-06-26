//
//  BoxSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 18.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation

public class BoxSetup {
	public static var constants: BoxSetup!

	public let clientId: String
	public let clientSecret: String
	public let sharedContainerIdentifier: String?

	public init(clientId: String, clientSecret: String, sharedContainerIdentifier: String?) {
		self.clientId = clientId
		self.clientSecret = clientSecret
		self.sharedContainerIdentifier = sharedContainerIdentifier
	}
}
