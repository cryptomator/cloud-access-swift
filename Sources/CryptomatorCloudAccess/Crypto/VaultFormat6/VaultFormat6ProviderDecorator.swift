//
//  VaultFormat6ProviderDecorator.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation

/**
 Cloud provider decorator for Cryptomator vaults in vault format 6 (without name shortening).

 With this decorator, you can call the cloud provider methods with cleartext paths (relative to `vaultPath`) and the decorator passes ciphertext paths (absolute) to the delegate. It transparently encrypts/decrypts filenames and file contents according to vault format 6, see the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.4/security/architecture/).

 Use the factory methods to create a new crypto decorator. In order to be fully compatible with vault format 6, pass an instance of `VaultFormat6ShorteningProviderDecorator` (shortening decorator) as the delegate.
 */
final class VaultFormat6ProviderDecorator: CloudProvider {
	// swiftlint:disable:next weak_delegate
	let delegate: CloudProvider
	let vaultPath: CloudPath
	let cryptor: VaultCryptor
	let dirIdCache: DirectoryIdCache
	let tmpDirURL: URL

	init(delegate: CloudProvider, vaultPath: CloudPath, cryptor: VaultCryptor) throws {
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

	@concurrent
	func fetchItemMetadata(at cleartextCloudPath: CloudPath) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		let parentDirId = try await getParentDirId(cleartextCloudPath)
		let fileCiphertextPath = try getFileCiphertextPath(cleartextCloudPath, parentDirId: parentDirId)
		try Task.checkCancellation()
		let ciphertextMetadata: CloudItemMetadata
		do {
			ciphertextMetadata = try await delegate.fetchItemMetadata(at: fileCiphertextPath)
		} catch CloudProviderError.itemNotFound {
			let folderCiphertextPath = try getFolderCiphertextPath(cleartextCloudPath, parentDirId: parentDirId)
			try Task.checkCancellation()
			ciphertextMetadata = try await delegate.fetchItemMetadata(at: folderCiphertextPath)
		}
		return try toCleartextMetadata(ciphertextMetadata, cleartextParentPath: cleartextCloudPath.deletingLastPathComponent(), parentDirId: parentDirId)
	}

	@concurrent
	func fetchItemList(forFolderAt cleartextCloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try Task.checkCancellation()
		let dirId = try await getDirId(cleartextCloudPath)
		let dirPath = try getDirPath(dirId)
		try Task.checkCancellation()
		let ciphertextList = try await delegate.fetchItemList(forFolderAt: dirPath, withPageToken: pageToken)
		return try toCleartextList(ciphertextList, cleartextParentPath: cleartextCloudPath, parentDirId: dirId)
	}

	@concurrent
	func downloadFile(from cleartextCloudPath: CloudPath, to cleartextLocalURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(cleartextLocalURL.isFileURL)
		try Task.checkCancellation()
		let phases = Progress.phases(of: progress, 799, 200)
		let ciphertextLocalURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		defer {
			try? FileManager.default.removeItem(at: ciphertextLocalURL)
		}
		let parentDirId = try await getParentDirId(cleartextCloudPath)
		let fileCiphertextPath = try getFileCiphertextPath(cleartextCloudPath, parentDirId: parentDirId)
		try Task.checkCancellation()
		let ciphertextMetadata: CloudItemMetadata
		do {
			ciphertextMetadata = try await delegate.downloadFile(from: fileCiphertextPath, to: ciphertextLocalURL, progress: phases[0], onTaskCreation: onTaskCreation)
		} catch CloudProviderError.itemNotFound {
			let folderCiphertextPath = try getFolderCiphertextPath(cleartextCloudPath, parentDirId: parentDirId)
			try Task.checkCancellation()
			if try await delegate.checkForItemExistence(at: folderCiphertextPath) {
				throw CloudProviderError.itemTypeMismatch
			} else {
				throw CloudProviderError.itemNotFound
			}
		}
		let cleartextMetadata = try await DownloadOperation.download(to: cleartextLocalURL, transfer: { stagedFile in
			try await cryptor.decryptContent(from: ciphertextLocalURL, to: stagedFile, progress: phases[1])
			return try toCleartextMetadata(ciphertextMetadata, cleartextParentPath: cleartextCloudPath.deletingLastPathComponent(), parentDirId: parentDirId)
		})
		phases.completeTransfer()
		return cleartextMetadata
	}

