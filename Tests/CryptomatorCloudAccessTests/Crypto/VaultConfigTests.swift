//
//  VaultConfigTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 03.03.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import JOSESwift
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class VaultConfigTests: XCTestCase {
	func testCreateNew() {
		let vaultConfig = VaultConfig.createNew(format: 8, cipherCombo: .sivCTRMAC, shorteningThreshold: 220)
		XCTAssertEqual(8, vaultConfig.format)
		XCTAssertEqual(.sivCTRMAC, vaultConfig.cipherCombo)
		XCTAssertEqual(220, vaultConfig.shorteningThreshold)
	}

	func testLoad() throws {
		let token = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6Im1hc3RlcmtleWZpbGU6bWFzdGVya2V5LmNyeXB0b21hdG9yIn0.eyJqdGkiOiJBQkI5RjY3My1GM0U4LTQxQTctQTQzQi1EMjlGNURBNjUwNjgiLCJzaG9ydGVuaW5nVGhyZXNob2xkIjoyMjAsImNpcGhlckNvbWJvIjoiU0lWX0NUUk1BQyIsImZvcm1hdCI6OH0.A66mLMcdcpAeJ1zCW2fcsSNznqoD7gWqO-OSE8pY2sg".data(using: .utf8)!
		let rawKey = [UInt8](repeating: 0x55, count: 64)
		let vaultConfig = try VaultConfig.load(token: token, rawKey: rawKey)
		XCTAssertEqual(8, vaultConfig.format)
		XCTAssertEqual(.sivCTRMAC, vaultConfig.cipherCombo)
		XCTAssertEqual(220, vaultConfig.shorteningThreshold)
	}

	func testLoadWithMalformedToken() throws {
		let token = "hello world".data(using: .utf8)!
		let rawKey = [UInt8](repeating: 0x55, count: 64)
		XCTAssertThrowsError(try VaultConfig.load(token: token, rawKey: rawKey), "input was not a valid token") { error in
			guard case JOSESwiftError.invalidCompactSerializationComponentCount(count: 1) = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
		}
	}

	func testLoadWithInvalidKey() throws {
		let token = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6Im1hc3RlcmtleWZpbGU6bWFzdGVya2V5LmNyeXB0b21hdG9yIn0.eyJqdGkiOiJBQkI5RjY3My1GM0U4LTQxQTctQTQzQi1EMjlGNURBNjUwNjgiLCJzaG9ydGVuaW5nVGhyZXNob2xkIjoyMjAsImNpcGhlckNvbWJvIjoiU0lWX0NUUk1BQyIsImZvcm1hdCI6OH0.A66mLMcdcpAeJ1zCW2fcsSNznqoD7gWqO-OSE8pY2sg".data(using: .utf8)!
		let rawKey = [UInt8](repeating: 0x77, count: 64)
		XCTAssertThrowsError(try VaultConfig.load(token: token, rawKey: rawKey), "signature verification failed") { error in
			guard case JOSESwiftError.verifyingFailed(description: JOSESwiftError.signatureInvalid.localizedDescription) = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
		}
	}

	func testToToken() throws {
		let vaultConfig = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 8, cipherCombo: .sivCTRMAC, shorteningThreshold: 220)
		let rawKey = [UInt8](repeating: 0x55, count: 64)
		let token = try vaultConfig.toToken(keyId: "masterkeyfile:masterkey.cryptomator", rawKey: rawKey)
		let tokenComponents = String(data: token, encoding: .utf8)!.split(separator: ".")
		// check header
		let header: [String: String] = try decodeTokenComponent(String(tokenComponents[0]))
		XCTAssertEqual(["typ": "JWT", "alg": "HS256", "kid": "masterkeyfile:masterkey.cryptomator"], header)
		// check payload
		let payload: VaultConfigPayload = try decodeTokenComponent(String(tokenComponents[1]))
		XCTAssertEqual(VaultConfigPayload(jti: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 8, cipherCombo: .sivCTRMAC, shorteningThreshold: 220), payload)
		// skip signature check
	}

	// MARK: - Helpers

	private func decodeTokenComponent<T: Decodable>(_ tokenComponent: String) throws -> T {
		let jsonDecoder = JSONDecoder()
		let data = Data(base64URLEncoded: String(tokenComponent))!
		return try jsonDecoder.decode(T.self, from: data)
	}
}
