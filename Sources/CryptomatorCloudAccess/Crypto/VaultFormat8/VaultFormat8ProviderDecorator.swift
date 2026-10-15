//
//  VaultFormat8ProviderDecorator.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 05.03.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation

private extension CloudPath {
	func appendingDirFileComponent() -> CloudPath {
		return appendingPathComponent("dir.c9r")
	}

	func appendingDirIdFileComponent() -> CloudPath {
		return appendingPathComponent("dirid.c9r")
	}
}

private extension CloudProvider {
	func silentlyUploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) async throws {
		do {
			_ = try await uploadFile(from: localURL, to: cloudPath, replaceExisting: replaceExisting)
		} catch let error as CancellationError {
			throw error
		} catch {
			// ignore error
		}
	}
}

/**
 Cloud provider decorator for Cryptomator vaults in vault format 8 (without name shortening).

 With this decorator, you can call the cloud provider methods with cleartext paths (relative to `vaultPath`) and the decorator passes ciphertext paths (absolute) to the delegate. It transparently encrypts/decrypts filenames and file contents according to vault format 8, see the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.6/security/architecture/).

 Use the factory methods to create a new crypto decorator. In order to be fully compatible with vault format 8, pass an instance of `VaultFormat8ShorteningProviderDecorator` (shortening decorator) as the delegate.

 The implementation of this decorator is identical to vault format 7 since the new format "only" introduced a new vault configuration file.

 `@unchecked Sendable`: restates the conformance of `VaultFormat7ProviderDecorator`; this subclass adds no state.
 */
final class VaultFormat8ProviderDecorator: VaultFormat7ProviderDecorator, @unchecked Sendable {
	@concurrent
	override func createFolder(at cleartextCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let dirId = UUID().uuidString.data(using: .utf8)!
		let localCleartextDirFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let localCiphertextDirFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		defer {
			try? FileManager.default.removeItem(at: localCleartextDirFileURL)
			try? FileManager.default.removeItem(at: localCiphertextDirFileURL)
		}
		try dirId.write(to: localCleartextDirFileURL)
		try await cryptor.encryptContent(from: localCleartextDirFileURL, to: localCiphertextDirFileURL)
		let dirPath = try getDirPath(dirId)
		let ciphertextCloudPath = try await getC9RPath(cleartextCloudPath)
		try Task.checkCancellation()
		try await withoutCancellation {
			try await self.delegate.createFolder(at: ciphertextCloudPath)
			let dirFileCloudPath = ciphertextCloudPath.appendingDirFileComponent()
			_ = try await self.delegate.uploadFile(from: localCleartextDirFileURL, to: dirFileCloudPath, replaceExisting: false)
			let parentDirPath = dirPath.deletingLastPathComponent()
			try await self.delegate.createFolderIfMissing(at: parentDirPath)
			try await self.delegate.createFolder(at: dirPath)
			// This step is optional and will create a `dirid.c9r` file for recovery purposes.
			// See: https://github.com/cryptomator/cloud-access-swift/issues/10
			let ciphertextDirFileCloudPath = dirPath.appendingDirIdFileComponent()
			try await self.delegate.silentlyUploadFile(from: localCiphertextDirFileURL, to: ciphertextDirFileCloudPath, replaceExisting: false)
			try self.dirIdCache.addOrUpdate(cleartextCloudPath, dirId: dirId)
		}
	}
}
