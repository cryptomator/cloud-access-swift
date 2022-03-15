//
//  VaultProviderFactory.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 05.05.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation
import Promises

public enum VaultProviderFactoryError: Error {
	case unsupportedVaultConfig
	case unsupportedVaultVersion(version: Int)
}

public enum VaultProviderFactory {
	private static let masterkeyFilename = "masterkey.cryptomator"
	private static let masterkeyFileId = "masterkeyfile:\(masterkeyFilename)"

	public static func createVaultProvider(from unverifiedVaultConfig: UnverifiedVaultConfig, masterkey: Masterkey, vaultPath: CloudPath, with provider: CloudProvider) throws -> CloudProvider {
		guard isSupported(unverifiedVaultConfig: unverifiedVaultConfig) else {
			throw VaultProviderFactoryError.unsupportedVaultConfig
		}
		let verifiedVaultConfig = try unverifiedVaultConfig.verify(rawKey: masterkey.rawKey)

		let cryptor = Cryptor(masterkey: masterkey)
		let shorteningDecorator = try VaultFormat8ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath, threshold: verifiedVaultConfig.shorteningThreshold)
		return try VaultFormat8ProviderDecorator(delegate: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
	}

	public static func createLegacyVaultProvider(from masterkey: Masterkey, vaultVersion: Int, vaultPath: CloudPath, with provider: CloudProvider) throws -> CloudProvider {
		let cryptor = Cryptor(masterkey: masterkey)

		switch vaultVersion {
		case 6:
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			return try VaultFormat6ProviderDecorator(delegate: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
		case 7:
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			return try VaultFormat7ProviderDecorator(delegate: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
		default:
			throw VaultProviderFactoryError.unsupportedVaultVersion(version: vaultVersion)
		}
	}

	public static func isSupported(unverifiedVaultConfig: UnverifiedVaultConfig) -> Bool {
		guard unverifiedVaultConfig.allegedCipherCombo == .sivCTRMAC else {
			return false
		}
		guard unverifiedVaultConfig.allegedFormat == 8 else {
			return false
		}
		guard unverifiedVaultConfig.keyId == masterkeyFileId else {
			return false
		}
		return true
	}
}
