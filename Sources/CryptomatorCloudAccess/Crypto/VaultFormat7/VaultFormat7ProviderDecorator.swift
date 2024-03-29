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
class VaultFormat7ProviderDecorator: CloudProvider {
	// swiftlint:disable:next weak_delegate
	let delegate: CloudProvider
	let vaultPath: CloudPath
	let cryptor: Cryptor
	let dirIdCache: DirectoryIdCache
	let tmpDirURL: URL

	init(delegate: CloudProvider, vaultPath: CloudPath, cryptor: Cryptor) throws {
		self.delegate = delegate
		self.vaultPath = vaultPath
		self.cryptor = cryptor
		self.dirIdCache = try DirectoryIdCache()
		self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - CloudProvider API

	func fetchItemMetadata(at cleartextCloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		let parentDirIdPromise = getParentDirId(cleartextCloudPath)
		let ciphertextMetadataPromise = parentDirIdPromise.then { parentDirId in
			return try self.getC9RPath(cleartextCloudPath, parentDirId: parentDirId)
		}.then { ciphertextCloudPath in
			return self.delegate.fetchItemMetadata(at: ciphertextCloudPath)
		}
		return all(ciphertextMetadataPromise, parentDirIdPromise).then { ciphertextMetadata, parentDirId in
			try self.toCleartextMetadata(ciphertextMetadata, cleartextParentPath: cleartextCloudPath.deletingLastPathComponent(), parentDirId: parentDirId)
		}
	}

	func fetchItemList(forFolderAt cleartextCloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		let dirIdPromise = getDirId(cleartextCloudPath)
		let ciphertextListPromise = dirIdPromise.then { dirId in
			return try self.getDirPath(dirId)
		}.then { dirPath in
			return self.delegate.fetchItemList(forFolderAt: dirPath, withPageToken: pageToken)
		}
		return all(ciphertextListPromise, dirIdPromise).then { ciphertextList, dirId in
			try self.toCleartextList(ciphertextList, cleartextParentPath: cleartextCloudPath, parentDirId: dirId)
		}
	}

	func downloadFile(from cleartextCloudPath: CloudPath, to cleartextLocalURL: URL, onTaskCreation: ((URLSessionDownloadTask?) -> Void)?) -> Promise<Void> {
		precondition(cleartextLocalURL.isFileURL)
		let overallProgress = Progress(totalUnitCount: 5)
		let ciphertextLocalURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		return getC9RPath(cleartextCloudPath).then { ciphertextCloudPath in
			overallProgress.becomeCurrent(withPendingUnitCount: 4)
			let downloadFilePromise = self.delegate.downloadFile(from: ciphertextCloudPath, to: ciphertextLocalURL, onTaskCreation: onTaskCreation)
			overallProgress.resignCurrent()
			return downloadFilePromise
		}.then {
			guard !FileManager.default.fileExists(atPath: cleartextLocalURL.path) else {
				throw CloudProviderError.itemAlreadyExists
			}
			overallProgress.becomeCurrent(withPendingUnitCount: 1)
			try self.cryptor.decryptContent(from: ciphertextLocalURL, to: cleartextLocalURL)
			overallProgress.resignCurrent()
		}.always {
			try? FileManager.default.removeItem(at: ciphertextLocalURL)
		}
	}

	func uploadFile(from cleartextLocalURL: URL, to cleartextCloudPath: CloudPath, replaceExisting: Bool, onTaskCreation: ((URLSessionUploadTask?) -> Void)?) -> Promise<CloudItemMetadata> {
		precondition(cleartextLocalURL.isFileURL)
		let overallProgress = Progress(totalUnitCount: 5)
		let ciphertextLocalURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let parentDirIdPromise = getParentDirId(cleartextCloudPath)
		let uploadFilePromise = parentDirIdPromise.then { parentDirId in
			return try self.getC9RPath(cleartextCloudPath, parentDirId: parentDirId)
		}.then { ciphertextCloudPath -> Promise<CloudItemMetadata> in
			overallProgress.becomeCurrent(withPendingUnitCount: 1)
			try self.cryptor.encryptContent(from: cleartextLocalURL, to: ciphertextLocalURL)
			overallProgress.resignCurrent()
			overallProgress.becomeCurrent(withPendingUnitCount: 4)
			let uploadFilePromise = self.delegate.uploadFile(from: ciphertextLocalURL, to: ciphertextCloudPath, replaceExisting: replaceExisting, onTaskCreation: onTaskCreation)
			overallProgress.resignCurrent()
			return uploadFilePromise
		}.recover { error -> CloudItemMetadata in
			switch error {
			case CocoaError.fileReadNoSuchFile:
				throw CloudProviderError.itemNotFound
			case POSIXError.EISDIR:
				throw CloudProviderError.itemTypeMismatch
			default:
				throw error
			}
		}.always {
			try? FileManager.default.removeItem(at: ciphertextLocalURL)
		}
		return all(uploadFilePromise, parentDirIdPromise).then { ciphertextMetadata, parentDirId in
			return try self.toCleartextMetadata(ciphertextMetadata, cleartextParentPath: cleartextCloudPath.deletingLastPathComponent(), parentDirId: parentDirId)
		}
	}

	func createFolder(at cleartextCloudPath: CloudPath) -> Promise<Void> {
		let dirId = UUID().uuidString.data(using: .utf8)!
		let localDirFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let dirPath: CloudPath
		do {
			try dirId.write(to: localDirFileURL)
			dirPath = try getDirPath(dirId)
		} catch {
			return Promise(error)
		}
		let ciphertextCloudPathPromise = getC9RPath(cleartextCloudPath)
		return ciphertextCloudPathPromise.then { ciphertextCloudPath in
			return self.delegate.createFolder(at: ciphertextCloudPath)
		}.then { ciphertextCloudPathPromise }.then { ciphertextCloudPath -> Promise<CloudItemMetadata> in
			let dirFileCloudPath = ciphertextCloudPath.appendingDirFileComponent()
			return self.delegate.uploadFile(from: localDirFileURL, to: dirFileCloudPath, replaceExisting: false)
		}.then { _ -> Promise<Void> in
			let parentDirPath = dirPath.deletingLastPathComponent()
			return self.delegate.createFolderIfMissing(at: parentDirPath)
		}.then { () -> Promise<Void> in
			return self.delegate.createFolder(at: dirPath)
		}.then {
			try self.dirIdCache.addOrUpdate(cleartextCloudPath, dirId: dirId)
		}.always {
			try? FileManager.default.removeItem(at: localDirFileURL)
		}
	}

	func deleteFile(at cleartextCloudPath: CloudPath) -> Promise<Void> {
		return getC9RPath(cleartextCloudPath).then { ciphertextCloudPath in
			return self.delegate.deleteFile(at: ciphertextCloudPath)
		}
	}

	func deleteFolder(at cleartextCloudPath: CloudPath) -> Promise<Void> {
		return getDirId(cleartextCloudPath).then { dirId in
			return self.deleteCiphertextDir(dirId)
		}.recover { error -> Void in
			// recover from error if `getDirId()` rejects with `CloudProviderError.itemTypeMismatch` and delete item anyway (because it's probably a symlink)
			// recover from error if `deleteCiphertextDir()` rejects with `CloudProviderError.itemNotFound` and delete item anyway (because the directory is broken anyway)
			switch error {
			case CloudProviderError.itemNotFound, CloudProviderError.itemTypeMismatch:
				return
			default:
				throw error
			}
		}.then {
			return self.getC9RPath(cleartextCloudPath)
		}.then { ciphertextCloudPath in
			return self.delegate.deleteFolder(at: ciphertextCloudPath)
		}.then {
			try self.dirIdCache.invalidate(cleartextCloudPath)
		}
	}

	func moveFile(from cleartextSourceCloudPath: CloudPath, to cleartextTargetCloudPath: CloudPath) -> Promise<Void> {
		return all(getC9RPath(cleartextSourceCloudPath), getC9RPath(cleartextTargetCloudPath)).then { ciphertextSourceCloudPath, ciphertextTargetCloudPath in
			return self.delegate.moveFile(from: ciphertextSourceCloudPath, to: ciphertextTargetCloudPath)
		}
	}

	func moveFolder(from cleartextSourceCloudPath: CloudPath, to cleartextTargetCloudPath: CloudPath) -> Promise<Void> {
		return all(getC9RPath(cleartextSourceCloudPath), getC9RPath(cleartextTargetCloudPath)).then { ciphertextSourceCloudPath, ciphertextTargetCloudPath in
			return self.delegate.moveFolder(from: ciphertextSourceCloudPath, to: ciphertextTargetCloudPath)
		}.then {
			if let dirId = try self.dirIdCache.get(cleartextSourceCloudPath) {
				try self.dirIdCache.addOrUpdate(cleartextTargetCloudPath, dirId: dirId)
			}
			try self.dirIdCache.invalidate(cleartextSourceCloudPath)
		}
	}

	// MARK: - Encryption

	private func getDirId(_ cleartextPath: CloudPath) -> Promise<Data> {
		return dirIdCache.get(cleartextPath, onMiss: { cacheMissPath, parentDirId in
			let c9rPath = try self.getC9RPath(cacheMissPath, parentDirId: parentDirId)
			let dirFilePath = c9rPath.appendingDirFileComponent()
			return self.downloadFile(at: dirFilePath).recover { error -> Promise<Data> in
				guard case CloudProviderError.itemNotFound = error else {
					return Promise(error)
				}
				return self.delegate.checkForItemExistence(at: c9rPath).then { c9rItemExists in
					if c9rItemExists {
						// `*.c9r` exists but `*.c9r/dir.c9r` does not, so it's not a directory as expected
						throw CloudProviderError.itemTypeMismatch
					} else {
						throw CloudProviderError.itemNotFound
					}
				}
			}
		})
	}

	private func getParentDirId(_ cleartextPath: CloudPath) -> Promise<Data> {
		let cleartextParentPath = cleartextPath.deletingLastPathComponent()
		return getDirId(cleartextParentPath).recover { error -> Data in
			guard case CloudProviderError.itemNotFound = error else {
				throw error
			}
			throw CloudProviderError.parentFolderDoesNotExist
		}
	}

	func getDirPath(_ dirId: Data) throws -> CloudPath {
		let digest = try cryptor.encryptDirId(dirId)
		let i = digest.index(digest.startIndex, offsetBy: 2)
		return vaultPath.appendingPathComponent("d/\(digest[..<i])/\(digest[i...])")
	}

	private func getDirPath(_ cleartextPath: CloudPath) -> Promise<CloudPath> {
		return getDirId(cleartextPath).then { dirId in
			return try self.getDirPath(dirId)
		}
	}

	private func getC9RPath(_ cleartextPath: CloudPath, parentDirId: Data) throws -> CloudPath {
		let ciphertextBaseName = try cryptor.encryptFileName(cleartextPath.lastPathComponent, dirId: parentDirId)
		let ciphertextName = "\(ciphertextBaseName).c9r"
		return try getDirPath(parentDirId).appendingPathComponent(ciphertextName)
	}

	func getC9RPath(_ cleartextPath: CloudPath) -> Promise<CloudPath> {
		return getParentDirId(cleartextPath).then { parentDirId in
			return try self.getC9RPath(cleartextPath, parentDirId: parentDirId)
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
		let cleartextSize = try toCleartextSize(ciphertextMetadata.size, itemType: ciphertextMetadata.itemType)
		return CloudItemMetadata(name: cleartextName, cloudPath: cleartextPath, itemType: ciphertextMetadata.itemType, lastModifiedDate: ciphertextMetadata.lastModifiedDate, size: cleartextSize)
	}

	private func toCleartextSize(_ ciphertextSize: Int?, itemType: CloudItemType) throws -> Int? {
		guard let ciphertextSize = ciphertextSize else {
			return nil
		}
		if itemType == .file, ciphertextSize >= cryptor.fileHeaderSize {
			return try cryptor.calculateCleartextSize(ciphertextSize - cryptor.fileHeaderSize)
		} else {
			return ciphertextSize
		}
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

	private func deleteCiphertextDir(_ dirId: Data, pageToken: String? = nil) -> Promise<Void> {
		let dirPath: CloudPath
		do {
			dirPath = try getDirPath(dirId)
		} catch {
			return Promise(error)
		}
		let itemListPromise = delegate.fetchItemList(forFolderAt: dirPath, withPageToken: pageToken)
		let nextPageTokenPromise = itemListPromise.then { $0.nextPageToken }
		return itemListPromise.then { itemList in
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
				return nextPageTokenPromise
			}.then { nextPageToken -> Promise<Void> in
				if nextPageToken != nil {
					return self.deleteCiphertextDir(dirId, pageToken: nextPageToken)
				} else {
					return Promise(())
				}
			}.then { _ in
				// delete self
				return self.delegate.deleteFolder(at: dirPath)
			}
		}
	}
}
