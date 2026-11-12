//
//  DecoratorFactory.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 06.11.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation
@testable import CryptomatorCloudAccessCore

/**
 Creates the files and folders of a new vault, and opens a vault from them like the app does, through `VaultProviderFactory`.

 The `createNewVaultFormat…` functions call `waitUntilVisible` after each folder they create, because the next step fails on an eventually consistent provider if it doesn't see the folder yet.
 */
enum DecoratorFactory {
	private static let masterkeyFilename = "masterkey.cryptomator"
	private static let vaultConfigFilename = "vault.cryptomator"

	// MARK: - Vault Format 8

	/// The masterkey file's vault version and the vault config are those of a vault that the app creates.
	static func createNewVaultFormat8(delegate: CloudProvider, vaultPath: CloudPath, password: String, waitUntilVisible: (CloudPath) async throws -> Void) async throws -> (masterkey: Masterkey, vaultConfigToken: Data) {
		let masterkey = try createMasterkey()
		let cipherCombo = CryptorScheme.sivGcm
		let vaultConfig = VaultConfig.createNew(format: 8, cipherCombo: cipherCombo, shorteningThreshold: 220)
		let vaultConfigToken = try vaultConfig.toToken(keyId: "masterkeyfile:\(masterkeyFilename)", rawKey: masterkey.rawKey)
		try await delegate.createFolder(at: vaultPath)
		try await waitUntilVisible(vaultPath)
		try await upload(MasterkeyFile.lock(masterkey: masterkey, vaultVersion: 999, passphrase: password, scryptCostParam: 2), to: vaultPath.appendingPathComponent(masterkeyFilename), with: delegate)
		try await upload(vaultConfigToken, to: vaultPath.appendingPathComponent(vaultConfigFilename), with: delegate)
		try await createRootDirectory(for: Cryptor(masterkey: masterkey, scheme: cipherCombo), vaultPath: vaultPath, delegate: delegate, waitUntilVisible: waitUntilVisible)
		return (masterkey, vaultConfigToken)
	}

	static func createFromExistingVaultFormat8(delegate: CloudProvider, vaultPath: CloudPath, password: String) async throws -> CloudProvider {
		let vaultConfigToken = try await download(from: vaultPath.appendingPathComponent(vaultConfigFilename), with: delegate)
		let masterkeyFile = try await downloadMasterkeyFile(delegate: delegate, vaultPath: vaultPath)
		let masterkey = try masterkeyFile.unlock(passphrase: password)
		return try VaultProviderFactory.createVaultProvider(from: UnverifiedVaultConfig(token: vaultConfigToken), masterkey: masterkey, vaultPath: vaultPath, with: delegate)
	}

	// MARK: - Vault Format 6

	static func createNewVaultFormat6(delegate: CloudProvider, vaultPath: CloudPath, password: String, waitUntilVisible: (CloudPath) async throws -> Void) async throws -> Masterkey {
		let masterkey = try createMasterkey()
		try await delegate.createFolder(at: vaultPath)
		try await waitUntilVisible(vaultPath)
		try await upload(MasterkeyFile.lock(masterkey: masterkey, vaultVersion: 6, passphrase: password, scryptCostParam: 2), to: vaultPath.appendingPathComponent(masterkeyFilename), with: delegate)
		let mPath = vaultPath.appendingPathComponent("m")
		try await delegate.createFolder(at: mPath)
		try await waitUntilVisible(mPath)
		try await createRootDirectory(for: Cryptor(masterkey: masterkey, scheme: .sivCtrMac), vaultPath: vaultPath, delegate: delegate, waitUntilVisible: waitUntilVisible)
		return masterkey
	}

	static func createFromExistingVaultFormat6(delegate: CloudProvider, vaultPath: CloudPath, password: String) async throws -> CloudProvider {
		let masterkeyFile = try await downloadMasterkeyFile(delegate: delegate, vaultPath: vaultPath)
		let masterkey = try masterkeyFile.unlock(passphrase: password)
		return try VaultProviderFactory.createLegacyVaultProvider(from: masterkey, vaultVersion: masterkeyFile.version, vaultPath: vaultPath, with: delegate)
	}

	// MARK: - Helpers

	private static func createMasterkey() throws -> Masterkey {
		return try Masterkey.createFromRaw(rawKey: [UInt8](repeating: 0x55, count: 32) + [UInt8](repeating: 0x77, count: 32))
	}

	private static func createRootDirectory(for cryptor: Cryptor, vaultPath: CloudPath, delegate: CloudProvider, waitUntilVisible: (CloudPath) async throws -> Void) async throws {
		let rootDirPath = try getRootDirectoryPath(for: cryptor, vaultPath: vaultPath)
		let dPath = vaultPath.appendingPathComponent("d")
		try await delegate.createFolder(at: dPath)
		try await waitUntilVisible(dPath)
		let twoCharsPath = rootDirPath.deletingLastPathComponent()
		try await delegate.createFolder(at: twoCharsPath)
		try await waitUntilVisible(twoCharsPath)
		try await delegate.createFolder(at: rootDirPath)
		try await waitUntilVisible(rootDirPath)
	}

	private static func getRootDirectoryPath(for cryptor: Cryptor, vaultPath: CloudPath) throws -> CloudPath {
		let digest = try cryptor.encryptDirId(Data())
		let i = digest.index(digest.startIndex, offsetBy: 2)
		return vaultPath.appendingPathComponent("d/\(digest[..<i])/\(digest[i...])")
	}

	private static func downloadMasterkeyFile(delegate: CloudProvider, vaultPath: CloudPath) async throws -> MasterkeyFile {
		return try await MasterkeyFile.withContentFromData(data: download(from: vaultPath.appendingPathComponent(masterkeyFilename), with: delegate))
	}

	private static func upload(_ data: Data, to cloudPath: CloudPath, with delegate: CloudProvider) async throws {
		let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
		defer {
			try? FileManager.default.removeItem(at: localURL)
		}
		try data.write(to: localURL)
		_ = try await delegate.uploadFile(from: localURL, to: cloudPath, replaceExisting: false)
	}

	private static func download(from cloudPath: CloudPath, with delegate: CloudProvider) async throws -> Data {
		let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
		defer {
			try? FileManager.default.removeItem(at: localURL)
		}
		_ = try await delegate.downloadFile(from: cloudPath, to: localURL)
		return try Data(contentsOf: localURL)
	}
}
