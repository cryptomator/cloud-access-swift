//
//  VaultProviderFactoryTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 06.05.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
@testable import CryptomatorCryptoLib

class VaultProviderFactoryTests: XCTestCase {
	let cloudProviderMock = CloudProviderMock(folders: [], files: [String: Data]())
	let vaultPath = CloudPath("/")

	// MARK: - createVaultProvider Tests

	func testCreateVaultProvider() throws {
		let vaultConfig = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 8, cipherCombo: .sivCTRMAC, shorteningThreshold: 220)
		let masterkey = Masterkey.createFromRaw(aesMasterKey: [UInt8](repeating: 0x55, count: 32), macMasterKey: [UInt8](repeating: 0x77, count: 32))

		let token = try vaultConfig.toToken(keyId: "masterkeyfile:masterkey.cryptomator", rawKey: masterkey.rawKey)
		let unverifiedVaultConfig = try UnverifiedVaultConfig(token: token)

		let vaultProvider = try VaultProviderFactory.createVaultProvider(from: unverifiedVaultConfig, masterkey: masterkey, vaultPath: vaultPath, with: cloudProviderMock)
		guard let vaultFormat8Provider = vaultProvider as? VaultFormat8ProviderDecorator else {
			XCTFail("Expected a VaultFormat8ProviderDecorator but received: \(type(of: vaultProvider))")
			return
		}
		guard vaultFormat8Provider.delegate is VaultFormat8ShorteningProviderDecorator else {
			XCTFail("Expected a VaultFormat8ShorteningProviderDecorator but received: \(type(of: vaultFormat8Provider.delegate))")
			return
		}
	}

	func testCreateVaultProviderFailsForUnsupportedVaultConfig() throws {
		let vaultConfig = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 7, cipherCombo: .sivCTRMAC, shorteningThreshold: 220)
		let masterkey = Masterkey.createFromRaw(aesMasterKey: [UInt8](repeating: 0x55, count: 32), macMasterKey: [UInt8](repeating: 0x77, count: 32))

		let token = try vaultConfig.toToken(keyId: "masterkeyfile:masterkey.cryptomator", rawKey: masterkey.rawKey)
		let unverifiedVaultConfig = try UnverifiedVaultConfig(token: token)

		XCTAssertThrowsError(try VaultProviderFactory.createVaultProvider(from: unverifiedVaultConfig, masterkey: masterkey, vaultPath: vaultPath, with: cloudProviderMock)) { error in
			guard case VaultProviderFactoryError.unsupportedVaultConfig = error else {
				XCTFail("Throws the wrong error: \(error)")
				return
			}
		}
	}

	// MARK: - createLegacyVaultProvider Tests

	func testCreateLegacyVaultFormat7Provider() throws {
		let masterkey = Masterkey.createFromRaw(aesMasterKey: [UInt8](repeating: 0x55, count: 32), macMasterKey: [UInt8](repeating: 0x77, count: 32))

		let vaultProvider = try VaultProviderFactory.createLegacyVaultProvider(from: masterkey, vaultVersion: 7, vaultPath: vaultPath, with: cloudProviderMock)
		guard let vaultFormat7Provider = vaultProvider as? VaultFormat7ProviderDecorator else {
			XCTFail("Expected a VaultFormat7ProviderDecorator but received: \(type(of: vaultProvider))")
			return
		}
		guard vaultFormat7Provider.delegate is VaultFormat7ShorteningProviderDecorator else {
			XCTFail("Expected a VaultFormat7ShorteningProviderDecorator but received: \(type(of: vaultFormat7Provider.delegate))")
			return
		}
	}

	func testCreateLegacyVaultFormat6Provider() throws {
		let masterkey = Masterkey.createFromRaw(aesMasterKey: [UInt8](repeating: 0x55, count: 32), macMasterKey: [UInt8](repeating: 0x77, count: 32))

		let vaultProvider = try VaultProviderFactory.createLegacyVaultProvider(from: masterkey, vaultVersion: 6, vaultPath: vaultPath, with: cloudProviderMock)
		guard let vaultFormat6Provider = vaultProvider as? VaultFormat6ProviderDecorator else {
			XCTFail("Expected a VaultFormat6ProviderDecorator but received: \(type(of: vaultProvider))")
			return
		}
		guard vaultFormat6Provider.delegate is VaultFormat6ShorteningProviderDecorator else {
			XCTFail("Expected a VaultFormat6ShorteningProviderDecorator but received: \(type(of: vaultFormat6Provider.delegate))")
			return
		}
	}

	func testCreateLegacyVaultProviderFailsForLowerVaultVersion() {
		let masterkey = Masterkey.createFromRaw(aesMasterKey: [UInt8](repeating: 0x55, count: 32), macMasterKey: [UInt8](repeating: 0x77, count: 32))

		XCTAssertThrowsError(try VaultProviderFactory.createLegacyVaultProvider(from: masterkey, vaultVersion: 5, vaultPath: vaultPath, with: cloudProviderMock)) { error in
			guard case VaultProviderFactoryError.unsupportedVaultVersion = error else {
				XCTFail("Throws the wrong error: \(error)")
				return
			}
		}
	}

	func testCreateLegacyVaultProviderFailsForHigherVaultVersion() {
		let masterkey = Masterkey.createFromRaw(aesMasterKey: [UInt8](repeating: 0x55, count: 32), macMasterKey: [UInt8](repeating: 0x77, count: 32))

		XCTAssertThrowsError(try VaultProviderFactory.createLegacyVaultProvider(from: masterkey, vaultVersion: 8, vaultPath: vaultPath, with: cloudProviderMock)) { error in
			guard case VaultProviderFactoryError.unsupportedVaultVersion = error else {
				XCTFail("Throws the wrong error: \(error)")
				return
			}
		}
	}

	// MARK: - isSupported Tests

	func testIsSupported() throws {
		let vaultConfig = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 8, cipherCombo: .sivCTRMAC, shorteningThreshold: 220)
		let rawKey = [UInt8](repeating: 0x55, count: 64)
		let token = try vaultConfig.toToken(keyId: "masterkeyfile:masterkey.cryptomator", rawKey: rawKey)
		let unverifiedVaultConfig = try UnverifiedVaultConfig(token: token)
		XCTAssert(VaultProviderFactory.isSupported(unverifiedVaultConfig: unverifiedVaultConfig))
	}

	func testVaultConfigWithFormatNotEqual8IsNotSupported() throws {
		let vaultConfigWithLowerFormat = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 7, cipherCombo: .sivCTRMAC, shorteningThreshold: 220)
		let rawKey = [UInt8](repeating: 0x55, count: 64)
		let lowerFormatToken = try vaultConfigWithLowerFormat.toToken(keyId: "masterkeyfile:masterkey.cryptomator", rawKey: rawKey)
		let unverifiedVaultConfigWithLowerFormat = try UnverifiedVaultConfig(token: lowerFormatToken)
		XCTAssertFalse(VaultProviderFactory.isSupported(unverifiedVaultConfig: unverifiedVaultConfigWithLowerFormat))

		let vaultConfigWithHigherFormat = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 9, cipherCombo: .sivCTRMAC, shorteningThreshold: 220)
		let higherFormatToken = try vaultConfigWithHigherFormat.toToken(keyId: "masterkeyfile:masterkey.cryptomator", rawKey: rawKey)
		let unverifiedVaultConfigWithHigherFormat = try UnverifiedVaultConfig(token: higherFormatToken)
		XCTAssertFalse(VaultProviderFactory.isSupported(unverifiedVaultConfig: unverifiedVaultConfigWithHigherFormat))
	}

	func testVaultConfigIsNotSupportedWithDifferentKid() throws {
		let vaultConfig = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 8, cipherCombo: .sivCTRMAC, shorteningThreshold: 220)
		let rawKey = [UInt8](repeating: 0x55, count: 64)
		let token = try vaultConfig.toToken(keyId: "masterkeyfile:foo.bar", rawKey: rawKey)
		let unverifiedVaultConfig = try UnverifiedVaultConfig(token: token)
		XCTAssertFalse(VaultProviderFactory.isSupported(unverifiedVaultConfig: unverifiedVaultConfig))
	}

	func testVaultConfigWithSIVGCMIsNotSupported() throws {
		let vaultConfig = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 8, cipherCombo: .sivGCM, shorteningThreshold: 220)
		let rawKey = [UInt8](repeating: 0x55, count: 64)
		let token = try vaultConfig.toToken(keyId: "masterkeyfile:masterkey.cryptomator", rawKey: rawKey)
		let unverifiedVaultConfig = try UnverifiedVaultConfig(token: token)
		XCTAssertFalse(VaultProviderFactory.isSupported(unverifiedVaultConfig: unverifiedVaultConfig))
	}
}