	@concurrent
	func uploadFile(from cleartextLocalURL: URL, to cleartextCloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(cleartextLocalURL.isFileURL)
		try Task.checkCancellation()
		let phases = Progress.phases(of: progress, 799, 200)
		let ciphertextLocalURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		defer {
			try? FileManager.default.removeItem(at: ciphertextLocalURL)
		}
		let parentDirId = try await getParentDirId(cleartextCloudPath)
		let folderCiphertextPath = try getFolderCiphertextPath(cleartextCloudPath, parentDirId: parentDirId)
		try Task.checkCancellation()
		if try await delegate.checkForItemExistence(at: folderCiphertextPath) {
			throw CloudProviderError.itemAlreadyExists
		}
		let fileCiphertextPath = try getFileCiphertextPath(cleartextCloudPath, parentDirId: parentDirId)
		let ciphertextMetadata: CloudItemMetadata
		do {
			try await cryptor.encryptContent(from: cleartextLocalURL, to: ciphertextLocalURL, progress: phases[1])
			try Task.checkCancellation()
			ciphertextMetadata = try await delegate.uploadFile(from: ciphertextLocalURL, to: fileCiphertextPath, replaceExisting: replaceExisting, progress: phases[0], onTaskCreation: onTaskCreation)
		} catch CocoaError.fileReadNoSuchFile, POSIXError.ENOENT {
			throw CloudProviderError.itemNotFound
		} catch POSIXError.EISDIR {
			throw CloudProviderError.itemTypeMismatch
		}
		let cleartextMetadata = try toCleartextMetadata(ciphertextMetadata, cleartextParentPath: cleartextCloudPath.deletingLastPathComponent(), parentDirId: parentDirId)
		phases.completeTransfer()
		return cleartextMetadata
	}

	@concurrent
	func createFolder(at cleartextCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let dirId = UUID().uuidString.data(using: .utf8)!
		let localDirFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		defer {
			try? FileManager.default.removeItem(at: localDirFileURL)
		}
		try dirId.write(to: localDirFileURL)
		let dirPath = try getDirPath(dirId)
		let parentDirId = try await getParentDirId(cleartextCloudPath)
		let fileCiphertextPath = try getFileCiphertextPath(cleartextCloudPath, parentDirId: parentDirId)
		try Task.checkCancellation()
		if try await delegate.checkForItemExistence(at: fileCiphertextPath) {
			throw CloudProviderError.itemAlreadyExists
		}
		let folderCiphertextPath = try getFolderCiphertextPath(cleartextCloudPath, parentDirId: parentDirId)
		try Task.checkCancellation()
		try await withoutCancellation {
			_ = try await self.delegate.uploadFile(from: localDirFileURL, to: folderCiphertextPath, replaceExisting: false)
			let parentDirPath = dirPath.deletingLastPathComponent()
			try await self.delegate.createFolderIfMissing(at: parentDirPath)
			try await self.delegate.createFolder(at: dirPath)
			try self.dirIdCache.addOrUpdate(cleartextCloudPath, dirId: dirId)
		}
	}

	@concurrent
	func deleteFile(at cleartextCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let fileCiphertextPath = try await getFileCiphertextPath(cleartextCloudPath)
		try Task.checkCancellation()
		try await delegate.deleteFile(at: fileCiphertextPath)
	}

	@concurrent
	func deleteFolder(at cleartextCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		do {
			let dirId = try await getDirId(cleartextCloudPath)
			try await deleteCiphertextDir(dirId)
		} catch CloudProviderError.itemNotFound {
			// recover from error if `deleteCiphertextDir()` throws `CloudProviderError.itemNotFound` and delete item anyway (because the directory is broken anyway)
		}
		let folderCiphertextPath = try await getFolderCiphertextPath(cleartextCloudPath)
		try Task.checkCancellation()
		try await delegate.deleteFile(at: folderCiphertextPath)
		try dirIdCache.invalidate(cleartextCloudPath)
	}

	@concurrent
	func moveFile(from cleartextSourceCloudPath: CloudPath, to cleartextTargetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let fileCiphertextSourcePath = try await getFileCiphertextPath(cleartextSourceCloudPath)
		let fileCiphertextTargetPath = try await getFileCiphertextPath(cleartextTargetCloudPath)
		try Task.checkCancellation()
		try await delegate.moveFile(from: fileCiphertextSourcePath, to: fileCiphertextTargetPath)
	}

	@concurrent
	func moveFolder(from cleartextSourceCloudPath: CloudPath, to cleartextTargetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let folderCiphertextSourcePath = try await getFolderCiphertextPath(cleartextSourceCloudPath)
		let folderCiphertextTargetPath = try await getFolderCiphertextPath(cleartextTargetCloudPath)
		try Task.checkCancellation()
		try await delegate.moveFile(from: folderCiphertextSourcePath, to: folderCiphertextTargetPath)
		if let dirId = try dirIdCache.get(cleartextSourceCloudPath) {
			try dirIdCache.addOrUpdate(cleartextTargetCloudPath, dirId: dirId)
		}
		try dirIdCache.invalidate(cleartextSourceCloudPath)
	}

	// MARK: - Encryption

	private func getDirId(_ cleartextPath: CloudPath) async throws -> Data {
		return try await dirIdCache.get(cleartextPath, onMiss: { cleartextPath, parentDirId in
			let folderCiphertextPath = try self.getFolderCiphertextPath(cleartextPath, parentDirId: parentDirId)
			do {
				return try await self.downloadFile(at: folderCiphertextPath)
			} catch CloudProviderError.itemNotFound {
				let fileCiphertextPath = try self.getFileCiphertextPath(cleartextPath, parentDirId: parentDirId)
				try Task.checkCancellation()
				if try await self.delegate.checkForItemExistence(at: fileCiphertextPath) {
					// ciphertext file exists but ciphertext folder (with `0` prefix) does not
					// symlink existence check has been omitted for simplicity
					throw CloudProviderError.itemTypeMismatch
				} else {
					throw CloudProviderError.itemNotFound
				}
			}
		})
	}

