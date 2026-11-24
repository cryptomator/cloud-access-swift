//
//  VaultProviderDecorator.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 20.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Cloud provider decorator for Cryptomator vaults, in the vault format of its layout.

 With this decorator, you can call the cloud provider methods with cleartext paths (relative to `vaultPath`) and the decorator passes ciphertext paths (absolute) to the delegate. It transparently encrypts/decrypts filenames and file contents according to the vault format of its layout.

 Use `VaultProviderFactory` to create a new crypto decorator. It stacks the decorator onto the shortening decorator of its format, which is needed to be fully compatible with the format.
 */
final class VaultProviderDecorator<Layout: VaultLayout>: CloudProvider {
	let layout: Layout
	/// The provider that the decorator passes ciphertext paths to, the shortening decorator if there is one.
	let delegate: CloudProvider
	let shortening: Layout.Shortening?
	let vaultPath: CloudPath
	let cryptor: VaultCryptor
	let dirIdCache: DirectoryIdCache
	let tmpDirURL: URL

	/// The provider below any shortening decorator, which lists every item, also one whose shortened name can't be restored.
	var physicalProvider: CloudProvider {
		return shortening?.delegate ?? delegate
	}

	/// Stacks the decorator onto the provider directly, without name shortening.
	convenience init(provider: CloudProvider, vaultPath: CloudPath, cryptor: VaultCryptor) throws {
		try self.init(delegate: provider, shortening: nil, vaultPath: vaultPath, cryptor: cryptor)
	}

	/// Stacks the decorator onto the shortening decorator of its format.
	convenience init(shortening: Layout.Shortening, vaultPath: CloudPath, cryptor: VaultCryptor) throws {
		try self.init(delegate: shortening, shortening: shortening, vaultPath: vaultPath, cryptor: cryptor)
	}

	private init(delegate: CloudProvider, shortening: Layout.Shortening?, vaultPath: CloudPath, cryptor: VaultCryptor) throws {
		self.layout = Layout()
		self.delegate = delegate
		self.shortening = shortening
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
		if cleartextCloudPath == .root {
			return try await fetchRootMetadata()
		}
		try cleartextCloudPath.checkAsSource()
		let parentDirId = try await parentDirId(of: cleartextCloudPath)
		let ciphertextMetadata = try await layout.fetchCiphertextMetadata(cleartextCloudPath, parentDirId: parentDirId, in: self)
		return try cleartextMetadata(ciphertextMetadata, cleartextParentPath: cleartextCloudPath.deletingLastPathComponent(), parentDirId: parentDirId)
	}

	@concurrent
	func fetchItemList(forFolderAt cleartextCloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try Task.checkCancellation()
		let dirId = try await dirId(of: cleartextCloudPath)
		let dirPath = try dirPath(of: dirId)
		try Task.checkCancellation()
		let ciphertextList = try await delegate.fetchItemList(forFolderAt: dirPath, withPageToken: pageToken)
		return cleartextList(ciphertextList, cleartextParentPath: cleartextCloudPath, parentDirId: dirId)
	}

	@concurrent
	func downloadFile(from cleartextCloudPath: CloudPath, to cleartextLocalURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(cleartextLocalURL.isFileURL)
		try Task.checkCancellation()
		try cleartextCloudPath.checkAsSource()
		let phases = Progress.phases(of: progress, 799, 200)
		let ciphertextLocalURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
		defer {
			try? FileManager.default.removeItem(at: ciphertextLocalURL)
		}
		let parentDirId = try await parentDirId(of: cleartextCloudPath)
		let ciphertextMetadata = try await layout.downloadCiphertextFile(cleartextCloudPath, parentDirId: parentDirId, in: self) { ciphertextCloudPath in
			try await delegate.downloadFile(from: ciphertextCloudPath, to: ciphertextLocalURL, progress: phases[0], onTaskCreation: onTaskCreation)
		}
		let cleartextMetadata = try await DownloadOperation.download(to: cleartextLocalURL, transfer: { stagedFile in
			try await cryptor.decryptContent(from: ciphertextLocalURL, to: stagedFile, progress: phases[1])
			return try self.cleartextMetadata(ciphertextMetadata, cleartextParentPath: cleartextCloudPath.deletingLastPathComponent(), parentDirId: parentDirId)
		})
		phases.completeTransfer()
		return cleartextMetadata
	}

