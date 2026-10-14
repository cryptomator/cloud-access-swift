//
//  VaultFormat7ProviderDecorator.swift
//  CryptomatorCloudAccess
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

private extension CloudPath {
	func appendingDirFileComponent() -> CloudPath {
		return appendingPathComponent("dir.c9r")
	}
}

/**
 Cloud provider decorator for Cryptomator vaults in vault format 7 (without name shortening).

 With this decorator, you can call the cloud provider methods with cleartext paths (relative to `vaultPath`) and the decorator passes ciphertext paths (absolute) to the delegate. It transparently encrypts/decrypts filenames and file contents according to vault format 7, see the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.5/security/architecture/).

 Use the factory methods to create a new crypto decorator. In order to be fully compatible with vault format 7, pass an instance of `VaultFormat7ShorteningProviderDecorator` (shortening decorator) as the delegate.

 `@unchecked Sendable`: all stored properties are immutable and `Sendable`. The class is subclassed by `VaultFormat8ProviderDecorator`.
 */
class VaultFormat7ProviderDecorator: CloudProvider, @unchecked Sendable {
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
		let ciphertextCloudPath = try getC9RPath(cleartextCloudPath, parentDirId: parentDirId)
		try Task.checkCancellation()
		let ciphertextMetadata = try await delegate.fetchItemMetadata(at: ciphertextCloudPath)
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
		let ciphertextCloudPath = try getC9RPath(cleartextCloudPath, parentDirId: parentDirId)
		try Task.checkCancellation()
		let ciphertextMetadata = try await delegate.downloadFile(from: ciphertextCloudPath, to: ciphertextLocalURL, progress: phases[0], onTaskCreation: onTaskCreation)
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
		let ciphertextCloudPath = try getC9RPath(cleartextCloudPath, parentDirId: parentDirId)
		let ciphertextMetadata: CloudItemMetadata
		do {
			try await cryptor.encryptContent(from: cleartextLocalURL, to: ciphertextLocalURL, progress: phases[1])
			try Task.checkCancellation()
			ciphertextMetadata = try await delegate.uploadFile(from: ciphertextLocalURL, to: ciphertextCloudPath, replaceExisting: replaceExisting, progress: phases[0], onTaskCreation: onTaskCreation)
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
		let ciphertextCloudPath = try await getC9RPath(cleartextCloudPath)
		try Task.checkCancellation()
		try await withoutCancellation {
			try await self.delegate.createFolder(at: ciphertextCloudPath)
			let dirFileCloudPath = ciphertextCloudPath.appendingDirFileComponent()
			_ = try await self.delegate.uploadFile(from: localDirFileURL, to: dirFileCloudPath, replaceExisting: false)
			let parentDirPath = dirPath.deletingLastPathComponent()
			try await self.delegate.createFolderIfMissing(at: parentDirPath)
			try await self.delegate.createFolder(at: dirPath)
			try self.dirIdCache.addOrUpdate(cleartextCloudPath, dirId: dirId)
		}
	}

	@concurrent
	func deleteFile(at cleartextCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let ciphertextCloudPath = try await getC9RPath(cleartextCloudPath)
		try Task.checkCancellation()
		try await delegate.deleteFile(at: ciphertextCloudPath)
	}

	@concurrent
	func deleteFolder(at cleartextCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let dirId: Data?
		do {
			dirId = try await getDirId(cleartextCloudPath)
		} catch CloudProviderError.itemNotFound, CloudProviderError.itemTypeMismatch {
			// `itemTypeMismatch`: the `.c9r` has no `dir.c9r`, e.g., it's a symlink, so delete it anyway
			// `itemNotFound`: the steps below throw the precise error
			dirId = nil
		}
		let ciphertextCloudPath = try await getC9RPath(cleartextCloudPath)
		try Task.checkCancellation()
		try await withoutCancellation {
			if let dirId {
				do {
					try await self.deleteCiphertextDir(dirId)
				} catch CloudProviderError.itemNotFound, CloudProviderError.itemTypeMismatch {
					// the directory is broken, so delete the `.c9r` anyway
				}
			}
			try await self.delegate.deleteFolder(at: ciphertextCloudPath)
			try self.dirIdCache.invalidate(cleartextCloudPath)
		}
	}

