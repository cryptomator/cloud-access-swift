//
//  MockDropboxCloudAuthentication.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 04.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import ObjectiveDropboxOfficial
import Promises
@testable import CryptomatorCloudAccess

class MockDropboxCredential: DropboxCredential {
	init() {
		DropboxSetup.constants = DropboxSetup(appKey: "", appGroupName: "", mainAppBundleId: "")
		super.init(tokenUid: "IntegrationTest")
	}

	override func setAuthorizedClient() {
		let config = DBTransportDefaultConfig(appKey: "",
		                                      appSecret: nil,
		                                      userAgent: nil,
		                                      asMemberId: nil,
		                                      delegateQueue: nil,
		                                      forceForegroundSession: true,
		                                      sharedContainerIdentifier: nil,
		                                      keychainService: nil)
		authorizedClient = DBUserClient(accessToken: IntegrationTestSecrets.dropboxAccessToken, transport: config)
	}

	override func deauthenticate() {
		authorizedClient = nil
	}
}
