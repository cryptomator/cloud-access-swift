//
//  S3EndpointTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class S3EndpointTests: XCTestCase {
	func testVirtualHostedStyleForDNSCompatibleBucket() throws {
		XCTAssertEqual("https://mybucket.example.com/folder/file.txt", try url(endpointURL: "https://example.com", bucket: "mybucket", key: "folder/file.txt"))
		XCTAssertEqual("https://mybucket.example.com/", try url(endpointURL: "https://example.com", bucket: "mybucket", key: ""))
	}

	func testPathStyleForOtherBuckets() throws {
		XCTAssertEqual("https://example.com/my.bucket/file.txt", try url(endpointURL: "https://example.com", bucket: "my.bucket", key: "file.txt"))
		XCTAssertEqual("https://example.com/My_Bucket/file.txt", try url(endpointURL: "https://example.com", bucket: "My_Bucket", key: "file.txt"))
		XCTAssertEqual("https://example.com/ab/file.txt", try url(endpointURL: "https://example.com", bucket: "ab", key: "file.txt"))
		XCTAssertEqual("https://example.com/MyBucket/file.txt", try url(endpointURL: "https://example.com", bucket: "MyBucket", key: "file.txt"))
		XCTAssertEqual("https://example.com/bucket-/file.txt", try url(endpointURL: "https://example.com", bucket: "bucket-", key: "file.txt"))
		let longBucket = String(repeating: "b", count: 64)
		XCTAssertEqual("https://example.com/\(longBucket)/file.txt", try url(endpointURL: "https://example.com", bucket: longBucket, key: "file.txt"))
		XCTAssertEqual("https://example.com/my.bucket", try url(endpointURL: "https://example.com", bucket: "my.bucket", key: ""))
	}

	func testVirtualHostedStyleUpToMaximumBucketLength() throws {
		let bucket = String(repeating: "b", count: 63)
		XCTAssertEqual("https://\(bucket).example.com/file.txt", try url(endpointURL: "https://example.com", bucket: bucket, key: "file.txt"))
	}

	func testPathStyleForIPAddressHost() throws {
		XCTAssertEqual("http://[fd00::1]:9000/mybucket/file.txt", try url(endpointURL: "http://[fd00::1]:9000", bucket: "mybucket", key: "file.txt"))
		XCTAssertEqual("http://192.168.1.10:9000/mybucket/file.txt", try url(endpointURL: "http://192.168.1.10:9000", bucket: "mybucket", key: "file.txt"))
		XCTAssertEqual("https://127.1/mybucket/file.txt", try url(endpointURL: "https://127.1", bucket: "mybucket", key: "file.txt"))
		XCTAssertEqual("http://192.168.1.09:9000/mybucket/file.txt", try url(endpointURL: "http://192.168.1.09:9000", bucket: "mybucket", key: "file.txt"))
	}

	func testVirtualHostedStyleForHostnameContainingIPAddress() throws {
		XCTAssertEqual("http://mybucket.127.0.0.1.nip.io:9000/file.txt", try url(endpointURL: "http://127.0.0.1.nip.io:9000", bucket: "mybucket", key: "file.txt"))
	}

	/// Such buckets pass the DNS rule of AWS SDK 2.41.0, but a host can't contain them.
	func testPathStyleForBucketsWithCharactersInvalidInHost() throws {
		XCTAssertEqual("https://example.com/b%C3%BCcket/file.txt", try url(endpointURL: "https://example.com", bucket: "bücket", key: "file.txt"))
		XCTAssertEqual("https://example.com/my%20bucket/file.txt", try url(endpointURL: "https://example.com", bucket: "my bucket", key: "file.txt"))
		XCTAssertEqual("https://example.com/my%3Abucket/file.txt", try url(endpointURL: "https://example.com", bucket: "my:bucket", key: "file.txt"))
		XCTAssertEqual("https://example.com/my%25bucket/file.txt", try url(endpointURL: "https://example.com", bucket: "my%bucket", key: "file.txt"))
		XCTAssertEqual("https://example.com/my%2Fbucket/file.txt", try url(endpointURL: "https://example.com", bucket: "my/bucket", key: "file.txt"))
		XCTAssertEqual("https://example.com/my%23bucket/file.txt", try url(endpointURL: "https://example.com", bucket: "my#bucket", key: "file.txt"))
	}

	func testKeepsSchemeAndNonDefaultPort() throws {
		XCTAssertEqual("http://mybucket.nas:9000/file.txt", try url(endpointURL: "http://nas:9000", bucket: "mybucket", key: "file.txt"))
		XCTAssertEqual("https://mybucket.example.com:8443/file.txt", try url(endpointURL: "https://example.com:8443", bucket: "mybucket", key: "file.txt"))
	}

	func testDropsDefaultPort() throws {
		XCTAssertEqual("https://mybucket.example.com/file.txt", try url(endpointURL: "https://example.com:443", bucket: "mybucket", key: "file.txt"))
		XCTAssertEqual("http://mybucket.example.com/file.txt", try url(endpointURL: "http://example.com:80", bucket: "mybucket", key: "file.txt"))
	}

	/// The path of the endpoint URL is ignored, as by the presigned transfers of AWS SDK 2.41.0.
	func testIgnoresPathOfEndpointURL() throws {
		XCTAssertEqual("https://mybucket.example.com/file.txt", try url(endpointURL: "https://example.com/", bucket: "mybucket", key: "file.txt"))
		XCTAssertEqual("https://mybucket.example.com/file.txt", try url(endpointURL: "https://example.com/prefix", bucket: "mybucket", key: "file.txt"))
	}

	func testEncodesQueryCompletely() throws {
		let endpoint = try makeEndpoint(endpointURL: "https://example.com", bucket: "mybucket")
		let url = endpoint.url(forKey: "", query: [URLQueryItem(name: "prefix", value: "a+b/c=d?e;f:g@h i"), URLQueryItem(name: "uploads", value: nil)])
		XCTAssertEqual("prefix=a%2Bb%2Fc%3Dd%3Fe%3Bf%3Ag%40h%20i&uploads", URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
	}

	// MARK: - Helpers

	private func url(endpointURL: String, bucket: String, key: String) throws -> String {
		return try makeEndpoint(endpointURL: endpointURL, bucket: bucket).url(forKey: key).absoluteString
	}

	private func makeEndpoint(endpointURL: String, bucket: String) throws -> S3Endpoint {
		return try S3Endpoint(credential: S3Credential(accessKey: "", secretKey: "", url: XCTUnwrap(URL(string: endpointURL)), bucket: bucket, region: "us-east-1"))
	}
}
