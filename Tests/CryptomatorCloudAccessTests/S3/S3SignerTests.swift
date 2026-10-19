//
//  S3SignerTests.swift
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

/// The signature examples are the ones that the AWS documentation of Signature Version 4 for S3 publishes.
class S3SignerTests: XCTestCase {
	private let signer = S3Signer(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
	/// 2013-05-24T00:00:00Z
	private let date = Date(timeIntervalSince1970: 1_369_353_600)
	private let credentialPrefix = "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request"

	// MARK: - Authorization Header

	func testGetObjectWithRange() throws {
		var request = try URLRequest(url: XCTUnwrap(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")))
		request.setValue("bytes=0-9", forHTTPHeaderField: "Range")

		signer.sign(&request, payloadHash: S3Signer.emptyPayloadHash, date: date)

		XCTAssertEqual("20130524T000000Z", request.value(forHTTPHeaderField: "x-amz-date"))
		XCTAssertEqual("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", request.value(forHTTPHeaderField: "x-amz-content-sha256"))
		XCTAssertEqual("\(credentialPrefix), SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", request.value(forHTTPHeaderField: "Authorization"))
	}

	func testPutObject() throws {
		let endpoint = try S3Endpoint(credential: S3Credential(accessKey: "", secretKey: "", url: XCTUnwrap(URL(string: "https://s3.amazonaws.com")), bucket: "examplebucket", region: "us-east-1"))
		var request = URLRequest(url: endpoint.url(forKey: "test$file.text"))
		request.httpMethod = "PUT"
		request.httpBody = Data("Welcome to Amazon S3.".utf8)
		request.setValue("Fri, 24 May 2013 00:00:00 GMT", forHTTPHeaderField: "Date")
		request.setValue("REDUCED_REDUNDANCY", forHTTPHeaderField: "x-amz-storage-class")
		let payloadHash = try S3Signer.sha256Hex(XCTUnwrap(request.httpBody))

		signer.sign(&request, payloadHash: payloadHash, date: date)

		XCTAssertEqual("https://examplebucket.s3.amazonaws.com/test%24file.text", request.url?.absoluteString)
		XCTAssertEqual("44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072", payloadHash)
		XCTAssertEqual("\(credentialPrefix), SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd", request.value(forHTTPHeaderField: "Authorization"))
	}

	func testGetBucketLifecycle() throws {
		var request = try URLRequest(url: XCTUnwrap(URL(string: "https://examplebucket.s3.amazonaws.com/?lifecycle")))

		signer.sign(&request, payloadHash: S3Signer.emptyPayloadHash, date: date)

		XCTAssertEqual("\(credentialPrefix), SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543", request.value(forHTTPHeaderField: "Authorization"))
	}

	func testListObjects() throws {
		var request = try URLRequest(url: XCTUnwrap(URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")))

		signer.sign(&request, payloadHash: S3Signer.emptyPayloadHash, date: date)

		XCTAssertEqual("\(credentialPrefix), SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7", request.value(forHTTPHeaderField: "Authorization"))
	}

	// MARK: - Presigned URL

	func testPresignedGetObject() throws {
		let url = try signer.presignedURL(method: "GET", url: XCTUnwrap(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")), headers: [:], expiresIn: 86400, date: date)

		XCTAssertEqual("https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404", url.absoluteString)
	}

	// MARK: - Encoding

	/// The canonical URI is the sent path, and the canonical query is the sent query sorted by name.
	func testCanonicalRequestUsesSentPathAndSortedQuery() throws {
		let endpoint = try S3Endpoint(credential: S3Credential(accessKey: "", secretKey: "", url: XCTUnwrap(URL(string: "https://example.com")), bucket: "mybucket", region: "us-east-1"))
		let query = [URLQueryItem(name: "list-type", value: "2"), URLQueryItem(name: "prefix", value: "a b"), URLQueryItem(name: "max-keys", value: "1000"), URLQueryItem(name: "continuation-token", value: "a+b/c=")]
		let url = endpoint.url(forKey: "folder/a b+ü.txt", query: query)
		let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

		let lines = S3Signer.canonicalRequest(method: "GET", url: url, headers: [], payloadHash: S3Signer.emptyPayloadHash).components(separatedBy: "\n")

		XCTAssertEqual("/folder/a%20b%2B%C3%BC.txt", lines[1])
		XCTAssertEqual(components.percentEncodedPath, lines[1])
		XCTAssertEqual("list-type=2&prefix=a%20b&max-keys=1000&continuation-token=a%2Bb%2Fc%3D", components.percentEncodedQuery)
		XCTAssertEqual("continuation-token=a%2Bb%2Fc%3D&list-type=2&max-keys=1000&prefix=a%20b", lines[2])
	}

	func testCanonicalHostCarriesExplicitPort() throws {
		let headers = try S3Signer.canonicalHeaders(url: XCTUnwrap(URL(string: "http://nas:9000/mybucket/key")), headers: [:])
		XCTAssertEqual("nas:9000", headers.first { $0.name == "host" }?.value)
	}

	/// URLSession sends the host lowercased.
	func testCanonicalHostIsLowercased() throws {
		let headers = try S3Signer.canonicalHeaders(url: XCTUnwrap(URL(string: "https://mybucket.S3.Example.com/key")), headers: [:])
		XCTAssertEqual("mybucket.s3.example.com", headers.first { $0.name == "host" }?.value)
	}

	func testCanonicalHostKeepsIPv6Brackets() throws {
		let headers = try S3Signer.canonicalHeaders(url: XCTUnwrap(URL(string: "http://[fd00::1]:9000/mybucket/key")), headers: [:])
		XCTAssertEqual("[fd00::1]:9000", headers.first { $0.name == "host" }?.value)
	}

	// MARK: - Region

	func testSigningRegionCanonicalizesSDKAliases() {
		XCTAssertEqual("us-east-1", S3Signer.signingRegion(for: "USEast1"))
		XCTAssertEqual("us-east-1", S3Signer.signingRegion(for: "AWSRegionUSEast1"))
		XCTAssertEqual("cn-northwest-1", S3Signer.signingRegion(for: "CNNorthWest1"))
		XCTAssertEqual("us-east-1", S3Signer.signingRegion(for: "us-east-1"))
	}

	func testSigningRegionKeepsOtherRegions() {
		XCTAssertEqual("nl-ams", S3Signer.signingRegion(for: "nl-ams"))
		XCTAssertEqual("fr-par", S3Signer.signingRegion(for: "fr-par"))
		XCTAssertEqual("EUFrankfurt1", S3Signer.signingRegion(for: "EUFrankfurt1"))
		XCTAssertEqual("useast1", S3Signer.signingRegion(for: "useast1"))
	}
}
