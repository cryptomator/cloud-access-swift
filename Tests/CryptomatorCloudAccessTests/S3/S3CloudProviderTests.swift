//
//  S3CloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 01.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
import AWSS3

class S3CloudProviderTests: XCTestCase {
	var provider: S3CloudProvider!

	override func setUpWithError() throws {
		provider = S3CloudProvider(credential: .stub)
	}

	func testGetPrefix() throws {
		let rootCloudPath = CloudPath("/")
		XCTAssertEqual("", provider.getPrefix(for: rootCloudPath))

		XCTAssertEqual("foo/", provider.getPrefix(for: CloudPath("/foo")))
		XCTAssertEqual("foo/", provider.getPrefix(for: CloudPath("/foo/")))

		XCTAssertEqual("foo/bar/", provider.getPrefix(for: CloudPath("/foo/bar")))
	}

	func testGetKey() throws {
		XCTAssertEqual("foo.txt", provider.getKey(for: CloudPath("/foo.txt")))
		XCTAssertEqual("foo/bar.txt", provider.getKey(for: CloudPath("/foo/bar.txt")))
	}

	func testMapUnknownAWSS3ErrorToInvalidPageToken() throws {
		let awsS3ContinuationTokenError = NSError(domain: AWSS3ErrorDomain, code: 0, userInfo: ["Code": "InvalidArgument", "ArgumentName": "continuation-token"])
		XCTAssertEqual(.pageTokenInvalid, provider.convertStandardError(awsS3ContinuationTokenError) as? CloudProviderError)

		let scalewayS3ContinuationTokenError = NSError(domain: AWSS3ErrorDomain, code: 0, userInfo: ["Code": "InternalError", "Reason": "Incorrect padding"])
		XCTAssertEqual(.pageTokenInvalid, provider.convertStandardError(scalewayS3ContinuationTokenError) as? CloudProviderError)
	}

	func testCreateListObjectsV2Request() {
		let request = provider.createListObjectsV2Request(for: CloudPath("/folder"), recursive: false, pageToken: nil)
		XCTAssertEqual("folder/", request.prefix)
		XCTAssertEqual("/", request.delimiter)
		XCTAssertNil(request.continuationToken)
		XCTAssertEqual(S3Credential.stub.bucket, request.bucket)
	}

	func testCreateListObjectsV2RequestWithContinuationToken() {
		let pageToken = "test-page-token"
		let request = provider.createListObjectsV2Request(for: CloudPath("/folder"), recursive: false, pageToken: pageToken)
		XCTAssertEqual("folder/", request.prefix)
		XCTAssertEqual("/", request.delimiter)
		XCTAssertEqual(pageToken, request.continuationToken)
		XCTAssertEqual(S3Credential.stub.bucket, request.bucket)
	}

	func testCreateListObjectsV2RequestRecursive() {
		let request = provider.createListObjectsV2Request(for: CloudPath("/folder"), recursive: true, pageToken: nil)
		XCTAssertEqual("folder/", request.prefix)
		XCTAssertNil(request.delimiter)
		XCTAssertNil(request.continuationToken)
		XCTAssertEqual(S3Credential.stub.bucket, request.bucket)
	}

	func testCreateDeleteObjectRequest() {
		let request = provider.createDeleteObjectRequest(for: CloudPath("/test.txt"))
		XCTAssertEqual("test.txt", request.key)
		XCTAssertEqual(S3Credential.stub.bucket, request.bucket)
	}

	func testCreateDeleteObjectsRequest() throws {
		let keys = ["test.txt", "folder/test1.pdf"]
		let request = provider.createDeleteObjectsRequest(keys: keys)
		XCTAssertEqual(S3Credential.stub.bucket, request.bucket)
		let removeContainer = try XCTUnwrap(request.remove)
		let objects = try XCTUnwrap(removeContainer.objects)
		XCTAssertEqual(keys, objects.map { $0.key })
	}

	func testCreateEmptyFolderPutObjectRequest() {
		let request = provider.createEmptyFolderPutObjectRequest(for: CloudPath("/folder"))
		XCTAssertEqual(S3Credential.stub.bucket, request.bucket)
		XCTAssertEqual("folder/", request.key)
		XCTAssertNil(request.body)
	}

	func testInitializerSetRegionName() throws {
		let hostName = try XCTUnwrap(S3Credential.stub.url.host)
		let customRegionName = CustomAWSEndpointRegionNameStorage.shared.getRegionName(for: hostName)
		XCTAssertEqual(S3Credential.stub.region, customRegionName)
	}
}

extension S3Credential {
	static let stub = S3Credential(accessKey: "access", secretKey: "secret", url: URL(string: "https://www.example.com")!, bucket: "exampleBucket", region: "example-region", identifier: UUID().uuidString)
}
