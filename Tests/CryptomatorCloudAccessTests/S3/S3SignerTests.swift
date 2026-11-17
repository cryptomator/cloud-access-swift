//
//  S3SignerTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	/// The signature examples are the ones that the AWS documentation of Signature Version 4 for S3 publishes.
	struct S3SignerTests {
		private let signer = S3Signer(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
		/// 2013-05-24T00:00:00Z
		private let date = Date(timeIntervalSince1970: 1_369_353_600)
		private let credentialPrefix = "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request"

		// MARK: - Authorization Header

		@Test
		func getObjectWithRange() throws {
			var request = try URLRequest(url: #require(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")))
			request.setValue("bytes=0-9", forHTTPHeaderField: "Range")

			signer.sign(&request, payloadHash: S3Signer.emptyPayloadHash, date: date)

			#expect(request.value(forHTTPHeaderField: "x-amz-date") == "20130524T000000Z")
			#expect(request.value(forHTTPHeaderField: "x-amz-content-sha256") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
			#expect(request.value(forHTTPHeaderField: "Authorization") == "\(credentialPrefix), SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
		}

		@Test
		func putObject() throws {
			let endpoint = try S3Endpoint(credential: S3Credential(accessKey: "", secretKey: "", url: #require(URL(string: "https://s3.amazonaws.com")), bucket: "examplebucket", region: "us-east-1"))
			var request = URLRequest(url: endpoint.url(forKey: "test$file.text"))
			request.httpMethod = "PUT"
			request.httpBody = Data("Welcome to Amazon S3.".utf8)
			request.setValue("Fri, 24 May 2013 00:00:00 GMT", forHTTPHeaderField: "Date")
			request.setValue("REDUCED_REDUNDANCY", forHTTPHeaderField: "x-amz-storage-class")
			let payloadHash = try S3Signer.sha256Hex(#require(request.httpBody))

			signer.sign(&request, payloadHash: payloadHash, date: date)

			#expect(request.url?.absoluteString == "https://examplebucket.s3.amazonaws.com/test%24file.text")
			#expect(payloadHash == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
			#expect(request.value(forHTTPHeaderField: "Authorization") == "\(credentialPrefix), SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
		}

		@Test
		func getBucketLifecycle() throws {
			var request = try URLRequest(url: #require(URL(string: "https://examplebucket.s3.amazonaws.com/?lifecycle")))

			signer.sign(&request, payloadHash: S3Signer.emptyPayloadHash, date: date)

			#expect(request.value(forHTTPHeaderField: "Authorization") == "\(credentialPrefix), SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
		}

		@Test
		func listObjects() throws {
			var request = try URLRequest(url: #require(URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")))

			signer.sign(&request, payloadHash: S3Signer.emptyPayloadHash, date: date)

			#expect(request.value(forHTTPHeaderField: "Authorization") == "\(credentialPrefix), SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
		}

		// MARK: - Presigned URL

		@Test
		func presignedGetObject() throws {
			let url = try signer.presignedURL(method: "GET", url: #require(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")), headers: [:], expiresIn: 86400, date: date)

			#expect(url.absoluteString == "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
		}

		// MARK: - Encoding

		/// The canonical URI is the sent path, and the canonical query is the sent query sorted by name.
		@Test
		func canonicalRequestUsesSentPathAndSortedQuery() throws {
			let endpoint = try S3Endpoint(credential: S3Credential(accessKey: "", secretKey: "", url: #require(URL(string: "https://example.com")), bucket: "mybucket", region: "us-east-1"))
			let query = [URLQueryItem(name: "list-type", value: "2"), URLQueryItem(name: "prefix", value: "a b"), URLQueryItem(name: "max-keys", value: "1000"), URLQueryItem(name: "continuation-token", value: "a+b/c=")]
			let url = endpoint.url(forKey: "folder/a b+ü.txt", query: query)
			let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

			let lines = S3Signer.canonicalRequest(method: "GET", url: url, headers: [], payloadHash: S3Signer.emptyPayloadHash).components(separatedBy: "\n")

			#expect(lines[1] == "/folder/a%20b%2B%C3%BC.txt")
			#expect(components.percentEncodedPath == lines[1])
			#expect(components.percentEncodedQuery == "list-type=2&prefix=a%20b&max-keys=1000&continuation-token=a%2Bb%2Fc%3D")
			#expect(lines[2] == "continuation-token=a%2Bb%2Fc%3D&list-type=2&max-keys=1000&prefix=a%20b")
		}

		@Test
		func canonicalHostCarriesExplicitPort() throws {
			let headers = try S3Signer.canonicalHeaders(url: #require(URL(string: "http://nas:9000/mybucket/key")), headers: [:])
			#expect(headers.first { $0.name == "host" }?.value == "nas:9000")
		}

		/// URLSession sends the host lowercased.
		@Test
		func canonicalHostIsLowercased() throws {
			let headers = try S3Signer.canonicalHeaders(url: #require(URL(string: "https://mybucket.S3.Example.com/key")), headers: [:])
			#expect(headers.first { $0.name == "host" }?.value == "mybucket.s3.example.com")
		}

		@Test
		func canonicalHostKeepsIPv6Brackets() throws {
			let headers = try S3Signer.canonicalHeaders(url: #require(URL(string: "http://[fd00::1]:9000/mybucket/key")), headers: [:])
			#expect(headers.first { $0.name == "host" }?.value == "[fd00::1]:9000")
		}

		// MARK: - Region

		@Test
		func signingRegionCanonicalizesSDKAliases() {
			#expect(S3Signer.signingRegion(for: "USEast1") == "us-east-1")
			#expect(S3Signer.signingRegion(for: "AWSRegionUSEast1") == "us-east-1")
			#expect(S3Signer.signingRegion(for: "CNNorthWest1") == "cn-northwest-1")
			#expect(S3Signer.signingRegion(for: "us-east-1") == "us-east-1")
		}

		@Test
		func signingRegionKeepsOtherRegions() {
			#expect(S3Signer.signingRegion(for: "nl-ams") == "nl-ams")
			#expect(S3Signer.signingRegion(for: "fr-par") == "fr-par")
			#expect(S3Signer.signingRegion(for: "EUFrankfurt1") == "EUFrankfurt1")
			#expect(S3Signer.signingRegion(for: "useast1") == "useast1")
		}
	}
}
