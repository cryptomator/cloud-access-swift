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

	func testForcedPathStyleForDNSCompatibleBucket() throws {
		XCTAssertEqual("https://example.com/mybucket/file.txt", try url(endpointURL: "https://example.com", bucket: "mybucket", key: "file.txt", forcePathStyle: true))
		XCTAssertEqual("https://example.com/prefix/mybucket/file.txt", try url(endpointURL: "https://example.com/prefix", bucket: "mybucket", key: "file.txt", forcePathStyle: true))
		XCTAssertEqual("https://mybucket.example.com/file.txt", try url(endpointURL: "https://example.com", bucket: "mybucket", key: "file.txt", forcePathStyle: false))
		XCTAssertEqual("https://mybucket.example.com/file.txt", try url(endpointURL: "https://example.com", bucket: "mybucket", key: "file.txt", forcePathStyle: nil))
	}

	func testKeepsSchemeAndNonDefaultPort() throws {
		XCTAssertEqual("http://mybucket.nas:9000/file.txt", try url(endpointURL: "http://nas:9000", bucket: "mybucket", key: "file.txt"))
		XCTAssertEqual("https://mybucket.example.com:8443/file.txt", try url(endpointURL: "https://example.com:8443", bucket: "mybucket", key: "file.txt"))
	}

	func testDropsDefaultPort() throws {
		XCTAssertEqual("https://mybucket.example.com/file.txt", try url(endpointURL: "https://example.com:443", bucket: "mybucket", key: "file.txt"))
		XCTAssertEqual("http://mybucket.example.com/file.txt", try url(endpointURL: "http://example.com:80", bucket: "mybucket", key: "file.txt"))
	}

	func testKeepsPathOfEndpointURL() throws {
		XCTAssertEqual("https://mybucket.example.com/file.txt", try url(endpointURL: "https://example.com/", bucket: "mybucket", key: "file.txt"))
		XCTAssertEqual("https://mybucket.example.com/prefix/file.txt", try url(endpointURL: "https://example.com/prefix/", bucket: "mybucket", key: "file.txt"))
		XCTAssertEqual("https://mybucket.example.com/prefix/", try url(endpointURL: "https://example.com/prefix", bucket: "mybucket", key: ""))
		XCTAssertEqual("https://example.com/prefix/my.bucket/file.txt", try url(endpointURL: "https://example.com/prefix", bucket: "my.bucket", key: "file.txt"))
		XCTAssertEqual("https://example.com/prefix/my.bucket", try url(endpointURL: "https://example.com/prefix", bucket: "my.bucket", key: ""))
	}

	/// S3 checks the signature against the path encoded with the SigV4 rules, so each segment of the path is re-encoded with them rather than sent as the credential's URL encodes it. An escaped slash stays part of its segment.
	func testEncodesPathOfEndpointURLWithSigV4Rules() throws {
		XCTAssertEqual("https://example.com/a%2Bb%20c/my.bucket/file.txt", try url(endpointURL: "https://example.com/a+b%20c", bucket: "my.bucket", key: "file.txt"))
		XCTAssertEqual("https://example.com/tenant%2Farchive/my.bucket/file.txt", try url(endpointURL: "https://example.com/tenant%2Farchive", bucket: "my.bucket", key: "file.txt"))
	}

	func testRejectsEndpointURLThatIsNoAbsoluteHTTPURLWithHost() {
		for endpointURL in ["s3.example.com", "s3.example.com:9000", "https:///bucket", "ftp://example.com"] {
			XCTAssertThrowsError(try makeEndpoint(endpointURL: endpointURL, bucket: "mybucket"), endpointURL) { error in
				XCTAssertEqual(.badURL, (error as? URLError)?.code, endpointURL)
			}
		}
	}

	func testResolvesRelativeEndpointURLAgainstItsBase() throws {
		let endpointURL = try XCTUnwrap(URL(string: "tenant", relativeTo: URL(string: "https://example.com/")))
		let endpoint = try S3Endpoint(credential: S3Credential(accessKey: "", secretKey: "", url: endpointURL, bucket: "mybucket", region: "us-east-1"))
		XCTAssertEqual("https://mybucket.example.com/tenant/file.txt", endpoint.url(forKey: "file.txt").absoluteString)
	}

	func testEncodesQueryCompletely() throws {
		let endpoint = try makeEndpoint(endpointURL: "https://example.com", bucket: "mybucket")
		let url = endpoint.url(forKey: "", query: [URLQueryItem(name: "prefix", value: "a+b/c=d?e;f:g@h i"), URLQueryItem(name: "uploads", value: nil)])
		XCTAssertEqual("prefix=a%2Bb%2Fc%3Dd%3Fe%3Bf%3Ag%40h%20i&uploads", URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
	}

	// MARK: - Relocation

	func testRelocatesOnlyOrdinaryAWSHosts() throws {
		let cases: [(endpointURL: String, relocatedURL: String?)] = [
			("https://s3.amazonaws.com", "https://s3.eu-central-1.amazonaws.com"),
			("https://s3.us-east-1.amazonaws.com", "https://s3.eu-central-1.amazonaws.com"),
			("https://S3.US-EAST-1.AMAZONAWS.COM", "https://s3.eu-central-1.amazonaws.com"),
			("https://s3.dualstack.us-east-1.amazonaws.com", "https://s3.dualstack.eu-central-1.amazonaws.com"),
			("https://s3.cn-north-1.amazonaws.com.cn", "https://s3.eu-central-1.amazonaws.com.cn"),
			("https://s3.dualstack.cn-north-1.amazonaws.com.cn", "https://s3.dualstack.eu-central-1.amazonaws.com.cn"),
			("https://s3.dualstack.amazonaws.com", nil),
			("https://s3.amazonaws.com.cn", nil),
			("https://s3-fips.us-east-1.amazonaws.com", nil),
			("https://s3.fips.us-east-1.amazonaws.com", nil),
			("https://s3-accelerate.amazonaws.com", nil),
			("https://s3-us-west-2.amazonaws.com", nil),
			("https://bucket.vpce-1a2b3c4d-5e6f.s3.us-east-1.vpce.amazonaws.com", nil),
			("https://s3.us-east-1.amazonaws.com.evil.com", nil),
			("https://s3.fr-par.scw.cloud", nil),
			("https://minio.example.com", nil)
		]
		for (endpointURL, relocatedURL) in cases {
			XCTAssertEqual(relocatedURL, try S3Endpoint.relocatedURL(XCTUnwrap(URL(string: endpointURL)), toRegion: "eu-central-1")?.absoluteString, endpointURL)
		}
	}

	func testDoesNotRelocateToInvalidRegion() throws {
		let endpointURL = try XCTUnwrap(URL(string: "https://s3.us-east-1.amazonaws.com"))
		for region in ["eu-west-1/x", "", "eu-west-1.evil.com"] {
			XCTAssertNil(S3Endpoint.relocatedURL(endpointURL, toRegion: region), region)
		}
	}

	func testRelocationKeepsSchemePortPathAndQuery() throws {
		let endpointURL = try XCTUnwrap(URL(string: "http://s3.us-east-1.amazonaws.com:8080/prefix?x=1"))
		XCTAssertEqual("http://s3.eu-central-1.amazonaws.com:8080/prefix?x=1", S3Endpoint.relocatedURL(endpointURL, toRegion: "eu-central-1")?.absoluteString)
	}

	// MARK: - Helpers

	private func url(endpointURL: String, bucket: String, key: String, forcePathStyle: Bool? = nil) throws -> String {
		return try makeEndpoint(endpointURL: endpointURL, bucket: bucket, forcePathStyle: forcePathStyle).url(forKey: key).absoluteString
	}

	private func makeEndpoint(endpointURL: String, bucket: String, forcePathStyle: Bool? = nil) throws -> S3Endpoint {
		return try S3Endpoint(credential: S3Credential(accessKey: "", secretKey: "", url: XCTUnwrap(URL(string: endpointURL)), bucket: bucket, region: "us-east-1", forcePathStyle: forcePathStyle))
	}
}
