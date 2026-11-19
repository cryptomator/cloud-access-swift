//
//  SharePointTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 19.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptomatorCloudAccessCore
import Foundation
import Testing

extension IntegrationTests.ProviderSpecific {
	@Suite(.enabled(if: IntegrationBackend.isSelected(.sharePoint)))
	struct SharePointTests {
		/// The backend finds its drive among the site's drives and never fetches a drive by its identifier.
		@Test
		func driveIsFetchedByIdentifier() async throws {
			try await withIntegrationRetries(on: .sharePoint) {
				let driveIdentifier = try await SharePointTestDrive.shared.identifier()
				let drive = try await MicrosoftGraphDiscovery(credential: SharedCredentials.sharePoint).fetchDrive(for: driveIdentifier)
				#expect(drive.identifier == driveIdentifier)
				#expect(try drive.name == IntegrationTestSecrets.microsoftGraphSharePointDriveName)
			}
		}
	}
}