	@concurrent
	func uploadFile(from cleartextLocalURL: URL, to cleartextCloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(cleartextLocalURL.isFileURL)
		try Task.checkCancellation()
		let cleartextFile = try LocalUploadFile(cleartextLocalURL)
		try cleartextCloudPath.checkAsTarget()
		let phases = Progress.phases(of: progress, 799, 200)
		let ciphertextLocalURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
		defer {
			try? FileManager.default.removeItem(at: ciphertextLocalURL)
		}
		let parentDirId = try await parentDirId(of: cleartextCloudPath)
		try await layout.checkUploadTarget(cleartextCloudPath, parentDirId: parentDirId, in: self)
		let ciphertextCloudPath = try layout.fileCiphertextPath(cleartextCloudPath, parentDirId: parentDirId, in: self)
		do {
			try await cryptor.encryptContent(from: cleartextFile.url, to: ciphertextLocalURL, progress: phases[1])
		} catch CocoaError.fileReadNoSuchFile, POSIXError.ENOENT {
			throw CloudProviderError.itemNotFound
		} catch POSIXError.EISDIR {
			throw CloudProviderError.itemTypeMismatch
		}
		try Task.checkCancellation()
		let ciphertextMetadata = try await delegate.uploadFile(from: ciphertextLocalURL, to: ciphertextCloudPath, replaceExisting: replaceExisting, progress: phases[0], onTaskCreation: onTaskCreation)
		let cleartextMetadata = try cleartextMetadata(ciphertextMetadata, cleartextParentPath: cleartextCloudPath.deletingLastPathComponent(), parentDirId: parentDirId)
		phases.completeTransfer()
		return cleartextMetadata
	}

	@concurrent
	func createFolder(at cleartextCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try cleartextCloudPath.checkAsTarget()
		let dirId = UUID().uuidString.data(using: .utf8)!
		let dirIdFileURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
		let preparedFileURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
		defer {
			try? FileManager.default.removeItem(at: dirIdFileURL)
			try? FileManager.default.removeItem(at: preparedFileURL)
		}
		try dirId.write(to: dirIdFileURL)
		try await layout.prepareFolderCreation(dirIdFileURL: dirIdFileURL, preparedFileURL: preparedFileURL, in: self)
		let dirPath = try dirPath(of: dirId)
		let parentDirId = try await parentDirId(of: cleartextCloudPath)
		try await layout.checkFolderCreationTarget(cleartextCloudPath, parentDirId: parentDirId, in: self)
		let referencePath = try layout.folderReferencePath(cleartextCloudPath, parentDirId: parentDirId, in: self)
		try Task.checkCancellation()
		try await withoutCancellation {
			try await self.layout.createReference(at: referencePath, dirIdFileURL: dirIdFileURL, in: self)
			try await self.delegate.createFolderIfMissing(at: dirPath.deletingLastPathComponent())
			try await self.delegate.createFolder(at: dirPath)
			try await self.layout.didCreateDirectory(at: dirPath, preparedFileURL: preparedFileURL, in: self)
			try self.dirIdCache.addOrUpdate(cleartextCloudPath, dirId: dirId)
		}
	}

	@concurrent
	func deleteFile(at cleartextCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try cleartextCloudPath.checkAsSource()
		let parentDirId = try await parentDirId(of: cleartextCloudPath)
		let ciphertextCloudPath = try layout.fileCiphertextPath(cleartextCloudPath, parentDirId: parentDirId, in: self)
		try Task.checkCancellation()
		try await delegate.deleteFile(at: ciphertextCloudPath)
	}

