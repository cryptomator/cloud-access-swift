//
//  DropboxSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 01.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation

public class DropboxSetup {
	public static var constants: DropboxSetup!

	let appKey: String
	let appGroupName: String
	let mainAppBundleId: String

	public init(appKey: String, appGroupName: String, mainAppBundleId: String) {
		self.appKey = appKey
		self.appGroupName = appGroupName
		self.mainAppBundleId = mainAppBundleId
	}
}
