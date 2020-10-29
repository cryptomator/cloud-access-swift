//
//  VaultFormat7ProviderDecorator.swift
//  CryptomatorCloudAccess
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation
import Promises

private extension CloudPath {
	func appendingDirFileComponent() -> CloudPath {
		return appendingPathComponent("dir.c9r")
	}
}

/**
 Cloud provider decorator for Cryptomator vaults in vault format 7 (without name shortening).

 With this decorator, you can call the cloud provider methods with cleartext paths (relative to `vaultPath`) and the decorator passes ciphertext paths (absolute) to the delegate. It transparently encrypts/decrypts filenames and file contents according to vault format 7, see the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.5/security/architecture/).

 Use the factory methods to create a new crypto decorator. In order to be fully compatible with vault format 7, pass an instance of `VaultFormat7ShorteningProviderDecorator` (shortening decorator) as the delegate.
 */
public class VaultFormat7ProviderDecorator: CloudProvider {
	let delegate: CloudProvider
	let vaultPath: CloudPath
	let cryptor: Cryptor
	let dirIdCache: DirectoryIdCache
	let tmpDirURL: URL

	public init(delegate: CloudProvider, vaultPath: CloudPath, cryptor: Cryptor) throws {
		guard cryptor.masterkeyVersion == 7 else {
			throw VaultFormatError.masterkeyVersionMismatch
		}
		self.delegate = delegate
		self.vaultPath = vaultPath
		self.cryptor = cryptor
		self.dirIdCache = try DirectoryIdCache()
		self.tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at cleartextCloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		let cleartextParentPath = cleartextCloudPath.deletingLastPathComponent()
		let parentDirIdPromise = getDirId(cleartextParentPath)
		let ciphertextMetadataPromise = parentDirIdPromise.then { parentDirId in
			return try self.getCiphertextPath(cleartextCloudPath, parentDirId: parentDirId)
		}.then { ciphertextPath in
			return self.delegate.fetchItemMetadata(at: ciphertextPath)
		}
		return all(ciphertextMetadataPromise, parentDirIdPromise).then { ciphertextMetadata, parentDirId in
			try self.toCleartextMetadata(ciphertextMetadata, cleartextParentPath: cleartextCloudPath.deletingLastPathComponent(), parentDirId: parentDirId)
		}
	}

	public func fetchItemList(forFolderAt cleartextCloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		let ciphertextListPromise = getDirPath(cleartextCloudPath).then { dirPath in
			return self.delegate.fetchItemList(forFolderAt: dirPath, withPageToken: pageToken)
		}
		return all(ciphertextListPromise, getDirId(cleartextCloudPath)).then { ciphertextList, parentDirId in
			try self.toCleartextList(ciphertextList, cleartextParentPath: cleartextCloudPath, parentDirId: parentDirId)
		}
	}

	public func downloadFile(from cleartextCloudPath: CloudPath, to cleartextLocalURL: URL) -> Promise<Void> {
		precondition(cleartextLocalURL.isFileURL)
		let overallProgress = Progress(totalUnitCount: 5)
		let ciphertextLocalURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		return getCiphertextPath(cleartextCloudPath).then { ciphertextCloudPath in
			overallProgress.becomeCurrent(withPendingUnitCount: 4)
			let downloadFilePromise = self.delegate.downloadFile(from: ciphertextCloudPath, to: ciphertextLocalURL)
			overallProgress.resignCurrent()
			return downloadFilePromise
		}.then {
			overallProgress.becomeCurrent(withPendingUnitCount: 1)
			try self.cryptor.decryptContent(from: ciphertextLocalURL, to: cleartextLocalURL)
			overallProgress.resignCurrent()
			try? FileManager.default.removeItem(at: ciphertextLocalURL)
		}
	}

