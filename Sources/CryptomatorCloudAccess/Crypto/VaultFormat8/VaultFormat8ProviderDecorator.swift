//
//  VaultFormat8ProviderDecorator.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 05.03.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

private extension CloudPath {
	func appendingDirFileComponent() -> CloudPath {
		return appendingPathComponent("dir.c9r")
	}

	func appendingDirIdFileComponent() -> CloudPath {
		return appendingPathComponent("dirid.c9r")
	}
}

private extension CloudProvider {
	func silentlyUploadFileAndCleanUp(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<Void> {
		return uploadFile(from: localURL, to: cloudPath, replaceExisting: replaceExisting).then { _ in
			// ignore result
		}.recover { _ in
			// ignore error
		}.always {
			try? FileManager.default.removeItem(at: localURL)
		}
	}
}

/**
 Cloud provider decorator for Cryptomator vaults in vault format 8 (without name shortening).

 With this decorator, you can call the cloud provider methods with cleartext paths (relative to `vaultPath`) and the decorator passes ciphertext paths (absolute) to the delegate. It transparently encrypts/decrypts filenames and file contents according to vault format 8, see the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.6/security/architecture/).

 Use the factory methods to create a new crypto decorator. In order to be fully compatible with vault format 8, pass an instance of `VaultFormat8ShorteningProviderDecorator` (shortening decorator) as the delegate.

 The implementation of this decorator is identical to vault format 7 since the new format "only" introduced a new vault configuration file.
 */
class VaultFormat8ProviderDecorator: VaultFormat7ProviderDecorator {
	override func createFolder(at cleartextCloudPath: CloudPath) -> Promise<Void> {
		let dirId = UUID().uuidString.data(using: .utf8)!
		let localCleartextDirFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let dirPath: CloudPath
		do {
			try dirId.write(to: localCleartextDirFileURL)
			dirPath = try getDirPath(dirId)
		} catch {
			return Promise(error)
		}
		let ciphertextCloudPathPromise = getC9RPath(cleartextCloudPath)
		return ciphertextCloudPathPromise.then { ciphertextCloudPath in
			return self.delegate.createFolder(at: ciphertextCloudPath)
		}.then { ciphertextCloudPathPromise }.then { ciphertextCloudPath -> Promise<CloudItemMetadata> in
			let dirFileCloudPath = ciphertextCloudPath.appendingDirFileComponent()
			return self.delegate.uploadFile(from: localCleartextDirFileURL, to: dirFileCloudPath, replaceExisting: false)
		}.then { _ -> Promise<Void> in
			let parentDirPath = dirPath.deletingLastPathComponent()
			return self.delegate.createFolderIfMissing(at: parentDirPath)
		}.then { () -> Promise<Void> in
			return self.delegate.createFolder(at: dirPath)
		}.then { () -> Promise<Void> in
			// This step is optional and will create a `dirid.c9r` file for recovery purposes.
			// See: https://github.com/cryptomator/cloud-access-swift/issues/10
			let localCiphertextDirFileURL = try self.encryptDirFile(localCleartextDirFileURL)
			let ciphertextDirFileCloudPath = dirPath.appendingDirIdFileComponent()
			return self.delegate.silentlyUploadFileAndCleanUp(from: localCiphertextDirFileURL, to: ciphertextDirFileCloudPath, replaceExisting: false)
		}.then { _ -> Void in
			try self.dirIdCache.addOrUpdate(cleartextCloudPath, dirId: dirId)
		}.always {
			try? FileManager.default.removeItem(at: localCleartextDirFileURL)
		}
	}

	private func encryptDirFile(_ cleartextDirFileURL: URL) throws -> URL {
		let ciphertextDirFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try cryptor.encryptContent(from: cleartextDirFileURL, to: ciphertextDirFileURL)
		return ciphertextDirFileURL
	}
}
