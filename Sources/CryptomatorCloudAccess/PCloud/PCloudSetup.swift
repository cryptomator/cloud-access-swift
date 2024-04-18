//
//  PCloudSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 18.04.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation

public class PCloudSetup {
	public static var constants: PCloudSetup!

	public let appKey: String
	public let sharedContainerIdentifier: String?

	public init(appKey: String, sharedContainerIdentifier: String?) {
		self.appKey = appKey
		self.sharedContainerIdentifier = sharedContainerIdentifier
	}
}
