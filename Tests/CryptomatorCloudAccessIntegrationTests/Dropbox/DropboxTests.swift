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

		/// Lowers the threshold of an upload session to 8 MiB and its chunks to 4 MiB, so that a 12 MiB file is uploaded in three chunks.
		@Test
		func largeFileIsUploadedThroughUploadSession() async throws {
			try await withIntegrationFixture(DropboxTests.backend) { context in
				let credential = try DropboxCredentialMock.generateAuthorizedCredential(userID: "DropboxUploadSessionTest-\(UUID().uuidString)")
				let provider = DropboxCloudProvider(client: .foreground(tokenSource: credential.tokenSource), maxPageSize: .max, uploadSessionThreshold: 8 * DropboxTests.mebibyte, uploadSessionChunkLength: 4 * DropboxTests.mebibyte)
				let cloudPath = try await context.makeSandbox().appendingPathComponent("large.bin")
				for (replaceExisting, seed) in [(false, UInt32(1)), (true, UInt32(2))] {
					// Each 4-byte word is its offset XORed with the seed, so that the chunks and both versions differ.
					let words = stride(from: 0, to: 12 * DropboxTests.mebibyte, by: 4).map { (UInt32($0) ^ seed).littleEndian }
					let data = words.withUnsafeBufferPointer { Data(buffer: $0) }
					let localURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString)
					try data.write(to: localURL)

					let metadata = try await provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: replaceExisting)
					let downloadURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString)
					_ = try await provider.downloadFile(from: cloudPath, to: downloadURL)

					#expect(metadata.size == data.count)
					#expect(try Data(contentsOf: downloadURL) == data, "The download differs from the upload")
				}
			}
		}
	}
}
