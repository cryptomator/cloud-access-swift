//
//  S3CloudProviderIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 13.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import AWSS3
import Promises
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

	override class func setUp() {
		S3CloudProviderIntegrationTests.onetimeAWSIntegrationTestsSetup
		integrationTestParentCloudPath = CloudPath("/iOS-IntegrationTests-Plain")
		// swiftlint:disable:next force_try
		setUpProvider = try! S3CloudProvider(credential: .mock)
		super.setUp()
	}

	override func setUpWithError() throws {
		try super.setUpWithError()
		provider = try S3CloudProvider(credential: .mock)
	}

	override func deauthenticate() -> Promise<Void> {
		do {
			provider = try S3CloudProvider(credential: .unauthorizedMock)
		} catch {
			return Promise(error)
		}
		return Promise(())
	}

	func testMultiPartCopy() throws {
		let credential = S3Credential.mock
		let endpoint = AWSEndpoint(url: credential.url)
		let credentialsProvider = AWSStaticCredentialsProvider(accessKey: credential.accessKey, secretKey: credential.secretKey)
		let region = S3Credential.mock.region.aws_regionTypeValue()
		let serviceConfiguration = try XCTUnwrap(AWSServiceConfiguration(region: region, endpoint: endpoint, credentialsProvider: credentialsProvider))
		AWSS3.register(with: serviceConfiguration, forKey: credential.identifier)
		let service = AWSS3.s3(forKey: credential.identifier)
		// allowed minimum part size is 5MB in multipart upload use this for testing purposes.
		let maxPartSize = 5 * 1024 * 1024
		let copyTaskUtility = S3CopyTaskUtility(service: service, bucket: credential.bucket, maxPartSize: maxPartSize)
		// Create a 12 MB file to test 3 parts with the last part smaller than 5 MB
		let length = maxPartSize + (7 * 1024 * 1024)
		let bytes = [UInt32](repeating: 0, count: length)
		let data = Data(bytes: bytes, count: length)
		let tmpFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		try data.write(to: tmpFileURL)
		let sourceCloudPath = S3CloudProviderIntegrationTests.integrationTestParentCloudPath.appendingPathComponent(tmpFileURL.lastPathComponent)
		let expectation = XCTestExpectation()
		let s3Provider = try XCTUnwrap(provider as? S3CloudProvider)
		provider.uploadFile(from: tmpFileURL, to: sourceCloudPath, replaceExisting: false).then { metadata -> Promise<Void> in
			let targetCloudPath = S3CloudProviderIntegrationTests.integrationTestParentCloudPath.appendingPathComponent(tmpFileURL.lastPathComponent + "1")
			let sourceKey = s3Provider.getKey(for: sourceCloudPath)
			let targetKey = s3Provider.getKey(for: targetCloudPath)
			let itemSize = try XCTUnwrap(metadata.size)
			let request = S3CopyRequest(sourceKey: sourceKey, targetKey: targetKey, itemSize: itemSize)
			return copyTaskUtility.copy(request)
		}.catch { error in
			XCTFail("Promise failed with error: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}
}

extension S3Credential {
	static let mock = S3Credential(accessKey: IntegrationTestSecrets.s3AccessKey,
	                               secretKey: IntegrationTestSecrets.s3SecretKey,
	                               url: IntegrationTestSecrets.s3URL,
	                               bucket: IntegrationTestSecrets.s3Bucket,
	                               region: IntegrationTestSecrets.s3RegionName)

	static let unauthorizedMock = S3Credential(accessKey: IntegrationTestSecrets.s3AccessKey,
	                                           secretKey: IntegrationTestSecrets.s3SecretKey + "Foo",
	                                           url: IntegrationTestSecrets.s3URL,
	                                           bucket: IntegrationTestSecrets.s3Bucket,
	                                           region: IntegrationTestSecrets.s3RegionName)
}

extension S3CloudProviderIntegrationTests {
	static let onetimeAWSIntegrationTestsSetup: Void = {
		AWSDDLog.sharedInstance.logLevel = .verbose
		AWSDDLog.add(AWSDDTTYLogger.sharedInstance)
	}()
}
