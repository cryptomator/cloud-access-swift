//
//  BoxTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 10.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

extension IntegrationTests.ProviderSpecific {
	@Suite(.enabled(if: IntegrationBackend.isSelected(.box)))
	struct BoxTests {
		private static let backend = IntegrationBackend(.box, .plain)
		/// Box refuses an upload session for a file under 20,000,000 bytes.
		private static let fileSize = 20 * 1024 * 1024

		/// Lowers the threshold of a chunked upload to the file's size, so that a file below the default threshold is uploaded in the parts of an upload session, as a new file and then replacing it.
		@Test
		func largeFileIsUploadedThroughUploadSession() async throws {
			try await withIntegrationFixture(BoxTests.backend) { context in
				let provider = try BoxCloudProvider(client: .foreground(tokenSource: BoxCredential.integrationTest().tokenSource), maxPageSize: .max, chunkedUploadThreshold: BoxTests.fileSize)
				let cloudPath = try await context.makeSandbox().appendingPathComponent("large.bin")
				try await expectUploadRoundTrips(ofLength: BoxTests.fileSize, to: cloudPath, through: provider, in: context)
			}
		}
	}
}
