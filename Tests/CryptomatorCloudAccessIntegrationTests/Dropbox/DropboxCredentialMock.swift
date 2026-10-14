//
//  DropboxCredentialMock.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 04.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
@preconcurrency import ObjectiveDropboxOfficial
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

/// `@unchecked Sendable`: restates the conformance of `DropboxCredential`; this subclass adds no state.
class DropboxCredentialMock: DropboxCredential, @unchecked Sendable {
	init() {
		DropboxSetup.constants = DropboxSetup(appKey: "", sharedContainerIdentifier: "", keychainService: "", forceForegroundSession: true)
		super.init(tokenUID: "IntegrationTest")
	}

	override func setAuthorizedClient() {
		let config = DBTransportDefaultConfig(appKey: "", appSecret: nil, userAgent: nil, asMemberId: nil, delegateQueue: nil, forceForegroundSession: true, sharedContainerIdentifier: nil, keychainService: nil)
		authorizedClient = DBUserClient(accessToken: IntegrationTestSecrets.dropboxAccessToken, transport: config)
	}

	override func deauthenticate() {
		authorizedClient = nil
	}
}