	public func uploadFile(from cleartextLocalURL: URL, to cleartextCloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		precondition(cleartextLocalURL.isFileURL)
		let overallProgress = Progress(totalUnitCount: 5)
		let ciphertextLocalURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let cleartextParentCloudPath = cleartextCloudPath.deletingLastPathComponent()
		let parentDirIdPromise = getDirId(cleartextParentCloudPath)
		let uploadFilePromise = parentDirIdPromise.then { parentDirId in
			return try self.getCiphertextPath(cleartextCloudPath, parentDirId: parentDirId)
		}.then { ciphertextCloudPath -> Promise<CloudItemMetadata> in
			overallProgress.becomeCurrent(withPendingUnitCount: 1)
			try self.cryptor.encryptContent(from: cleartextLocalURL, to: ciphertextLocalURL)
			overallProgress.resignCurrent()
			overallProgress.becomeCurrent(withPendingUnitCount: 4)
			let uploadFilePromise = self.delegate.uploadFile(from: ciphertextLocalURL, to: ciphertextCloudPath, replaceExisting: replaceExisting)
			overallProgress.resignCurrent()
			return uploadFilePromise
		}.always {
			try? FileManager.default.removeItem(at: ciphertextLocalURL)
		}
		return all(uploadFilePromise, parentDirIdPromise).then { ciphertextMetadata, parentDirId in
			return try self.toCleartextMetadata(ciphertextMetadata, cleartextParentPath: cleartextCloudPath.deletingLastPathComponent(), parentDirId: parentDirId)
		}
	}

	public func createFolder(at cleartextCloudPath: CloudPath) -> Promise<Void> {
		let dirId = UUID().uuidString.data(using: .utf8)!
		let localDirFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let dirPath: CloudPath
		do {
			try dirId.write(to: localDirFileURL)
			dirPath = try getDirPath(dirId)
		} catch {
			return Promise(error)
		}
		let ciphertextPathPromise = getCiphertextPath(cleartextCloudPath)
		return ciphertextPathPromise.then { ciphertextCloudPath in
			return self.delegate.createFolder(at: ciphertextCloudPath)
		}.then { ciphertextPathPromise }.then { ciphertextCloudPath -> Promise<CloudItemMetadata> in
			let dirFileCloudPath = ciphertextCloudPath.appendingDirFileComponent()
			return self.delegate.uploadFile(from: localDirFileURL, to: dirFileCloudPath, replaceExisting: false)
		}.then { _ -> Promise<Void> in
			let parentDirPath = dirPath.deletingLastPathComponent()
			return self.delegate.createFolderIfMissing(at: parentDirPath)
		}.then { () -> Promise<Void> in
			return self.delegate.createFolder(at: dirPath)
		}.always {
			try? FileManager.default.removeItem(at: localDirFileURL)
		}
	}

	public func deleteFile(at cleartextCloudPath: CloudPath) -> Promise<Void> {
		return getCiphertextPath(cleartextCloudPath).then { ciphertextCloudPath in
			return self.delegate.deleteFile(at: ciphertextCloudPath)
		}
	}

	public func deleteFolder(at cleartextCloudPath: CloudPath) -> Promise<Void> {
		// TODO: recover from error if `getDirId()` rejects with `CloudProviderError.itemNotFound` and delete item anyway (because it's probably a symlink)
		// TODO: recover from error if `deleteCiphertextDir()` rejects with `CloudProviderError.itemNotFound` and delete item anyway (because the directory is broken anyway)
		return getDirId(cleartextCloudPath).then { dirId in
			return self.deleteCiphertextDir(dirId)
		}.then {
			return self.getCiphertextPath(cleartextCloudPath)
		}.then { ciphertextCloudPath in
			return self.delegate.deleteFolder(at: ciphertextCloudPath)
		}
	}

	public func moveFile(from cleartextSourceCloudPath: CloudPath, to cleartextTargetCloudPath: CloudPath) -> Promise<Void> {
		return all(getCiphertextPath(cleartextSourceCloudPath), getCiphertextPath(cleartextTargetCloudPath)).then { ciphertextSourceCloudPath, ciphertextTargetCloudPath in
			return self.delegate.moveFile(from: ciphertextSourceCloudPath, to: ciphertextTargetCloudPath)
		}
	}

	public func moveFolder(from cleartextSourceCloudPath: CloudPath, to cleartextTargetCloudPath: CloudPath) -> Promise<Void> {
		return all(getCiphertextPath(cleartextSourceCloudPath), getCiphertextPath(cleartextTargetCloudPath)).then { ciphertextSourceCloudPath, ciphertextTargetCloudPath in
			return self.delegate.moveFolder(from: ciphertextSourceCloudPath, to: ciphertextTargetCloudPath)
		}
	}

	// MARK: - Encryption

	private func getDirId(_ cleartextPath: CloudPath) -> Promise<Data> {
		return dirIdCache.get(cleartextPath, onMiss: { cleartextPath, parentDirId in
			let ciphertextPath = try self.getCiphertextPath(cleartextPath, parentDirId: parentDirId)
			let dirFilePath = ciphertextPath.appendingDirFileComponent()
			return self.downloadFile(at: dirFilePath)
		})
	}

