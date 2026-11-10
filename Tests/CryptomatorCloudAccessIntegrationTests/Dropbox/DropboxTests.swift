//
//  DropboxTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 21.10.26.
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
	@Suite(.enabled(if: IntegrationBackend.isSelected(.dropbox)))
	struct DropboxTests {
		private static let backend = IntegrationBackend(.dropbox, .plain)
		private static let mebibyte = 1024 * 1024

		@Test
		func firstAccessTokenIsRefreshed() async throws {
			try await withIntegrationRetries(on: .dropbox) {
				let credential = try DropboxCredentialMock.generateAuthorizedCredential(userID: "DropboxCredentialTest-\(UUID().uuidString)")
				let accessToken = try await credential.tokenSource.accessToken()
				#expect(!accessToken.isEmpty)
			}
		}

		/// Lowers the threshold of an upload session to 8 MiB and its chunks to 4 MiB, so that a 12 MiB file is uploaded in three chunks, as a new file and then replacing it.
		@Test
		func largeFileIsUploadedThroughUploadSession() async throws {
			try await withIntegrationFixture(DropboxTests.backend) { context in
				let credential = try DropboxCredentialMock.generateAuthorizedCredential(userID: "DropboxUploadSessionTest-\(UUID().uuidString)")
				let provider = DropboxCloudProvider(client: .foreground(tokenSource: credential.tokenSource), maxPageSize: .max, uploadSessionThreshold: 8 * DropboxTests.mebibyte, uploadSessionChunkLength: 4 * DropboxTests.mebibyte)
				let cloudPath = try await context.makeSandbox().appendingPathComponent("large.bin")
				try await expectUploadRoundTrips(ofLength: 12 * DropboxTests.mebibyte, to: cloudPath, through: provider, in: context)
			}
		}
	}
}
