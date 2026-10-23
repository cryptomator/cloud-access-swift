//
//  S3CredentialTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 23.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class S3CredentialTests: XCTestCase {
	/// The app stores credentials as JSON, and one that no longer decodes loses its account.
	func testDecodesStoredCredentialWithoutForcePathStyle() throws {
		let json = Data(#"{"accessKey":"access","secretKey":"secret","url":"https:\/\/s3.example.com","bucket":"examplebucket","region":"us-east-1","identifier":"ID"}"#.utf8)

		let credential = try JSONDecoder().decode(S3Credential.self, from: json)

		XCTAssertNil(credential.forcePathStyle)
		XCTAssertEqual(try S3Credential(accessKey: "access", secretKey: "secret", url: XCTUnwrap(URL(string: "https://s3.example.com")), bucket: "examplebucket", region: "us-east-1", identifier: "ID"), credential)
	}

	/// A credential stored with forced path style must keep it, so its stored JSON key must not change.
	func testDecodesStoredForcePathStyle() throws {
		let json = Data(#"{"accessKey":"access","secretKey":"secret","url":"https:\/\/s3.example.com","bucket":"examplebucket","region":"us-east-1","forcePathStyle":true,"identifier":"ID"}"#.utf8)

		XCTAssertEqual(true, try JSONDecoder().decode(S3Credential.self, from: json).forcePathStyle)
	}

	func testEncodesForcePathStyleUnderItsStoredKey() throws {
		let credential = try S3Credential(accessKey: "access", secretKey: "secret", url: XCTUnwrap(URL(string: "https://s3.example.com")), bucket: "examplebucket", region: "us-east-1", forcePathStyle: true, identifier: "ID")

		let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(credential)) as? [String: Any])
		XCTAssertEqual(true, object["forcePathStyle"] as? Bool)
	}
}
