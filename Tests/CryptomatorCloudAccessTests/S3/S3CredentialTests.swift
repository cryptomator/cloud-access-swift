//
//  S3CredentialTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 23.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct S3CredentialTests {
		/// The app stores credentials as JSON, and one that no longer decodes loses its account.
		@Test
		func decodesStoredCredentialWithoutForcePathStyle() throws {
			let json = Data(#"{"accessKey":"access","secretKey":"secret","url":"https:\/\/s3.example.com","bucket":"examplebucket","region":"us-east-1","identifier":"ID"}"#.utf8)

			let credential = try JSONDecoder().decode(S3Credential.self, from: json)

			#expect(credential.forcePathStyle == nil)
			#expect(try S3Credential(accessKey: "access", secretKey: "secret", url: #require(URL(string: "https://s3.example.com")), bucket: "examplebucket", region: "us-east-1", identifier: "ID") == credential)
		}

		/// A credential stored with forced path style must keep it, so its stored JSON key must not change.
		@Test
		func decodesStoredForcePathStyle() throws {
			let json = Data(#"{"accessKey":"access","secretKey":"secret","url":"https:\/\/s3.example.com","bucket":"examplebucket","region":"us-east-1","forcePathStyle":true,"identifier":"ID"}"#.utf8)

			#expect(try JSONDecoder().decode(S3Credential.self, from: json).forcePathStyle == true)
		}

		@Test
		func encodesForcePathStyleUnderItsStoredKey() throws {
			let credential = try S3Credential(accessKey: "access", secretKey: "secret", url: #require(URL(string: "https://s3.example.com")), bucket: "examplebucket", region: "us-east-1", forcePathStyle: true, identifier: "ID")

			let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(credential)) as? [String: Any])
			#expect((object["forcePathStyle"] as? Bool) == true)
		}
	}
}
