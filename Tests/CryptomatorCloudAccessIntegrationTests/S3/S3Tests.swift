//
//  S3Tests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 13.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

extension IntegrationTests.ProviderSpecific {
	@Suite(.enabled(if: IntegrationBackend.isSelected(.s3)))
	struct S3Tests {
		/// S3's minimum part size, used as the maximum so that the test copies a small file in several parts.
		private static let multiPartCopyMaxPartSize = 5 * 1024 * 1024
		private static let mebibyte = 1024 * 1024
		private static let backend = IntegrationBackend(.s3, .plain)

		@Test
		func multiPartCopy() async throws {
			try await withIntegrationFixture(S3Tests.backend) { context in
				try await S3Tests.multiPartCopy(in: context)
			}
		}

		@Test
		func multiPartCopyInCancelledTask() async throws {
			try await withIntegrationFixture(S3Tests.backend) { context in
				try await S3Tests.multiPartCopyInCancelledTask(in: context)
			}
		}

		/// Lowers the threshold of a multipart upload to 8 MiB and its parts to S3's minimum of 5 MiB, so that a 12 MiB file is uploaded in three parts, as a new file and then replacing it.
		@Test
		func multipartUpload() async throws {
			try await withIntegrationFixture(S3Tests.backend) { context in
				let provider = try S3CloudProvider(client: .foreground(credential: IntegrationTestSecrets.s3Credential), maxPageSize: .max, multipartUploadThreshold: 8 * S3Tests.mebibyte, minPartSize: 5 * S3Tests.mebibyte)
				let cloudPath = try await context.makeSandbox().appendingPathComponent("large.bin")
				for (replaceExisting, seed) in [(false, UInt32(1)), (true, UInt32(2))] {
					// Each 4-byte word is its offset XORed with the seed, so that the parts and both versions differ.
					let words = stride(from: 0, to: 12 * S3Tests.mebibyte, by: 4).map { (UInt32($0) ^ seed).littleEndian }
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

		@Test
		func forcedPathStyleRoundTrip() async throws {
			try await withIntegrationFixture(S3Tests.backend) { context in
				let credential = IntegrationTestSecrets.s3Credential
				let provider = try S3CloudProvider(credential: S3Credential(accessKey: credential.accessKey, secretKey: credential.secretKey, url: credential.url, bucket: credential.bucket, region: credential.region, forcePathStyle: true))
				let sandbox = try await context.makeSandbox()
				let cloudPath = sandbox.appendingPathComponent("file.txt")
				let data = Data("path style".utf8)
				let localURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString)
				try data.write(to: localURL)

				_ = try await provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false)
				try await waitUntilVisible(cloudPath, through: provider, on: .s3)
				let items = try await provider.fetchItemListExhaustively(forFolderAt: sandbox).items
				let downloadURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString)
				_ = try await provider.downloadFile(from: cloudPath, to: downloadURL)
				try await provider.deleteFile(at: cloudPath)
				let isDeleted = try await eventually(on: .s3) {
					try await !provider.checkForItemExistence(at: cloudPath)
				}

				#expect(items.map(\.cloudPath) == [cloudPath])
				#expect(try Data(contentsOf: downloadURL) == data)
				#expect(isDeleted)
			}
		}

		/// Compares the credentials outside `#expect`, which would print both, secret key included, on a failure.
		@Test
		func verifyCredentialKeepsWorkingCredential() async throws {
			try await withIntegrationRetries(on: .s3) {
				let credential = IntegrationTestSecrets.s3Credential
				let verifiedCredential = try await S3Authenticator.verifyCredential(credential)
				let isUnchanged = verifiedCredential == credential
				#expect(isUnchanged, "The login check changed a working credential")
			}
		}

		/// Downloads the copy and compares it with the source, because a manifest that drops or reorders a part completes with a truncated or scrambled object.
		private static func multiPartCopy(in context: IntegrationTestContext) async throws {
			let (copyTaskUtility, _) = try createCopyTaskUtility()
			let upload = try await uploadFileForMultiPartCopy(in: context)
			try await copyTaskUtility.copy(upload.request)
			let downloadURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString)
			_ = try await context.provider.downloadFile(from: upload.targetCloudPath, to: downloadURL)
			let copiedData = try Data(contentsOf: downloadURL)
			#expect(copiedData.count == upload.data.count)
			#expect(copiedData == upload.data, "The copy differs from its source")
		}

		private static func multiPartCopyInCancelledTask(in context: IntegrationTestContext) async throws {
			let (copyTaskUtility, client) = try createCopyTaskUtility()
			let upload = try await uploadFileForMultiPartCopy(in: context)
			let copyResult: Result<Void, Error>
			do {
				try await value(of: cancelledTask { try await copyTaskUtility.copy(upload.request) }, timeout: .seconds(60))
				copyResult = .success(())
			} catch {
				copyResult = .failure(error)
			}
			let listRequest = URLRequest(url: client.endpoint.url(forKey: "", query: [URLQueryItem(name: "uploads", value: nil), URLQueryItem(name: "prefix", value: upload.request.targetKey)]))
			let multipartUploads = try await client.send(listRequest) { body in
				String(bytes: body, encoding: .utf8) ?? ""
			}
			let sourceExists = try await context.provider.checkForItemExistence(at: upload.sourceCloudPath)
			switch copyResult {
			case .success:
				Issue.record("copy fulfilled in cancelled task")
			case let .failure(error):
				#expect(error is CancellationError, "copy threw \(error)")
			}
			#expect(!multipartUploads.contains("<Upload>"), "multipart upload left behind")
			#expect(sourceExists)
		}

		private static func createCopyTaskUtility() throws -> (S3CopyTaskUtility, S3Client) {
			let client = try S3Client.foreground(credential: IntegrationTestSecrets.s3Credential)
			return (S3CopyTaskUtility(client: client, maxPartSize: multiPartCopyMaxPartSize), client)
		}

		/// Uploads a 12 MB file to test 3 parts with the last part smaller than 5 MB. Each 4-byte word holds its own offset, so that the parts differ. The run root's deletion removes it and its copy.
		private static func uploadFileForMultiPartCopy(in context: IntegrationTestContext) async throws -> MultiPartCopyUpload {
			let length = multiPartCopyMaxPartSize + (7 * 1024 * 1024)
			let words = stride(from: 0, to: length, by: 4).map { UInt32($0).littleEndian }
			let data = words.withUnsafeBufferPointer { Data(buffer: $0) }
			let tmpFileURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString)
			try data.write(to: tmpFileURL)
			let sandbox = try await context.makeSandbox()
			let sourceCloudPath = sandbox.appendingPathComponent(tmpFileURL.lastPathComponent)
			let targetCloudPath = sandbox.appendingPathComponent(tmpFileURL.lastPathComponent + "1")
			let s3Provider = try #require(context.provider as? S3CloudProvider)
			let metadata = try await context.provider.uploadFile(from: tmpFileURL, to: sourceCloudPath, replaceExisting: false)
			let sourceKey = s3Provider.getKey(for: sourceCloudPath)
			let targetKey = s3Provider.getKey(for: targetCloudPath)
			let itemSize = try #require(metadata.size)
			return MultiPartCopyUpload(request: S3CopyRequest(sourceKey: sourceKey, targetKey: targetKey, itemSize: itemSize), sourceCloudPath: sourceCloudPath, targetCloudPath: targetCloudPath, data: data)
		}
	}
}

private struct MultiPartCopyUpload {
	let request: S3CopyRequest
	let sourceCloudPath: CloudPath
	let targetCloudPath: CloudPath
	let data: Data
}
