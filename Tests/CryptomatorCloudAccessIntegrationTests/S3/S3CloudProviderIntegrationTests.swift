//
//  S3CloudProviderIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 13.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

@preconcurrency import AWSS3
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class S3CloudProviderIntegrationTests: CloudAccessIntegrationTestWithAuthentication {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: S3CloudProviderIntegrationTests.self)
	}

	/// S3's minimum part size, used as the maximum so that the test copies a small file in several parts.
	private let multiPartCopyMaxPartSize = 5 * 1024 * 1024

	override class func setUp() {
		S3CloudProviderIntegrationTests.onetimeAWSIntegrationTestsSetup
		integrationTestParentCloudPath = CloudPath("/iOS-IntegrationTests-Plain-\(runID)")
		// swiftlint:disable:next force_try
		setUpProvider = try! S3CloudProvider(credential: IntegrationTestSecrets.s3Credential)
		super.setUp()
		guard classSetUpError == nil else { return }
		// Wait for Scaleway S3's eventual consistency to catch up after setUp uploaded all test fixtures.
		let expectedItemCount = 6 // 5 files (test 0-4.txt) + 1 folder (testFolder)
		waitForConsistencyOfSetUp(expectedItemCount: expectedItemCount)
	}

	override func setUp() async throws {
		try await super.setUp()
		provider = try S3CloudProvider(credential: IntegrationTestSecrets.s3Credential)
	}

	override func deauthenticate() async throws {
		let correctCredential = IntegrationTestSecrets.s3Credential
		let invalidCredential = S3Credential(accessKey: correctCredential.accessKey, secretKey: correctCredential.secretKey + "Foo", url: correctCredential.url, bucket: correctCredential.bucket, region: correctCredential.region)
		provider = try S3CloudProvider(credential: invalidCredential)
	}

	@MainActor
	func testMultiPartCopy() async throws {
		let (copyTaskUtility, _) = try createCopyTaskUtility()
		let (request, _) = try await uploadFileForMultiPartCopy()
		try await copyTaskUtility.copy(request)
	}

	@MainActor
	func testMultiPartCopyInCancelledTask() async throws {
		let (copyTaskUtility, service) = try createCopyTaskUtility()
		let (request, sourceCloudPath) = try await uploadFileForMultiPartCopy()
		await XCTAssertThrowsErrorAsync(try await value(of: cancelledTask { try await copyTaskUtility.copy(request) }, timeout: 60.0), "copy fulfilled in cancelled task") { error in
			XCTAssertTrue(error is CancellationError, "copy threw \(error)")
		}
		let listRequest = try XCTUnwrap(AWSS3ListMultipartUploadsRequest())
		listRequest.bucket = IntegrationTestSecrets.s3Credential.bucket
		listRequest.prefix = request.targetKey
		let listOutput = try await service.listMultipartUploads(listRequest)
		XCTAssertTrue(listOutput.uploads?.isEmpty ?? true)
		let sourceExists = try await provider.checkForItemExistence(at: sourceCloudPath)
		XCTAssertTrue(sourceExists)
		try await provider.deleteFile(at: sourceCloudPath)
	}

	@MainActor
	private func createCopyTaskUtility() throws -> (S3CopyTaskUtility, AWSS3) {
		let credential = IntegrationTestSecrets.s3Credential
		let endpoint = AWSEndpoint(url: credential.url)
		let credentialsProvider = AWSStaticCredentialsProvider(accessKey: credential.accessKey, secretKey: credential.secretKey)
		let region = credential.region.aws_regionTypeValue()
		let serviceConfiguration = try XCTUnwrap(AWSServiceConfiguration(region: region, endpoint: endpoint, credentialsProvider: credentialsProvider))
		AWSS3.register(with: serviceConfiguration, forKey: credential.identifier)
		let service = AWSS3.s3(forKey: credential.identifier)
		return (S3CopyTaskUtility(service: service, bucket: credential.bucket, maxPartSize: multiPartCopyMaxPartSize), service)
	}

	/// Uploads a 12 MB file to test 3 parts with the last part smaller than 5 MB.
	private func uploadFileForMultiPartCopy() async throws -> (S3CopyRequest, CloudPath) {
		let length = multiPartCopyMaxPartSize + (7 * 1024 * 1024)
		let bytes = [UInt32](repeating: 0, count: length)
		let data = Data(bytes: bytes, count: length)
		let tmpFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		try data.write(to: tmpFileURL)
		let sourceCloudPath = S3CloudProviderIntegrationTests.integrationTestParentCloudPath.appendingPathComponent(tmpFileURL.lastPathComponent)
		let targetCloudPath = S3CloudProviderIntegrationTests.integrationTestParentCloudPath.appendingPathComponent(tmpFileURL.lastPathComponent + "1")
		let s3Provider = try XCTUnwrap(provider as? S3CloudProvider)
		let metadata = try await provider.uploadFile(from: tmpFileURL, to: sourceCloudPath, replaceExisting: false)
		let sourceKey = s3Provider.getKey(for: sourceCloudPath)
		let targetKey = s3Provider.getKey(for: targetCloudPath)
		let itemSize = try XCTUnwrap(metadata.size)
		return (S3CopyRequest(sourceKey: sourceKey, targetKey: targetKey, itemSize: itemSize), sourceCloudPath)
	}

	override func createLimitedCloudProvider() async throws -> CloudProvider {
		return try S3CloudProvider(credential: IntegrationTestSecrets.s3Credential, maxPageSize: maxPageSizeForLimitedCloudProvider)
	}
}

extension S3CloudProviderIntegrationTests {
	static let onetimeAWSIntegrationTestsSetup: Void = {
		AWSDDLog.sharedInstance.logLevel = .verbose
		AWSDDLog.add(AWSDDTTYLogger.sharedInstance)
	}()
}
