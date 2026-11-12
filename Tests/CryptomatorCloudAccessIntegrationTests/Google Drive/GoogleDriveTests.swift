//
//  GoogleDriveTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 25.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccess

extension IntegrationTests.ProviderSpecific {
	@Suite(.enabled(if: IntegrationBackend.isSelected(.googleDrive)))
	struct GoogleDriveTests {
		/// The stored access token has expired, so the first access token comes from a refresh with the refresh token.
		@Test
		func firstAccessTokenIsRefreshed() async throws {
			try await withIntegrationRetries(on: .googleDrive) {
				let credential = try GoogleDriveAuthenticatorMock.generateAuthorizedCredential(withRefreshToken: IntegrationTestSecrets.googleDriveRefreshToken, tokenUID: "GDriveCredentialTest-\(UUID().uuidString)")
				let accessToken = try await credential.tokenSource.accessToken()
				#expect(!accessToken.isEmpty)
			}
		}
	}
}