	/**
	 Reads the dir IDs of the folder and of its ancestors from their dir files instead of the cache, because another device may have moved the folder away and created a new one at its path. Throws `VaultFormatError.invalidDirectoryReference` before deleting anything if a download reaches one of these dir files through an alias, or if one of them names the root or an ancestor.

	 The folder's directory and those of its subfolders are deleted before its reference, see `CiphertextDirectoryDeletion`. The delete lists the directories below any shortening decorator, and the layout resolves each listed item to the dir IDs it refers to.
	 */
	@concurrent
	func deleteFolder(at cleartextCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try cleartextCloudPath.checkAsSource()
		let directory = try await dirIdCache.verifiedDirectory(cleartextCloudPath, readDirId: { try await self.layout.readDirId($0, parentDirId: $1, refusingAlias: true, in: self) }, treatingAsMissing: layout.isMissingDirFile)
		let referencePath = try layout.folderReferencePath(cleartextCloudPath, parentDirId: directory.parentDirId, in: self)
		try await layout.checkReferenceBeforeDelete(at: referencePath, dirId: directory.dirId, in: self)
		try await withoutCancellation {
			if let dirId = directory.dirId {
				try await self.deleteCiphertextDirectory(of: dirId, containingDirIds: directory.containingDirIds)
			}
			do {
				try await self.layout.deleteReference(at: referencePath, in: self)
			} catch {
				// The folder's directory is gone by now, and the provider may have deleted the reference although it threw, so the path may not keep its cached dir ID. A failed invalidation must not replace the delete's error.
				try? self.dirIdCache.invalidate(cleartextCloudPath)
				throw error
			}
			try self.dirIdCache.invalidate(cleartextCloudPath)
		}
	}

	@concurrent
	func moveFile(from cleartextSourceCloudPath: CloudPath, to cleartextTargetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try cleartextSourceCloudPath.checkAsSource()
		try cleartextTargetCloudPath.checkAsTarget()
		let sourceParentDirId = try await parentDirId(of: cleartextSourceCloudPath)
		let ciphertextSourceCloudPath = try layout.fileCiphertextPath(cleartextSourceCloudPath, parentDirId: sourceParentDirId, in: self)
		let targetParentDirId = try await parentDirId(of: cleartextTargetCloudPath)
		let ciphertextTargetCloudPath = try layout.fileCiphertextPath(cleartextTargetCloudPath, parentDirId: targetParentDirId, in: self)
		try Task.checkCancellation()
		try await delegate.moveFile(from: ciphertextSourceCloudPath, to: ciphertextTargetCloudPath)
	}

	@concurrent
	func moveFolder(from cleartextSourceCloudPath: CloudPath, to cleartextTargetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try cleartextSourceCloudPath.checkAsSource()
		try cleartextTargetCloudPath.checkAsTarget()
		let sourceParentDirId = try await parentDirId(of: cleartextSourceCloudPath)
		let sourceReferencePath = try layout.folderReferencePath(cleartextSourceCloudPath, parentDirId: sourceParentDirId, in: self)
		let targetParentDirId = try await parentDirId(of: cleartextTargetCloudPath)
		let targetReferencePath = try layout.folderReferencePath(cleartextTargetCloudPath, parentDirId: targetParentDirId, in: self)
		try Task.checkCancellation()
		try await completingMove {
			do {
				try await layout.moveReference(from: sourceReferencePath, to: targetReferencePath, in: self)
			} catch let error where error as? CloudProviderError != .moveCompletedWithSourceRemaining {
				// The provider may have applied the move although it threw, so neither path may keep a cached dir ID. A failed invalidation must not replace the move's error.
				try? dirIdCache.invalidate(cleartextSourceCloudPath)
				try? dirIdCache.invalidate(cleartextTargetCloudPath)
				throw error
			}
		} finalize: {
			if let dirId = try dirIdCache.get(cleartextSourceCloudPath) {
				try dirIdCache.addOrUpdate(cleartextTargetCloudPath, dirId: dirId)
			}
			try dirIdCache.invalidate(cleartextSourceCloudPath)
		}
	}

	// MARK: - Encryption

