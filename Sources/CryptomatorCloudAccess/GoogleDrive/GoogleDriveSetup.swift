//
//  GoogleDriveSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 01.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation

public class GoogleDriveSetup {
	public static var constants: GoogleDriveSetup!

	let clientId: String
	let redirectURL: URL
	let appGroupName: String

	public init(clientId: String, redirectURL: URL, appGroupName: String) {
		self.clientId = clientId
		self.redirectURL = redirectURL
		self.appGroupName = appGroupName
	}
}
