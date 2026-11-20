//
//  SharePointTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 19.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension IntegrationTests.ProviderSpecific {
	@Suite(.enabled(if: IntegrationBackend.isSelected(.sharePoint)))
	struct SharePointTests {
		private static let backend = IntegrationBackend(.sharePoint, .plain)

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

		/// Lowers the chunk length of an upload session to 320 KiB, so that a file of 641 KiB is uploaded in three chunks, as a new file and then replacing it.
		@Test
		func fileOfSeveralChunksIsUploaded() async throws {
			try await withIntegrationFixture(SharePointTests.backend) { context in
				let provider = try await MicrosoftGraphCloudProvider(client: .foreground(tokenSource: SharedCredentials.sharePoint.tokenSource), driveIdentifier: SharePointTestDrive.shared.identifier(), uploadSessionChunkLength: MicrosoftGraphTests.uploadSessionChunkLength)
				let cloudPath = try await context.makeSandbox().appendingPathComponent("large.bin")
				try await expectUploadRoundTrips(ofLength: MicrosoftGraphTests.threeChunkFileLength, to: cloudPath, through: provider, in: context)
			}
		}
	}
}
