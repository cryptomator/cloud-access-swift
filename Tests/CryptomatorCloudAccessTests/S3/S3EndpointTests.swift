//
//  S3EndpointTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct S3EndpointTests {
		@Test
		func virtualHostedStyleForDNSCompatibleBucket() throws {
			#expect(try url(endpointURL: "https://example.com", bucket: "mybucket", key: "folder/file.txt") == "https://mybucket.example.com/folder/file.txt")
			#expect(try url(endpointURL: "https://example.com", bucket: "mybucket", key: "") == "https://mybucket.example.com/")
		}

		@Test
		func pathStyleForOtherBuckets() throws {
			#expect(try url(endpointURL: "https://example.com", bucket: "my.bucket", key: "file.txt") == "https://example.com/my.bucket/file.txt")
			#expect(try url(endpointURL: "https://example.com", bucket: "My_Bucket", key: "file.txt") == "https://example.com/My_Bucket/file.txt")
			#expect(try url(endpointURL: "https://example.com", bucket: "ab", key: "file.txt") == "https://example.com/ab/file.txt")
			#expect(try url(endpointURL: "https://example.com", bucket: "MyBucket", key: "file.txt") == "https://example.com/MyBucket/file.txt")
			#expect(try url(endpointURL: "https://example.com", bucket: "bucket-", key: "file.txt") == "https://example.com/bucket-/file.txt")
			let longBucket = String(repeating: "b", count: 64)
			#expect(try url(endpointURL: "https://example.com", bucket: longBucket, key: "file.txt") == "https://example.com/\(longBucket)/file.txt")
			#expect(try url(endpointURL: "https://example.com", bucket: "my.bucket", key: "") == "https://example.com/my.bucket")
		}

		@Test
		func virtualHostedStyleUpToMaximumBucketLength() throws {
			let bucket = String(repeating: "b", count: 63)
			#expect(try url(endpointURL: "https://example.com", bucket: bucket, key: "file.txt") == "https://\(bucket).example.com/file.txt")
		}

		@Test
		func pathStyleForIPAddressHost() throws {
			#expect(try url(endpointURL: "http://[fd00::1]:9000", bucket: "mybucket", key: "file.txt") == "http://[fd00::1]:9000/mybucket/file.txt")
			#expect(try url(endpointURL: "http://192.168.1.10:9000", bucket: "mybucket", key: "file.txt") == "http://192.168.1.10:9000/mybucket/file.txt")
			#expect(try url(endpointURL: "https://127.1", bucket: "mybucket", key: "file.txt") == "https://127.1/mybucket/file.txt")
			#expect(try url(endpointURL: "http://192.168.1.09:9000", bucket: "mybucket", key: "file.txt") == "http://192.168.1.09:9000/mybucket/file.txt")
		}

		@Test
		func virtualHostedStyleForHostnameContainingIPAddress() throws {
			#expect(try url(endpointURL: "http://127.0.0.1.nip.io:9000", bucket: "mybucket", key: "file.txt") == "http://mybucket.127.0.0.1.nip.io:9000/file.txt")
		}

		/// Such buckets pass the DNS rule of AWS SDK 2.41.0, but a host can't contain them.
		@Test
		func pathStyleForBucketsWithCharactersInvalidInHost() throws {
			#expect(try url(endpointURL: "https://example.com", bucket: "bücket", key: "file.txt") == "https://example.com/b%C3%BCcket/file.txt")
			#expect(try url(endpointURL: "https://example.com", bucket: "my bucket", key: "file.txt") == "https://example.com/my%20bucket/file.txt")
			#expect(try url(endpointURL: "https://example.com", bucket: "my:bucket", key: "file.txt") == "https://example.com/my%3Abucket/file.txt")
			#expect(try url(endpointURL: "https://example.com", bucket: "my%bucket", key: "file.txt") == "https://example.com/my%25bucket/file.txt")
			#expect(try url(endpointURL: "https://example.com", bucket: "my/bucket", key: "file.txt") == "https://example.com/my%2Fbucket/file.txt")
			#expect(try url(endpointURL: "https://example.com", bucket: "my#bucket", key: "file.txt") == "https://example.com/my%23bucket/file.txt")
		}

		@Test
		func forcedPathStyleForDNSCompatibleBucket() throws {
			#expect(try url(endpointURL: "https://example.com", bucket: "mybucket", key: "file.txt", forcePathStyle: true) == "https://example.com/mybucket/file.txt")
			#expect(try url(endpointURL: "https://example.com/prefix", bucket: "mybucket", key: "file.txt", forcePathStyle: true) == "https://example.com/prefix/mybucket/file.txt")
			#expect(try url(endpointURL: "https://example.com", bucket: "mybucket", key: "file.txt", forcePathStyle: false) == "https://mybucket.example.com/file.txt")
			#expect(try url(endpointURL: "https://example.com", bucket: "mybucket", key: "file.txt", forcePathStyle: nil) == "https://mybucket.example.com/file.txt")
		}

		@Test
		func keepsSchemeAndNonDefaultPort() throws {
			#expect(try url(endpointURL: "http://nas:9000", bucket: "mybucket", key: "file.txt") == "http://mybucket.nas:9000/file.txt")
			#expect(try url(endpointURL: "https://example.com:8443", bucket: "mybucket", key: "file.txt") == "https://mybucket.example.com:8443/file.txt")
		}

		@Test
		func dropsDefaultPort() throws {
			#expect(try url(endpointURL: "https://example.com:443", bucket: "mybucket", key: "file.txt") == "https://mybucket.example.com/file.txt")
			#expect(try url(endpointURL: "http://example.com:80", bucket: "mybucket", key: "file.txt") == "http://mybucket.example.com/file.txt")
		}

		@Test
		func keepsPathOfEndpointURL() throws {
			#expect(try url(endpointURL: "https://example.com/", bucket: "mybucket", key: "file.txt") == "https://mybucket.example.com/file.txt")
			#expect(try url(endpointURL: "https://example.com/prefix/", bucket: "mybucket", key: "file.txt") == "https://mybucket.example.com/prefix/file.txt")
			#expect(try url(endpointURL: "https://example.com/prefix", bucket: "mybucket", key: "") == "https://mybucket.example.com/prefix/")
			#expect(try url(endpointURL: "https://example.com/prefix", bucket: "my.bucket", key: "file.txt") == "https://example.com/prefix/my.bucket/file.txt")
			#expect(try url(endpointURL: "https://example.com/prefix", bucket: "my.bucket", key: "") == "https://example.com/prefix/my.bucket")
		}

		/// S3 checks the signature against the path encoded with the SigV4 rules, so each segment of the path is re-encoded with them rather than sent as the credential's URL encodes it. An escaped slash stays part of its segment.
		@Test
		func encodesPathOfEndpointURLWithSigV4Rules() throws {
			#expect(try url(endpointURL: "https://example.com/a+b%20c", bucket: "my.bucket", key: "file.txt") == "https://example.com/a%2Bb%20c/my.bucket/file.txt")
			#expect(try url(endpointURL: "https://example.com/tenant%2Farchive", bucket: "my.bucket", key: "file.txt") == "https://example.com/tenant%2Farchive/my.bucket/file.txt")
		}

		@Test
		func rejectsEndpointURLThatIsNoAbsoluteHTTPURLWithHost() throws {
			for endpointURL in ["s3.example.com", "s3.example.com:9000", "https:///bucket", "ftp://example.com"] {
				let error = try #require(throws: (any Error).self, "\(endpointURL)") { try makeEndpoint(endpointURL: endpointURL, bucket: "mybucket") }
				#expect((error as? URLError)?.code == .badURL, "\(endpointURL)")
			}
		}

		@Test
		func resolvesRelativeEndpointURLAgainstItsBase() throws {
			let endpointURL = try #require(URL(string: "tenant", relativeTo: URL(string: "https://example.com/")))
			let endpoint = try S3Endpoint(credential: S3Credential(accessKey: "", secretKey: "", url: endpointURL, bucket: "mybucket", region: "us-east-1"))
			#expect(endpoint.url(forKey: "file.txt").absoluteString == "https://mybucket.example.com/tenant/file.txt")
		}

		@Test
		func encodesQueryCompletely() throws {
			let endpoint = try makeEndpoint(endpointURL: "https://example.com", bucket: "mybucket")
			let url = endpoint.url(forKey: "", query: [URLQueryItem(name: "prefix", value: "a+b/c=d?e;f:g@h i"), URLQueryItem(name: "uploads", value: nil)])
			#expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery == "prefix=a%2Bb%2Fc%3Dd%3Fe%3Bf%3Ag%40h%20i&uploads")
		}

		// MARK: - Relocation

		@Test
		func relocatesOnlyOrdinaryAWSHosts() throws {
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
				#expect(try relocatedURL == S3Endpoint.relocatedURL(#require(URL(string: endpointURL)), toRegion: "eu-central-1")?.absoluteString, "\(endpointURL)")
			}
		}

		@Test
		func doesNotRelocateToInvalidRegion() throws {
			let endpointURL = try #require(URL(string: "https://s3.us-east-1.amazonaws.com"))
			for region in ["eu-west-1/x", "", "eu-west-1.evil.com"] {
				#expect(S3Endpoint.relocatedURL(endpointURL, toRegion: region) == nil, "\(region)")
			}
		}

		@Test
		func relocationKeepsSchemePortPathAndQuery() throws {
			let endpointURL = try #require(URL(string: "http://s3.us-east-1.amazonaws.com:8080/prefix?x=1"))
			#expect(S3Endpoint.relocatedURL(endpointURL, toRegion: "eu-central-1")?.absoluteString == "http://s3.eu-central-1.amazonaws.com:8080/prefix?x=1")
		}

		// MARK: - Helpers

		private func url(endpointURL: String, bucket: String, key: String, forcePathStyle: Bool? = nil) throws -> String {
			return try makeEndpoint(endpointURL: endpointURL, bucket: bucket, forcePathStyle: forcePathStyle).url(forKey: key).absoluteString
		}

		private func makeEndpoint(endpointURL: String, bucket: String, forcePathStyle: Bool? = nil) throws -> S3Endpoint {
			return try S3Endpoint(credential: S3Credential(accessKey: "", secretKey: "", url: #require(URL(string: endpointURL)), bucket: bucket, region: "us-east-1", forcePathStyle: forcePathStyle))
		}
	}
}
