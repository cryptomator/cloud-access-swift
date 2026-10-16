//
//  S3Tests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 13.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

@preconcurrency import AWSS3
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
import Foundation
import Testing

extension IntegrationTests.ProviderSpecific {
	@Suite(.enabled(if: IntegrationBackend.isSelected(.s3)))
	struct S3Tests {
		/// S3's minimum part size, used as the maximum so that the test copies a small file in several parts.
		private static let multiPartCopyMaxPartSize = 5 * 1024 * 1024
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

		@MainActor
		private static func multiPartCopy(in context: IntegrationTestContext) async throws {
			let (copyTaskUtility, _) = try createCopyTaskUtility()
			let (request, _) = try await uploadFileForMultiPartCopy(in: context)
			try await copyTaskUtility.copy(request)
		}

		@MainActor
		private static func multiPartCopyInCancelledTask(in context: IntegrationTestContext) async throws {
			let (copyTaskUtility, service) = try createCopyTaskUtility()
			let (request, sourceCloudPath) = try await uploadFileForMultiPartCopy(in: context)
			let copyResult: Result<Void, Error>
			do {
				try await value(of: cancelledTask { try await copyTaskUtility.copy(request) }, timeout: .seconds(60))
				copyResult = .success(())
			} catch {
				copyResult = .failure(error)
			}
			let listRequest = try #require(AWSS3ListMultipartUploadsRequest())
			listRequest.bucket = IntegrationTestSecrets.s3Credential.bucket
			listRequest.prefix = request.targetKey
			let listOutput = try await service.listMultipartUploads(listRequest)
			let sourceExists = try await context.provider.checkForItemExistence(at: sourceCloudPath)
			switch copyResult {
			case .success:
				Issue.record("copy fulfilled in cancelled task")
			case let .failure(error):
				#expect(error is CancellationError, "copy threw \(error)")
			}
			#expect(listOutput.uploads?.isEmpty ?? true)
			#expect(sourceExists)
		}

		@MainActor
		private static func createCopyTaskUtility() throws -> (S3CopyTaskUtility, AWSS3) {
			let credential = IntegrationTestSecrets.s3Credential
			let endpoint = AWSEndpoint(url: credential.url)
			let credentialsProvider = AWSStaticCredentialsProvider(accessKey: credential.accessKey, secretKey: credential.secretKey)
			let region = credential.region.aws_regionTypeValue()
			let serviceConfiguration = try #require(AWSServiceConfiguration(region: region, endpoint: endpoint, credentialsProvider: credentialsProvider))
			AWSS3.register(with: serviceConfiguration, forKey: credential.identifier)
			let service = AWSS3.s3(forKey: credential.identifier)
			return (S3CopyTaskUtility(service: service, bucket: credential.bucket, maxPartSize: multiPartCopyMaxPartSize), service)
		}

		/// Uploads a 12 MB file to test 3 parts with the last part smaller than 5 MB. The run root's deletion removes it and its copy.
		@MainActor
		private static func uploadFileForMultiPartCopy(in context: IntegrationTestContext) async throws -> (S3CopyRequest, CloudPath) {
			let length = multiPartCopyMaxPartSize + (7 * 1024 * 1024)
			let bytes = [UInt32](repeating: 0, count: length)
			let data = Data(bytes: bytes, count: length)
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
			return (S3CopyRequest(sourceKey: sourceKey, targetKey: targetKey, itemSize: itemSize), sourceCloudPath)
		}
	}
}
