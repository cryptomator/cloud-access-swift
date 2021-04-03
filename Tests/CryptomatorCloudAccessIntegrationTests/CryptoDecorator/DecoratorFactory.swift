//
//  DecoratorFactory.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 06.11.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises
@testable import CryptomatorCloudAccess
@testable import CryptomatorCryptoLib
class DecoratorFactory {
	// MARK: VaultFormat7

	static func createNewVaultFormat7(delegate: CloudProvider, vaultPath: CloudPath, password: String) -> Promise<VaultFormat7ProviderDecorator> {
		do {
			let masterkey = Masterkey.createFromRaw(aesMasterKey: [UInt8](repeating: 0x55, count: 32), macMasterKey: [UInt8](repeating: 0x77, count: 32))
			let cryptor = Cryptor(masterkey: masterkey)
			let decorator = try VaultFormat7ProviderDecorator(delegate: delegate, vaultPath: vaultPath, cryptor: cryptor)
			let rootDirPath = try getRootDirectoryPath(for: cryptor, vaultPath: vaultPath)
			return delegate.createFolder(at: vaultPath).then { () -> Promise<CloudItemMetadata> in
				let tmpDirURL = FileManager.default.temporaryDirectory
				let localMasterkeyURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
				let masterkeyData = try MasterkeyFile.lock(masterkey: masterkey, vaultVersion: 7, passphrase: password, scryptCostParam: 2)
				try masterkeyData.write(to: localMasterkeyURL)
				let masterkeyCloudPath = vaultPath.appendingPathComponent("masterkey.cryptomator")
				return delegate.uploadFile(from: localMasterkeyURL, to: masterkeyCloudPath, replaceExisting: false)
			}.then { _ -> Promise<Void> in
				let dPath = vaultPath.appendingPathComponent("d")
				return delegate.createFolder(at: dPath)
			}.then { () -> Promise<Void> in
				let twoCharsPath = rootDirPath.deletingLastPathComponent()
				return delegate.createFolder(at: twoCharsPath)
			}.then { () -> Promise<Void> in
				return delegate.createFolder(at: rootDirPath)
			}.then { () -> VaultFormat7ProviderDecorator in
				return decorator
			}
		} catch {
			return Promise(error)
		}
	}

	static func createFromExistingVaultFormat7(delegate: CloudProvider, vaultPath: CloudPath, password: String) -> Promise<VaultFormat7ProviderDecorator> {
		let masterkeyCloudPath = vaultPath.appendingPathComponent("masterkey.cryptomator")
		let tmpDirURL = FileManager.default.temporaryDirectory
		let localMasterkeyURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		return delegate.downloadFile(from: masterkeyCloudPath, to: localMasterkeyURL).then { () -> VaultFormat7ProviderDecorator in
			let masterkeyFile = try MasterkeyFile.withContentFromURL(url: localMasterkeyURL)
			let masterkey = try masterkeyFile.unlock(passphrase: password)
			let cryptor = Cryptor(masterkey: masterkey)
			return try VaultFormat7ProviderDecorator(delegate: delegate, vaultPath: vaultPath, cryptor: cryptor)
		}
	}

	// MARK: VaultFormat6

	static func createNewVaultFormat6(delegate: CloudProvider, vaultPath: CloudPath, password: String) -> Promise<VaultFormat6ProviderDecorator> {
		do {
			let masterkey = Masterkey.createFromRaw(aesMasterKey: [UInt8](repeating: 0x55, count: 32), macMasterKey: [UInt8](repeating: 0x77, count: 32))
			let cryptor = Cryptor(masterkey: masterkey)
			let decorator = try VaultFormat6ProviderDecorator(delegate: delegate, vaultPath: vaultPath, cryptor: cryptor)
			let rootDirPath = try getRootDirectoryPath(for: cryptor, vaultPath: vaultPath)
			return delegate.createFolder(at: vaultPath).then { () -> Promise<CloudItemMetadata> in
				let tmpDirURL = FileManager.default.temporaryDirectory
				let localMasterkeyURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
				let masterkeyData = try MasterkeyFile.lock(masterkey: masterkey, vaultVersion: 6, passphrase: password, scryptCostParam: 2)
				try masterkeyData.write(to: localMasterkeyURL)
				let masterkeyCloudPath = vaultPath.appendingPathComponent("masterkey.cryptomator")
				return delegate.uploadFile(from: localMasterkeyURL, to: masterkeyCloudPath, replaceExisting: false)
			}.then { _ -> Promise<Void> in
				let mPath = vaultPath.appendingPathComponent("m")
				return delegate.createFolder(at: mPath)
			}.then { _ -> Promise<Void> in
				let dPath = vaultPath.appendingPathComponent("d")
				return delegate.createFolder(at: dPath)
			}.then { () -> Promise<Void> in
				let twoCharsPath = rootDirPath.deletingLastPathComponent()
				return delegate.createFolder(at: twoCharsPath)
			}.then { () -> Promise<Void> in
				return delegate.createFolder(at: rootDirPath)
			}.then { () -> VaultFormat6ProviderDecorator in
				return decorator
			}
		} catch {
			return Promise(error)
		}
	}

	static func createFromExistingVaultFormat6(delegate: CloudProvider, vaultPath: CloudPath, password: String) -> Promise<VaultFormat6ProviderDecorator> {
		let masterkeyCloudPath = vaultPath.appendingPathComponent("masterkey.cryptomator")
		let tmpDirURL = FileManager.default.temporaryDirectory
		let localMasterkeyURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		return delegate.downloadFile(from: masterkeyCloudPath, to: localMasterkeyURL).then { () -> VaultFormat6ProviderDecorator in
			let masterkeyFile = try MasterkeyFile.withContentFromURL(url: localMasterkeyURL)
			let masterkey = try masterkeyFile.unlock(passphrase: password)
			let cryptor = Cryptor(masterkey: masterkey)
			return try VaultFormat6ProviderDecorator(delegate: delegate, vaultPath: vaultPath, cryptor: cryptor)
		}
	}

	// MARK: Helper Functions

	private static func getRootDirectoryPath(for cryptor: Cryptor, vaultPath: CloudPath) throws -> CloudPath {
		let digest = try cryptor.encryptDirId(Data())
		let i = digest.index(digest.startIndex, offsetBy: 2)
		return vaultPath.appendingPathComponent("d/\(digest[..<i])/\(digest[i...])")
	}
}
