//
//  DropboxCredentialMock.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 04.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
@preconcurrency import SwiftyDropbox
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
		authorizedClient = DropboxAuthorizedClient(accessTokenProvider: LongLivedAccessTokenProvider(accessToken: IntegrationTestSecrets.dropboxAccessToken))
	}

	override func deauthenticate() {
		authorizedClient = nil
	}
}
