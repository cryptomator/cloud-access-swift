//
//  VaultConfigTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 03.03.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import SwiftJWT
import XCTest
@testable import CryptomatorCloudAccess

class VaultConfigTests: XCTestCase {
	func testCreateNew() {
		let vaultConfig = VaultConfig.createNew(format: 8, cipherCombo: .sivCTRMAC, maxFilenameLength: 220)
		XCTAssertEqual(8, vaultConfig.format)
		XCTAssertEqual(.sivCTRMAC, vaultConfig.cipherCombo)
		XCTAssertEqual(220, vaultConfig.maxFilenameLength)
	}

	func testLoad() throws {
		let token = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6Im1hc3RlcmtleWZpbGU6bWFzdGVya2V5LmNyeXB0b21hdG9yIn0.eyJqdGkiOiJBQkI5RjY3My1GM0U4LTQxQTctQTQzQi1EMjlGNURBNjUwNjgiLCJtYXhGaWxlbmFtZUxlbiI6MjIwLCJjaXBoZXJDb21ibyI6IlNJVl9DVFJNQUMiLCJmb3JtYXQiOjh9.-rZb6zhB1BdtDd6PE3Eopvn_USEzoFlyWrqNAz1XaJc"
		let rawKey = [UInt8](repeating: 0x55, count: 64)
		let vaultConfig = try VaultConfig.load(token: token, rawKey: rawKey)
		XCTAssertEqual(8, vaultConfig.format)
		XCTAssertEqual(.sivCTRMAC, vaultConfig.cipherCombo)
		XCTAssertEqual(220, vaultConfig.maxFilenameLength)
	}

	func testLoadWithMalformedToken() throws {
		let token = "hello world"
		let rawKey = [UInt8](repeating: 0x55, count: 64)
		XCTAssertThrowsError(try VaultConfig.load(token: token, rawKey: rawKey), "input was not a valid JWT string") { error in
			XCTAssertEqual(JWTError.invalidJWTString, error as? JWTError)
		}
	}

	func testLoadWithInvalidKey() throws {
		let token = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6Im1hc3RlcmtleWZpbGU6bWFzdGVya2V5LmNyeXB0b21hdG9yIn0.eyJqdGkiOiJBQkI5RjY3My1GM0U4LTQxQTctQTQzQi1EMjlGNURBNjUwNjgiLCJtYXhGaWxlbmFtZUxlbiI6MjIwLCJjaXBoZXJDb21ibyI6IlNJVl9DVFJNQUMiLCJmb3JtYXQiOjh9.-rZb6zhB1BdtDd6PE3Eopvn_USEzoFlyWrqNAz1XaJc"
		let rawKey = [UInt8](repeating: 0x77, count: 64)
		XCTAssertThrowsError(try VaultConfig.load(token: token, rawKey: rawKey), "signature verification failed") { error in
			XCTAssertEqual(.signatureVerificationFailed, error as? VaultConfigError)
		}
	}

	func testToToken() throws {
		let vaultConfig = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 8, cipherCombo: .sivCTRMAC, maxFilenameLength: 220)
		let rawKey = [UInt8](repeating: 0x55, count: 64)
		let token = try vaultConfig.toToken(keyId: "masterkeyfile:masterkey.cryptomator", rawKey: rawKey)
		XCTAssertEqual("eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6Im1hc3RlcmtleWZpbGU6bWFzdGVya2V5LmNyeXB0b21hdG9yIn0.eyJqdGkiOiJBQkI5RjY3My1GM0U4LTQxQTctQTQzQi1EMjlGNURBNjUwNjgiLCJtYXhGaWxlbmFtZUxlbiI6MjIwLCJjaXBoZXJDb21ibyI6IlNJVl9DVFJNQUMiLCJmb3JtYXQiOjh9.-rZb6zhB1BdtDd6PE3Eopvn_USEzoFlyWrqNAz1XaJc", token)
	}
}