	private func getParentDirId(_ cleartextPath: CloudPath) async throws -> Data {
		let cleartextParentPath = cleartextPath.deletingLastPathComponent()
		do {
			return try await getDirId(cleartextParentPath)
		} catch CloudProviderError.itemNotFound {
			throw CloudProviderError.parentFolderDoesNotExist
		}
	}

	private func getDirPath(_ dirId: Data) throws -> CloudPath {
		let digest = try cryptor.encryptDirId(dirId)
		let i = digest.index(digest.startIndex, offsetBy: 2)
		return vaultPath.appendingPathComponent("d/\(digest[..<i])/\(digest[i...])")
	}

	private func getFileCiphertextPath(_ cleartextPath: CloudPath, parentDirId: Data) throws -> CloudPath {
		let ciphertextName = try cryptor.encryptFileName(cleartextPath.lastPathComponent, dirId: parentDirId, encoding: .base32)
		return try getDirPath(parentDirId).appendingPathComponent(ciphertextName)
	}

	private func getFileCiphertextPath(_ cleartextPath: CloudPath) async throws -> CloudPath {
		let parentDirId = try await getParentDirId(cleartextPath)
		return try getFileCiphertextPath(cleartextPath, parentDirId: parentDirId)
	}

	private func getFolderCiphertextPath(_ cleartextPath: CloudPath, parentDirId: Data) throws -> CloudPath {
		let ciphertextBaseName = try cryptor.encryptFileName(cleartextPath.lastPathComponent, dirId: parentDirId, encoding: .base32)
		let ciphertextName = "0\(ciphertextBaseName)"
		return try getDirPath(parentDirId).appendingPathComponent(ciphertextName)
	}

	private func getFolderCiphertextPath(_ cleartextPath: CloudPath) async throws -> CloudPath {
		let parentDirId = try await getParentDirId(cleartextPath)
		return try getFolderCiphertextPath(cleartextPath, parentDirId: parentDirId)
	}

	// MARK: - Decryption

	private func toCleartextMetadata(_ ciphertextMetadata: CloudItemMetadata, cleartextParentPath: CloudPath, parentDirId: Data) throws -> CloudItemMetadata {
		let itemType = guessItemTypeByFileName(ciphertextMetadata.name)
		let ciphertextBaseName = getCiphertextBaseName(ciphertextMetadata.name, itemType: itemType)
		let cleartextName = try cryptor.decryptFileName(ciphertextBaseName, dirId: parentDirId, encoding: .base32)
		let cleartextPath = cleartextParentPath.appendingPathComponent(cleartextName)
		let cleartextSize = try toCleartextSize(ciphertextMetadata.size, itemType: itemType)
		return CloudItemMetadata(name: cleartextName, cloudPath: cleartextPath, itemType: itemType, lastModifiedDate: ciphertextMetadata.lastModifiedDate, size: cleartextSize)
	}

	private func guessItemTypeByFileName(_ fileName: String) -> CloudItemType {
		if fileName.hasPrefix("0") {
			return .folder
		} else if fileName.hasPrefix("1S") {
			return .symlink
		} else {
			return .file
		}
	}

	private func getCiphertextBaseName(_ ciphertextName: String, itemType: CloudItemType) -> String {
		switch itemType {
		case .folder:
			return String(ciphertextName.dropFirst())
		case .symlink:
			return String(ciphertextName.dropFirst(2))
		default:
			return ciphertextName
		}
	}

	private func toCleartextSize(_ ciphertextSize: Int?, itemType: CloudItemType) throws -> Int? {
		guard let ciphertextSize else {
			return nil
		}
		if itemType == .file || itemType == .symlink, ciphertextSize >= cryptor.fileHeaderSize {
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

	private func downloadFile(at cloudPath: CloudPath) async throws -> Data {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		defer {
			try? FileManager.default.removeItem(at: localURL)
		}
		_ = try await delegate.downloadFile(from: cloudPath, to: localURL)
		return try Data(contentsOf: localURL)
	}

	private func deleteCiphertextDir(_ dirId: Data) async throws {
		let dirPath = try getDirPath(dirId)
		var pageToken: String?
		repeat {
			try Task.checkCancellation()
			let itemList = try await delegate.fetchItemList(forFolderAt: dirPath, withPageToken: pageToken)
			let subDirs = itemList.items.filter { $0.name.hasPrefix("0") }
			let dirIds = try await allSettled(subDirs) { try await self.downloadFile(at: $0.cloudPath) }
			// delete subdirectories recursively
			_ = try await allSettled(dirIds) { try await self.deleteCiphertextDir($0) }
			pageToken = itemList.nextPageToken
		} while pageToken != nil
		// delete self
		try await delegate.deleteFolder(at: dirPath)
	}
}
