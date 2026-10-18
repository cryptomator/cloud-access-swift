//
//  DecoratorFactory.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 06.11.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

/// The `createNewVaultFormat…` functions call `waitUntilVisible` after each folder they create, because the next step fails on an eventually consistent provider if it doesn't see the folder yet.
enum DecoratorFactory {
	// MARK: - Vault Format 7

	static func createNewVaultFormat7(delegate: CloudProvider, vaultPath: CloudPath, password: String, waitUntilVisible: (CloudPath) async throws -> Void) async throws -> VaultFormat7ProviderDecorator {
		let masterkey = try Masterkey.createFromRaw(rawKey: [UInt8](repeating: 0x55, count: 32) + [UInt8](repeating: 0x77, count: 32))
		let cryptor = Cryptor(masterkey: masterkey, scheme: .sivCtrMac)
		let decorator = try VaultFormat7ProviderDecorator(delegate: delegate, vaultPath: vaultPath, cryptor: cryptor)
		let rootDirPath = try getRootDirectoryPath(for: cryptor, vaultPath: vaultPath)
		let tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer {
			try? FileManager.default.removeItem(at: tmpDirURL)
		}
		try await delegate.createFolder(at: vaultPath)
		try await waitUntilVisible(vaultPath)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		let localMasterkeyURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let masterkeyData = try MasterkeyFile.lock(masterkey: masterkey, vaultVersion: 7, passphrase: password, scryptCostParam: 2)
		try masterkeyData.write(to: localMasterkeyURL)
		let masterkeyCloudPath = vaultPath.appendingPathComponent("masterkey.cryptomator")
		_ = try await delegate.uploadFile(from: localMasterkeyURL, to: masterkeyCloudPath, replaceExisting: false)
		let dPath = vaultPath.appendingPathComponent("d")
		try await delegate.createFolder(at: dPath)
		try await waitUntilVisible(dPath)
		let twoCharsPath = rootDirPath.deletingLastPathComponent()
		try await delegate.createFolder(at: twoCharsPath)
		try await waitUntilVisible(twoCharsPath)
		try await delegate.createFolder(at: rootDirPath)
		try await waitUntilVisible(rootDirPath)
		return decorator
	}

	static func createFromExistingVaultFormat7(delegate: CloudProvider, vaultPath: CloudPath, password: String) async throws -> VaultFormat7ProviderDecorator {
		let masterkeyCloudPath = vaultPath.appendingPathComponent("masterkey.cryptomator")
		let tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		defer {
			try? FileManager.default.removeItem(at: tmpDirURL)
		}
		let localMasterkeyURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		_ = try await delegate.downloadFile(from: masterkeyCloudPath, to: localMasterkeyURL)
		let masterkeyFile = try MasterkeyFile.withContentFromURL(url: localMasterkeyURL)
		let masterkey = try masterkeyFile.unlock(passphrase: password)
		let cryptor = Cryptor(masterkey: masterkey, scheme: .sivCtrMac)
		return try VaultFormat7ProviderDecorator(delegate: delegate, vaultPath: vaultPath, cryptor: cryptor)
	}

	// MARK: - Vault Format 6

	static func createNewVaultFormat6(delegate: CloudProvider, vaultPath: CloudPath, password: String, waitUntilVisible: (CloudPath) async throws -> Void) async throws -> VaultFormat6ProviderDecorator {
		let masterkey = try Masterkey.createFromRaw(rawKey: [UInt8](repeating: 0x55, count: 32) + [UInt8](repeating: 0x77, count: 32))
		let cryptor = Cryptor(masterkey: masterkey, scheme: .sivCtrMac)
		let decorator = try VaultFormat6ProviderDecorator(delegate: delegate, vaultPath: vaultPath, cryptor: cryptor)
		let rootDirPath = try getRootDirectoryPath(for: cryptor, vaultPath: vaultPath)
		let tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer {
			try? FileManager.default.removeItem(at: tmpDirURL)
		}
		try await delegate.createFolder(at: vaultPath)
		try await waitUntilVisible(vaultPath)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		let localMasterkeyURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let masterkeyData = try MasterkeyFile.lock(masterkey: masterkey, vaultVersion: 6, passphrase: password, scryptCostParam: 2)
		try masterkeyData.write(to: localMasterkeyURL)
		let masterkeyCloudPath = vaultPath.appendingPathComponent("masterkey.cryptomator")
		_ = try await delegate.uploadFile(from: localMasterkeyURL, to: masterkeyCloudPath, replaceExisting: false)
		let mPath = vaultPath.appendingPathComponent("m")
		try await delegate.createFolder(at: mPath)
		try await waitUntilVisible(mPath)
		let dPath = vaultPath.appendingPathComponent("d")
		try await delegate.createFolder(at: dPath)
		try await waitUntilVisible(dPath)
		let twoCharsPath = rootDirPath.deletingLastPathComponent()
		try await delegate.createFolder(at: twoCharsPath)
		try await waitUntilVisible(twoCharsPath)
		try await delegate.createFolder(at: rootDirPath)
		try await waitUntilVisible(rootDirPath)
		return decorator
	}

	static func createFromExistingVaultFormat6(delegate: CloudProvider, vaultPath: CloudPath, password: String) async throws -> VaultFormat6ProviderDecorator {
		let masterkeyCloudPath = vaultPath.appendingPathComponent("masterkey.cryptomator")
		let tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		defer {
			try? FileManager.default.removeItem(at: tmpDirURL)
		}
		let localMasterkeyURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		_ = try await delegate.downloadFile(from: masterkeyCloudPath, to: localMasterkeyURL)
		let masterkeyFile = try MasterkeyFile.withContentFromURL(url: localMasterkeyURL)
		let masterkey = try masterkeyFile.unlock(passphrase: password)
		let cryptor = Cryptor(masterkey: masterkey, scheme: .sivCtrMac)
		return try VaultFormat6ProviderDecorator(delegate: delegate, vaultPath: vaultPath, cryptor: cryptor)
	}

	// MARK: - Helpers

	private static func getRootDirectoryPath(for cryptor: Cryptor, vaultPath: CloudPath) throws -> CloudPath {
		let digest = try cryptor.encryptDirId(Data())
		let i = digest.index(digest.startIndex, offsetBy: 2)
		return vaultPath.appendingPathComponent("d/\(digest[..<i])/\(digest[i...])")
	}
}
