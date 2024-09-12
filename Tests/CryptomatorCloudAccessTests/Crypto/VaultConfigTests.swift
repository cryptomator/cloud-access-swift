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
	let tokenNone = Data("eyJraWQiOiJURVNUX0tFWSIsInR5cCI6IkpXVCIsImFsZyI6Im5vbmUifQ.eyJmb3JtYXQiOjgsInNob3J0ZW5pbmdUaHJlc2hvbGQiOjIyMCwianRpIjoiZjRiMjlmM2EtNDdkNi00NjlmLTk2NGMtZjRjMmRhZWU4ZWI2IiwiY2lwaGVyQ29tYm8iOiJTSVZfQ1RSTUFDIn0.".utf8)
	let tokenHS256 = Data("eyJraWQiOiJURVNUX0tFWSIsInR5cCI6IkpXVCIsImFsZyI6IkhTMjU2In0.eyJmb3JtYXQiOjgsInNob3J0ZW5pbmdUaHJlc2hvbGQiOjIyMCwianRpIjoiZjRiMjlmM2EtNDdkNi00NjlmLTk2NGMtZjRjMmRhZWU4ZWI2IiwiY2lwaGVyQ29tYm8iOiJTSVZfQ1RSTUFDIn0.V7pqSXX1tBRgmntL1sXovnhNR4Z1_7z3Jzrq7NMqPO8".utf8)
	let tokenHS384 = Data("eyJraWQiOiJURVNUX0tFWSIsInR5cCI6IkpXVCIsImFsZyI6IkhTMzg0In0.eyJmb3JtYXQiOjgsInNob3J0ZW5pbmdUaHJlc2hvbGQiOjIyMCwianRpIjoiZjRiMjlmM2EtNDdkNi00NjlmLTk2NGMtZjRjMmRhZWU4ZWI2IiwiY2lwaGVyQ29tYm8iOiJTSVZfQ1RSTUFDIn0.rx03sCVAyrCmT6halPaFU46lu-DOd03iwDgvdw362hfgJj782q6xPXjAxdKeVKxG".utf8)
	let tokenHS512 = Data("eyJraWQiOiJURVNUX0tFWSIsInR5cCI6IkpXVCIsImFsZyI6IkhTNTEyIn0.eyJmb3JtYXQiOjgsInNob3J0ZW5pbmdUaHJlc2hvbGQiOjIyMCwianRpIjoiZjRiMjlmM2EtNDdkNi00NjlmLTk2NGMtZjRjMmRhZWU4ZWI2IiwiY2lwaGVyQ29tYm8iOiJTSVZfQ1RSTUFDIn0.fzkVI34Ou3z7RaFarS9VPCaA0NX9z7My14gAISTXJGKGNSID7xEcoaY56SBdWbU7Ta17KhxcHhbXffxk3Mzing".utf8)

	func testCreateNew() {
		let vaultConfig = VaultConfig.createNew(format: 8, cipherCombo: .sivCtrMac, shorteningThreshold: 220)
		XCTAssertEqual(8, vaultConfig.format)
		XCTAssertEqual(.sivCtrMac, vaultConfig.cipherCombo)
		XCTAssertEqual(220, vaultConfig.shorteningThreshold)
	}

	func testUnsupportedSignature() throws {
		let rawKey = [UInt8](repeating: 0x55, count: 64)
		XCTAssertThrowsError(try VaultConfig.load(token: tokenNone, rawKey: rawKey), "unsupported signature algorithm: none") { error in
			guard case VaultConfigError.unsupportedAlgorithm = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
		}
	}

	func testSuccessfulLoadHS256() throws {
		let rawKey = [UInt8](repeating: 0x55, count: 64)
		let vaultConfig = try VaultConfig.load(token: tokenHS256, rawKey: rawKey)
		XCTAssertEqual(8, vaultConfig.format)
		XCTAssertEqual(.sivCtrMac, vaultConfig.cipherCombo)
		XCTAssertEqual(220, vaultConfig.shorteningThreshold)
	}

	func testSuccessfulLoadHS384() throws {
		let rawKey = [UInt8](repeating: 0x55, count: 64)
		let vaultConfig = try VaultConfig.load(token: tokenHS384, rawKey: rawKey)
		XCTAssertEqual(8, vaultConfig.format)
		XCTAssertEqual(.sivCtrMac, vaultConfig.cipherCombo)
		XCTAssertEqual(220, vaultConfig.shorteningThreshold)
	}

	func testSuccessfulLoadHS512() throws {
		let rawKey = [UInt8](repeating: 0x55, count: 64)
		let vaultConfig = try VaultConfig.load(token: tokenHS512, rawKey: rawKey)
		XCTAssertEqual(8, vaultConfig.format)
		XCTAssertEqual(.sivCtrMac, vaultConfig.cipherCombo)
		XCTAssertEqual(220, vaultConfig.shorteningThreshold)
	}

	func testLoadWithMalformedToken() throws {
		let token = Data("hello world".utf8)
		let rawKey = [UInt8](repeating: 0x55, count: 64)
		XCTAssertThrowsError(try VaultConfig.load(token: token, rawKey: rawKey), "input was not a valid token") { error in
			guard case JOSESwiftError.invalidCompactSerializationComponentCount(count: 1) = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
		}
	}

	func testLoadWithInvalidKey() throws {
		let rawKey = [UInt8](repeating: 0x77, count: 64)
		XCTAssertThrowsError(try VaultConfig.load(token: tokenHS256, rawKey: rawKey), "signature verification failed") { error in
			guard case JOSESwiftError.verifyingFailed(description: JOSESwiftError.signatureInvalid.localizedDescription) = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
		}
	}

	func testToToken() throws {
		let vaultConfig = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 8, cipherCombo: .sivCtrMac, shorteningThreshold: 220)
		let rawKey = [UInt8](repeating: 0x55, count: 64)
		let token = try vaultConfig.toToken(keyId: "masterkeyfile:masterkey.cryptomator", rawKey: rawKey)
		let tokenComponents = String(data: token, encoding: .utf8)!.split(separator: ".")
		// check header
		let header: [String: String] = try decodeTokenComponent(String(tokenComponents[0]))
		XCTAssertEqual(["typ": "JWT", "alg": "HS256", "kid": "masterkeyfile:masterkey.cryptomator"], header)
		// check payload
		let payload: VaultConfigPayload = try decodeTokenComponent(String(tokenComponents[1]))
		XCTAssertEqual(VaultConfigPayload(jti: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 8, cipherCombo: "SIV_CTRMAC", shorteningThreshold: 220), payload)
		// skip signature check
	}

	// MARK: - Helpers

	private func decodeTokenComponent<T: Decodable>(_ tokenComponent: String) throws -> T {
		let jsonDecoder = JSONDecoder()
		let data = Data(base64URLEncoded: String(tokenComponent))!
		return try jsonDecoder.decode(T.self, from: data)
	}
}
