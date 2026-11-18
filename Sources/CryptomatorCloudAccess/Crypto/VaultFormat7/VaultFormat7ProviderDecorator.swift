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

/// Whether a listed item of a `.c9r` or `.c9s` is the file that holds its dir ID. A folder of that name holds none.
private func isDirFile(_ item: CloudItemMetadata) -> Bool {
	return item.name == "dir.c9r" && item.itemType == .file
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
		self.tmpDirURL = try ProcessTemporaryDirectory.shared.makeDirectory()
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

	/// Reads the dir IDs of the folder and of its ancestors from their dir files instead of the cache, because another device may have moved the folder away and created a new one at its path.
	@concurrent
	func deleteFolder(at cleartextCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let directory = try await dirIdCache.verifiedDirectory(cleartextCloudPath, readDirId: { try await self.readDirId($0, parentDirId: $1) }, treatingAsMissing: { error in
			// `itemTypeMismatch`: the `.c9r` exists, but the download found no `dir.c9r`, e.g., it's a symlink.
			// `itemNotFound`: the `.c9r` is gone, or it's a `.c9s` that the shortening decorator reports as missing because it holds no item file.
			// Either way it's deleted without a walk unless it lists a `dir.c9r`.
			switch error {
			case CloudProviderError.itemNotFound, CloudProviderError.itemTypeMismatch:
				return true
			default:
				return false
			}
		})
		let ciphertextCloudPath = try getC9RPath(cleartextCloudPath, parentDirId: directory.parentDirId)
		let holdsUnreadableDirFile = directory.dirId == nil ? try await holdsDirFile(ciphertextCloudPath) : false
		try Task.checkCancellation()
		if holdsUnreadableDirFile {
			// A provider that addresses items by cached IDs reports a `dir.c9r` that another client replaced as missing. Deleting the `.c9r` would orphan its directory. A later delete can read the new ID once the provider has cached it, which some providers' listings do.
			throw CloudProviderError.itemNotFound
		}
		try await withoutCancellation {
			if let dirId = directory.dirId {
				try await self.deleteCiphertextDir(dirId, containingDirIds: directory.containingDirIds)
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
		try await completingMove {
			try await delegate.moveFolder(from: ciphertextSourceCloudPath, to: ciphertextTargetCloudPath)
		} finalize: {
			if let dirId = try dirIdCache.get(cleartextSourceCloudPath) {
				try dirIdCache.addOrUpdate(cleartextTargetCloudPath, dirId: dirId)
			}
			try dirIdCache.invalidate(cleartextSourceCloudPath)
		}
	}

	// MARK: - Encryption

	private func getDirId(_ cleartextPath: CloudPath) async throws -> Data {
		return try await dirIdCache.get(cleartextPath, onMiss: { try await self.readDirId($0, parentDirId: $1) })
	}

	private func readDirId(_ cleartextPath: CloudPath, parentDirId: Data) async throws -> Data {
		let c9rPath = try getC9RPath(cleartextPath, parentDirId: parentDirId)
		let dirFilePath = c9rPath.appendingDirFileComponent()
		do {
			return try await downloadFile(at: dirFilePath, of: delegate)
		} catch CloudProviderError.itemNotFound {
			try Task.checkCancellation()
			if try await delegate.checkForItemExistence(at: c9rPath) {
				// `*.c9r` exists but `*.c9r/dir.c9r` does not, so it's not a directory as expected
				throw CloudProviderError.itemTypeMismatch
			} else {
				throw CloudProviderError.itemNotFound
			}
		}
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
		let cleartextItems = ciphertextList.items.compactMap { try? self.toCleartextMetadata($0, cleartextParentPath: cleartextParentPath, parentDirId: parentDirId) }.filter(\.name.isSinglePathComponent)
		return CloudItemList(items: cleartextItems, nextPageToken: ciphertextList.nextPageToken)
	}

	// MARK: - Convenience

	private func downloadFile(at cloudPath: CloudPath, of provider: CloudProvider) async throws -> Data {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		defer {
			try? FileManager.default.removeItem(at: localURL)
		}
		_ = try await provider.downloadFile(from: cloudPath, to: localURL)
		return try Data(contentsOf: localURL)
	}

	/// The provider below the shortening decorator, which lists every item, also one whose shortened name can't be restored.
	private var physicalDelegate: CloudProvider {
		return (delegate as? VaultFormat7ShorteningProviderDecorator)?.delegate ?? delegate
	}

	/// Whether the folder of a `.c9r` or `.c9s` holds a `dir.c9r` file, as listed below the shortening decorator. A first page that throws `itemNotFound` or `itemTypeMismatch` means none. Any other failure is thrown, because the pages not listed yet may hold it.
	private func holdsDirFile(_ c9rPath: CloudPath) async throws -> Bool {
		let shorteningDecorator = delegate as? VaultFormat7ShorteningProviderDecorator
		let provider = shorteningDecorator?.delegate ?? delegate
		let containerPath = shorteningDecorator?.shortenedNameCache.getShortenedPath(c9rPath).cloudPath ?? c9rPath
		var pageToken: String?
		repeat {
			try Task.checkCancellation()
			let itemList: CloudItemList
			do {
				itemList = try await provider.fetchItemList(forFolderAt: containerPath, withPageToken: pageToken)
			} catch let error as CloudProviderError where pageToken == nil && [.itemNotFound, .itemTypeMismatch].contains(error) {
				return false
			}
			if itemList.items.contains(where: isDirFile) {
				return true
			}
			pageToken = itemList.nextPageToken
		} while pageToken != nil
		return false
	}

	/**
	 Must run inside `withoutCancellation`, because stopping halfway leaves folders whose directory is missing.

	 Lists below the shortening decorator and follows every `dir.c9r` file of a `.c9r` or `.c9s` folder without reading its name, so that a subfolder whose `name.c9s` is invalid or can't be read is deleted with its parent instead of keeping a directory without a reference.
	 */
	private func deleteCiphertextDir(_ dirId: Data, containingDirIds: Set<Data>) async throws {
		let provider = physicalDelegate
		let deletion = CiphertextDirectoryDeletion(provider: provider, directoryPath: { try self.getDirPath($0) }, subdirectoryIds: { item in
			guard item.itemType == .folder, item.name.hasSuffix(".c9r") || item.name.hasSuffix(".c9s") else {
				return []
			}
			var dirIds = [Data]()
			for dirFile in try await provider.fetchItemListExhaustively(forFolderAt: item.cloudPath).items where isDirFile(dirFile) {
				try await dirIds.append(self.downloadFile(at: dirFile.cloudPath, of: provider))
			}
			return dirIds
		})
		try await deletion.deleteDirectory(of: dirId, containingDirIds: containingDirIds)
	}
}