	@concurrent
	func moveFile(from cleartextSourceCloudPath: CloudPath, to cleartextTargetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let ciphertextSourceCloudPath = try await getC9RPath(cleartextSourceCloudPath)
		let ciphertextTargetCloudPath = try await getC9RPath(cleartextTargetCloudPath)
		try Task.checkCancellation()
		try await delegate.moveFile(from: ciphertextSourceCloudPath, to: ciphertextTargetCloudPath)
	}

	@concurrent
	func moveFolder(from cleartextSourceCloudPath: CloudPath, to cleartextTargetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let ciphertextSourceCloudPath = try await getC9RPath(cleartextSourceCloudPath)
		let ciphertextTargetCloudPath = try await getC9RPath(cleartextTargetCloudPath)
		try Task.checkCancellation()
		try await delegate.moveFolder(from: ciphertextSourceCloudPath, to: ciphertextTargetCloudPath)
		if let dirId = try dirIdCache.get(cleartextSourceCloudPath) {
			try dirIdCache.addOrUpdate(cleartextTargetCloudPath, dirId: dirId)
		}
		try dirIdCache.invalidate(cleartextSourceCloudPath)
	}

	// MARK: - Encryption

	private func getDirId(_ cleartextPath: CloudPath) async throws -> Data {
		return try await dirIdCache.get(cleartextPath, onMiss: { cacheMissPath, parentDirId in
			let c9rPath = try self.getC9RPath(cacheMissPath, parentDirId: parentDirId)
			let dirFilePath = c9rPath.appendingDirFileComponent()
			do {
				return try await self.downloadFile(at: dirFilePath)
			} catch CloudProviderError.itemNotFound {
				try Task.checkCancellation()
				if try await self.delegate.checkForItemExistence(at: c9rPath) {
					// `*.c9r` exists but `*.c9r/dir.c9r` does not, so it's not a directory as expected
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

	func getDirPath(_ dirId: Data) throws -> CloudPath {
		let digest = try cryptor.encryptDirId(dirId)
		let i = digest.index(digest.startIndex, offsetBy: 2)
		return vaultPath.appendingPathComponent("d/\(digest[..<i])/\(digest[i...])")
	}

	private func getC9RPath(_ cleartextPath: CloudPath, parentDirId: Data) throws -> CloudPath {
		let ciphertextBaseName = try cryptor.encryptFileName(cleartextPath.lastPathComponent, dirId: parentDirId)
		let ciphertextName = "\(ciphertextBaseName).c9r"
		return try getDirPath(parentDirId).appendingPathComponent(ciphertextName)
	}

	func getC9RPath(_ cleartextPath: CloudPath) async throws -> CloudPath {
		let parentDirId = try await getParentDirId(cleartextPath)
		return try getC9RPath(cleartextPath, parentDirId: parentDirId)
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
		guard let ciphertextSize else {
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

	private func downloadFile(at cloudPath: CloudPath) async throws -> Data {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		defer {
			try? FileManager.default.removeItem(at: localURL)
		}
		_ = try await delegate.downloadFile(from: cloudPath, to: localURL)
		return try Data(contentsOf: localURL)
	}

	/// Must run inside `withoutCancellation`, because stopping halfway leaves folders whose directory is missing.
	private func deleteCiphertextDir(_ dirId: Data) async throws {
		let dirPath = try getDirPath(dirId)
		var pageToken: String?
		repeat {
			let itemList = try await delegate.fetchItemList(forFolderAt: dirPath, withPageToken: pageToken)
			let subDirs = itemList.items.filter { $0.itemType == .folder }
			let subDirItemLists = try await withThrowingTaskGroup(of: CloudItemList.self) { group in
				for subDir in subDirs {
					group.addTask {
						try await self.delegate.fetchItemListExhaustively(forFolderAt: subDir.cloudPath)
					}
				}
				var subDirItemLists = [CloudItemList]()
				for try await subDirItemList in group {
					subDirItemLists.append(subDirItemList)
				}
				return subDirItemLists
			}
			// find subdirectories
			let allDirFiles = subDirItemLists.flatMap(\.items).filter { $0.name == "dir.c9r" }
			let dirIds = try await allSettled(allDirFiles) { try await self.downloadFile(at: $0.cloudPath) }
			// delete subdirectories recursively
			_ = try await allSettled(dirIds) { try await self.deleteCiphertextDir($0) }
			pageToken = itemList.nextPageToken
		} while pageToken != nil
		// delete self
		try await delegate.deleteFolder(at: dirPath)
	}
}