	private func getDirPath(_ dirId: Data) throws -> CloudPath {
		let digest = try cryptor.encryptDirId(dirId)
		let i = digest.index(digest.startIndex, offsetBy: 2)
		return vaultPath.appendingPathComponent("d/\(digest[..<i])/\(digest[i...])")
	}

	private func getDirPath(_ cleartextPath: CloudPath) -> Promise<CloudPath> {
		return getDirId(cleartextPath).then { dirId in
			return try self.getDirPath(dirId)
		}
	}

	private func getCiphertextPath(_ cleartextPath: CloudPath, parentDirId: Data) throws -> CloudPath {
		let ciphertextBaseName = try cryptor.encryptFileName(cleartextPath.lastPathComponent, dirId: parentDirId)
		let ciphertextName = "\(ciphertextBaseName).c9r"
		return try getDirPath(parentDirId).appendingPathComponent(ciphertextName)
	}

	private func getCiphertextPath(_ cleartextPath: CloudPath) -> Promise<CloudPath> {
		let cleartextParentPath = cleartextPath.deletingLastPathComponent()
		return getDirId(cleartextParentPath).then { parentDirId in
			return try self.getCiphertextPath(cleartextPath, parentDirId: parentDirId)
		}
	}

	// MARK: - Decryption

	private func toCleartextMetadata(_ ciphertextMetadata: CloudItemMetadata, cleartextParentPath: CloudPath, parentDirId: Data) throws -> CloudItemMetadata {
		guard String(ciphertextMetadata.name.suffix(4)) == ".c9r" else {
			throw VaultFormatError.encounteredUnrelatedFile // not a Cryptomator file
		}
		let ciphertextBaseName = String(ciphertextMetadata.name.dropLast(4))
		let cleartextName = try cryptor.decryptFileName(ciphertextBaseName, dirId: parentDirId)
		let cleartextPath = cleartextParentPath.appendingPathComponent(cleartextName)
		let cleartextSize = try { () -> Int? in
			guard let ciphertextSize = ciphertextMetadata.size else {
				return nil
			}
			if ciphertextMetadata.itemType == .file {
				return try self.cryptor.calculateCleartextSize(ciphertextSize)
			} else {
				return ciphertextSize
			}
		}()
		return CloudItemMetadata(name: cleartextName, cloudPath: cleartextPath, itemType: ciphertextMetadata.itemType, lastModifiedDate: ciphertextMetadata.lastModifiedDate, size: cleartextSize)
	}

	private func toCleartextList(_ ciphertextList: CloudItemList, cleartextParentPath: CloudPath, parentDirId: Data) throws -> CloudItemList {
		let cleartextItems = ciphertextList.items.compactMap { try? self.toCleartextMetadata($0, cleartextParentPath: cleartextParentPath, parentDirId: parentDirId) }
		return CloudItemList(items: cleartextItems, nextPageToken: ciphertextList.nextPageToken)
	}

	// MARK: - Convenience

	private func downloadFile(at cloudPath: CloudPath) -> Promise<Data> {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		return delegate.downloadFile(from: cloudPath, to: localURL).then {
			return try Data(contentsOf: localURL)
		}.always {
			try? FileManager.default.removeItem(at: localURL)
		}
	}

	private func deleteCiphertextDir(_ dirId: Data) -> Promise<Void> {
		let dirPath: CloudPath
		do {
			dirPath = try getDirPath(dirId)
		} catch {
			return Promise(error)
		}
		return delegate.fetchItemListExhaustively(forFolderAt: dirPath).then { itemList in
			let subDirs = itemList.items.filter { $0.itemType == .folder }
			let subDirItemListPromises = subDirs.map { self.delegate.fetchItemListExhaustively(forFolderAt: $0.cloudPath) }
			return all(subDirItemListPromises).then { subDirItemLists -> Promise<[Maybe<Data>]> in
				// find subdirectories
				let allDirFiles = subDirItemLists.flatMap { $0.items }.filter { $0.name == "dir.c9r" }
				let dirIdPromises = allDirFiles.map { self.downloadFile(at: $0.cloudPath) }
				return any(dirIdPromises)
			}.then { dirIds -> Promise<[Maybe<Void>]> in
				// delete subdirectories recursively
				let recursiveDeleteOperations = dirIds.filter { $0.value != nil }.map { self.deleteCiphertextDir($0.value!) }
				return any(recursiveDeleteOperations)
			}.then { _ in
				// delete self
				return self.delegate.deleteFolder(at: dirPath)
			}
		}
	}
}