	func dirId(of cleartextPath: CloudPath) async throws -> Data {
		return try await dirIdCache.get(cleartextPath, onMiss: { try await self.layout.readDirId($0, parentDirId: $1, refusingAlias: false, in: self) })
	}

	func parentDirId(of cleartextPath: CloudPath) async throws -> Data {
		do {
			return try await dirId(of: cleartextPath.deletingLastPathComponent())
		} catch CloudProviderError.itemNotFound {
			throw CloudProviderError.parentFolderDoesNotExist
		}
	}

	func dirPath(of dirId: Data) throws -> CloudPath {
		let digest = try cryptor.encryptDirId(dirId)
		let i = digest.index(digest.startIndex, offsetBy: 2)
		return vaultPath.appendingPathComponent("d/\(digest[..<i])/\(digest[i...])")
	}

	/// The encrypted name of the item in the directory of the given dir ID.
	func ciphertextName(of cleartextPath: CloudPath, parentDirId: Data) throws -> String {
		return try cryptor.encryptFileName(cleartextPath.lastPathComponent, dirId: parentDirId, encoding: layout.fileNameEncoding)
	}

	// MARK: - Decryption

	private func cleartextMetadata(_ ciphertextMetadata: CloudItemMetadata, cleartextParentPath: CloudPath, parentDirId: Data) throws -> CloudItemMetadata {
		let (ciphertextBaseName, itemType) = try layout.ciphertextItem(named: ciphertextMetadata.name, itemType: ciphertextMetadata.itemType)
		let cleartextName = try cryptor.decryptFileName(ciphertextBaseName, dirId: parentDirId, encoding: layout.fileNameEncoding)
		let cleartextPath = cleartextParentPath.appendingPathComponent(cleartextName)
		let cleartextSize = try cleartextSize(ciphertextMetadata.size, itemType: itemType)
		return CloudItemMetadata(name: cleartextName, cloudPath: cleartextPath, itemType: itemType, lastModifiedDate: ciphertextMetadata.lastModifiedDate, size: cleartextSize)
	}

	private func cleartextSize(_ ciphertextSize: Int?, itemType: CloudItemType) throws -> Int? {
		guard let ciphertextSize else {
			return nil
		}
		if layout.hasCleartextSize(itemType), ciphertextSize >= cryptor.fileHeaderSize {
			return try cryptor.calculateCleartextSize(ciphertextSize - cryptor.fileHeaderSize)
		} else {
			return ciphertextSize
		}
	}

	private func cleartextList(_ ciphertextList: CloudItemList, cleartextParentPath: CloudPath, parentDirId: Data) -> CloudItemList {
		let cleartextItems = ciphertextList.items.compactMap { try? self.cleartextMetadata($0, cleartextParentPath: cleartextParentPath, parentDirId: parentDirId) }.filter(\.name.isSinglePathComponent)
		return CloudItemList(items: cleartextItems, nextPageToken: ciphertextList.nextPageToken)
	}

	// MARK: - Convenience

	/// The root has no encrypted name to decrypt, so its metadata comes from its ciphertext directory. If that directory is gone, the root counts as missing.
	private func fetchRootMetadata() async throws -> CloudItemMetadata {
		let rootDirPath = try await dirPath(of: dirId(of: .root))
		let metadata = try await delegate.fetchItemMetadata(at: rootDirPath)
		guard metadata.itemType == .folder else {
			throw CloudProviderError.itemTypeMismatch
		}
		return CloudItemMetadata(name: CloudPath.root.lastPathComponent, cloudPath: .root, itemType: .folder, lastModifiedDate: metadata.lastModifiedDate, size: nil)
	}

	/// Must run inside `withoutCancellation`, because stopping halfway leaves folders whose directory is missing.
	private func deleteCiphertextDirectory(of dirId: Data, containingDirIds: Set<Data>) async throws {
		let deletion = CiphertextDirectoryDeletion(provider: physicalProvider, directoryPath: { try self.dirPath(of: $0) }, subdirectoryIds: { try await self.layout.subdirectoryIds(of: $0, in: self) })
		try await deletion.deleteDirectory(of: dirId, containingDirIds: containingDirIds)
	}
}
