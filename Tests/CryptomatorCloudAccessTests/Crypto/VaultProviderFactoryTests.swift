//
//  VaultProviderFactoryTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 06.05.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct VaultProviderFactoryTests {
		let cloudProviderMock = CloudProviderMock(folders: [], files: [String: Data]())
		let vaultPath = CloudPath("/")

		// MARK: - createVaultProvider Tests

		@Test
		func testCreateVaultProvider() throws {
			let vaultConfig = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 8, cipherCombo: .sivCtrMac, shorteningThreshold: 220)
			let masterkey = try Masterkey.createFromRaw(rawKey: [UInt8](repeating: 0x55, count: 32) + [UInt8](repeating: 0x77, count: 32))

			let token = try vaultConfig.toToken(keyId: "masterkeyfile:masterkey.cryptomator", rawKey: masterkey.rawKey)
			let unverifiedVaultConfig = try UnverifiedVaultConfig(token: token)

			let vaultProvider = try VaultProviderFactory.createVaultProvider(from: unverifiedVaultConfig, masterkey: masterkey, vaultPath: vaultPath, with: cloudProviderMock)
			guard let vaultFormat8Provider = vaultProvider as? VaultFormat8ProviderDecorator else {
				Issue.record("Expected a VaultFormat8ProviderDecorator but received: \(type(of: vaultProvider))")
				return
			}
			guard vaultFormat8Provider.delegate is VaultFormat7ShorteningProviderDecorator else {
				Issue.record("Expected a VaultFormat7ShorteningProviderDecorator but received: \(type(of: vaultFormat8Provider.delegate))")
				return
			}
			#expect((vaultFormat8Provider.physicalProvider as? CloudProviderMock) === cloudProviderMock)
		}

		/// A name longer than the config's threshold but not than the default of 220 is shortened.
		@Test
		func createVaultProviderShortensAtConfigThreshold() throws {
			let vaultConfig = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 8, cipherCombo: .sivCtrMac, shorteningThreshold: 150)
			let masterkey = try Masterkey.createFromRaw(rawKey: [UInt8](repeating: 0x55, count: 32) + [UInt8](repeating: 0x77, count: 32))
			let token = try vaultConfig.toToken(keyId: "masterkeyfile:masterkey.cryptomator", rawKey: masterkey.rawKey)
			let unverifiedVaultConfig = try UnverifiedVaultConfig(token: token)

			let vaultProvider = try VaultProviderFactory.createVaultProvider(from: unverifiedVaultConfig, masterkey: masterkey, vaultPath: vaultPath, with: cloudProviderMock)
			let shorteningDecorator = try #require((vaultProvider as? VaultFormat8ProviderDecorator)?.delegate as? VaultFormat7ShorteningProviderDecorator)
			let shortened = shorteningDecorator.shortenedNameCache.getShortenedPath(CloudPath("/d/AB/CDEFGHIJKLMNOPQRSTUVWXYZ234567/\(String(repeating: "a", count: 196)).c9r"))
			#expect(shortened.cloudPath.pathExtension == "c9s")
		}

		@Test
		func createVaultProviderFailsForUnsupportedVaultConfig() throws {
			let vaultConfig = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 7, cipherCombo: .sivCtrMac, shorteningThreshold: 220)
			let masterkey = try Masterkey.createFromRaw(rawKey: [UInt8](repeating: 0x55, count: 32) + [UInt8](repeating: 0x77, count: 32))

			let token = try vaultConfig.toToken(keyId: "masterkeyfile:masterkey.cryptomator", rawKey: masterkey.rawKey)
			let unverifiedVaultConfig = try UnverifiedVaultConfig(token: token)

			let error = try #require(throws: (any Error).self) { try VaultProviderFactory.createVaultProvider(from: unverifiedVaultConfig, masterkey: masterkey, vaultPath: vaultPath, with: cloudProviderMock) }
			guard case VaultProviderFactoryError.unsupportedVaultConfig = error else {
				Issue.record("Throws the wrong error: \(error)")
				return
			}
		}

		// MARK: - createLegacyVaultProvider Tests

		@Test
		func createLegacyVaultFormat7Provider() throws {
			let masterkey = try Masterkey.createFromRaw(rawKey: [UInt8](repeating: 0x55, count: 32) + [UInt8](repeating: 0x77, count: 32))

			let vaultProvider = try VaultProviderFactory.createLegacyVaultProvider(from: masterkey, vaultVersion: 7, vaultPath: vaultPath, with: cloudProviderMock)
			guard let vaultFormat7Provider = vaultProvider as? VaultFormat7ProviderDecorator else {
				Issue.record("Expected a VaultFormat7ProviderDecorator but received: \(type(of: vaultProvider))")
				return
			}
			guard vaultFormat7Provider.delegate is VaultFormat7ShorteningProviderDecorator else {
				Issue.record("Expected a VaultFormat7ShorteningProviderDecorator but received: \(type(of: vaultFormat7Provider.delegate))")
				return
			}
			#expect((vaultFormat7Provider.physicalProvider as? CloudProviderMock) === cloudProviderMock)
		}

		@Test
		func createLegacyVaultFormat6Provider() throws {
			let masterkey = try Masterkey.createFromRaw(rawKey: [UInt8](repeating: 0x55, count: 32) + [UInt8](repeating: 0x77, count: 32))

			let vaultProvider = try VaultProviderFactory.createLegacyVaultProvider(from: masterkey, vaultVersion: 6, vaultPath: vaultPath, with: cloudProviderMock)
			guard let vaultFormat6Provider = vaultProvider as? VaultFormat6ProviderDecorator else {
				Issue.record("Expected a VaultFormat6ProviderDecorator but received: \(type(of: vaultProvider))")
				return
			}
			guard vaultFormat6Provider.delegate is VaultFormat6ShorteningProviderDecorator else {
				Issue.record("Expected a VaultFormat6ShorteningProviderDecorator but received: \(type(of: vaultFormat6Provider.delegate))")
				return
			}
			#expect((vaultFormat6Provider.physicalProvider as? CloudProviderMock) === cloudProviderMock)
		}

		@Test
		func createLegacyVaultProviderFailsForLowerVaultVersion() throws {
			let masterkey = try Masterkey.createFromRaw(rawKey: [UInt8](repeating: 0x55, count: 32) + [UInt8](repeating: 0x77, count: 32))

			let error = try #require(throws: (any Error).self) { try VaultProviderFactory.createLegacyVaultProvider(from: masterkey, vaultVersion: 5, vaultPath: vaultPath, with: cloudProviderMock) }
			guard case VaultProviderFactoryError.unsupportedVaultVersion = error else {
				Issue.record("Throws the wrong error: \(error)")
				return
			}
		}

		@Test
		func createLegacyVaultProviderFailsForHigherVaultVersion() throws {
			let masterkey = try Masterkey.createFromRaw(rawKey: [UInt8](repeating: 0x55, count: 32) + [UInt8](repeating: 0x77, count: 32))

			let error = try #require(throws: (any Error).self) { try VaultProviderFactory.createLegacyVaultProvider(from: masterkey, vaultVersion: 8, vaultPath: vaultPath, with: cloudProviderMock) }
			guard case VaultProviderFactoryError.unsupportedVaultVersion = error else {
				Issue.record("Throws the wrong error: \(error)")
				return
			}
		}

		// MARK: - isSupported Tests

		@Test
		func vaultConfigWithSivCtrMacIsSupported() throws {
			let vaultConfig = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 8, cipherCombo: .sivCtrMac, shorteningThreshold: 220)
			let rawKey = [UInt8](repeating: 0x55, count: 64)
			let token = try vaultConfig.toToken(keyId: "masterkeyfile:masterkey.cryptomator", rawKey: rawKey)
			let unverifiedVaultConfig = try UnverifiedVaultConfig(token: token)
			#expect(VaultProviderFactory.isSupported(unverifiedVaultConfig: unverifiedVaultConfig))
		}

		@Test
		func vaultConfigWithSivGcmIsSupported() throws {
			let vaultConfig = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 8, cipherCombo: .sivGcm, shorteningThreshold: 220)
			let rawKey = [UInt8](repeating: 0x55, count: 64)
			let token = try vaultConfig.toToken(keyId: "masterkeyfile:masterkey.cryptomator", rawKey: rawKey)
			let unverifiedVaultConfig = try UnverifiedVaultConfig(token: token)
			#expect(VaultProviderFactory.isSupported(unverifiedVaultConfig: unverifiedVaultConfig))
		}

		@Test
		func vaultConfigWithFormatNotEqual8IsNotSupported() throws {
			let vaultConfigWithLowerFormat = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 7, cipherCombo: .sivCtrMac, shorteningThreshold: 220)
			let rawKey = [UInt8](repeating: 0x55, count: 64)
			let lowerFormatToken = try vaultConfigWithLowerFormat.toToken(keyId: "masterkeyfile:masterkey.cryptomator", rawKey: rawKey)
			let unverifiedVaultConfigWithLowerFormat = try UnverifiedVaultConfig(token: lowerFormatToken)
			#expect(!VaultProviderFactory.isSupported(unverifiedVaultConfig: unverifiedVaultConfigWithLowerFormat))

			let vaultConfigWithHigherFormat = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 9, cipherCombo: .sivCtrMac, shorteningThreshold: 220)
			let higherFormatToken = try vaultConfigWithHigherFormat.toToken(keyId: "masterkeyfile:masterkey.cryptomator", rawKey: rawKey)
			let unverifiedVaultConfigWithHigherFormat = try UnverifiedVaultConfig(token: higherFormatToken)
			#expect(!VaultProviderFactory.isSupported(unverifiedVaultConfig: unverifiedVaultConfigWithHigherFormat))
		}

		@Test
		func vaultConfigIsNotSupportedWithDifferentKid() throws {
			let vaultConfig = VaultConfig(id: "ABB9F673-F3E8-41A7-A43B-D29F5DA65068", format: 8, cipherCombo: .sivCtrMac, shorteningThreshold: 220)
			let rawKey = [UInt8](repeating: 0x55, count: 64)
			let token = try vaultConfig.toToken(keyId: "masterkeyfile:foo.bar", rawKey: rawKey)
			let unverifiedVaultConfig = try UnverifiedVaultConfig(token: token)
			#expect(!VaultProviderFactory.isSupported(unverifiedVaultConfig: unverifiedVaultConfig))
		}
	}
}
