//
//  VaultFormat7ShorteningProviderDecorator.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 18.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

/// Thrown for a `.c9s` directory that holds no `contents.c9r`, `dir.c9r` or `symlink.c9r`, e.g., after a failed upload or a partial delete, and for a file at a `.c9s` name. The listing skips it like `invalidNameFile`, so such a `.c9s` never fails the listing.
private struct C9SItemFileMissing: Error {}

private func isLeftOutOfListing(_ error: Error) -> Bool {
	return isInvalidNameFile(error) || error is C9SItemFileMissing
}

func guessItemTypeByC9SItemName(_ c9sItemName: String) -> CloudItemType {
	switch c9sItemName {
	case "contents.c9r":
		return .file
	case "dir.c9r":
		return .folder
	case "symlink.c9r":
		return .symlink
	default:
		return .unknown
	}
}

private extension CloudPath {
	func appendingNameFileComponent() -> CloudPath {
		return appendingPathComponent("name.c9s")
	}

	func appendingContentsFileComponent() -> CloudPath {
		return appendingPathComponent("contents.c9r")
	}
}

/**
 Cloud provider decorator for Cryptomator vaults in vault format 7 (only name shortening).

 With this decorator, it is expected that the cloud provider methods are being called with ciphertext paths. It transparently deflates/inflates filenames according to vault format 7, see the name shortening section at the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.5/security/architecture/#name-shortening).

 It's meaningless to use this shortening decorator without being decorated by an instance of `VaultFormat7ProviderDecorator` or `VaultFormat8ProviderDecorator` (crypto decorator). This shortening decorator explicitly only shortens the fourth path component relative to `vaultPath` if it exceeds the threshold, which is 220 characters unless a vault format 8 configuration gives another.
 */
final class VaultFormat7ShorteningProviderDecorator: VaultShorteningDecorator {
	let delegate: CloudProvider
	let shortenedNameCache: VaultFormat7ShortenedNameCache
	let tmpDirURL: URL

	init(delegate: CloudProvider, vaultPath: CloudPath, threshold: Int) throws {
		self.delegate = delegate
		self.shortenedNameCache = VaultFormat7ShortenedNameCache(vaultPath: vaultPath, threshold: threshold)
		self.tmpDirURL = try ProcessTemporaryDirectory.shared.makeDirectory()
	}

	convenience init(delegate: CloudProvider, vaultPath: CloudPath) throws {
		try self.init(delegate: delegate, vaultPath: vaultPath, threshold: 220)
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - CloudProvider API

	@concurrent
	func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if case .c9sDirectory = shortened {
			let shortenedMetadata = try await delegate.fetchItemMetadata(at: shortened.cloudPath)
			do {
				return try await getOriginalMetadata(shortenedMetadata)
			} catch is C9SItemFileMissing {
				throw CloudProviderError.itemNotFound
			}
		} else {
			return try await delegate.fetchItemMetadata(at: shortened.cloudPath)
		}
	}

	@concurrent
	func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try Task.checkCancellation()
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		let itemList = try await delegate.fetchItemList(forFolderAt: shortened.cloudPath, withPageToken: pageToken)
		let originalItems = try await allSettled(itemList.items, limit: vaultItemConcurrencyLimit, skipping: isLeftOutOfListing) { try await self.getOriginalMetadata($0) }
		return CloudItemList(items: originalItems, nextPageToken: itemList.nextPageToken)
	}

	@concurrent
	func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if case let .c9sDirectory(c9sDir) = shortened {
			let contentsFilePath = c9sDir.cloudPath.appendingContentsFileComponent()
			let contentsFileMetadata = try await delegate.downloadFile(from: contentsFilePath, to: localURL, progress: progress, onTaskCreation: onTaskCreation)
			return getOriginalFileMetadata(contentsFileMetadata, originalPath: cloudPath)
		} else {
			return try await delegate.downloadFile(from: shortened.cloudPath, to: localURL, progress: progress, onTaskCreation: onTaskCreation)
		}
	}

	@concurrent
	func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if case let .c9sDirectory(c9sDir) = shortened {
			let contentsFilePath = c9sDir.cloudPath.appendingContentsFileComponent()
			let newC9SContentsFileMetadata = try await withoutCancellation { () -> CloudItemMetadata? in
				do {
					try await self.delegate.createFolder(at: c9sDir.cloudPath)
				} catch CloudProviderError.itemAlreadyExists {
					return nil
				}
				try await self.uploadNameFile(c9sDir)
				return try await self.delegate.uploadFile(from: localURL, to: contentsFilePath, replaceExisting: replaceExisting, progress: progress, onTaskCreation: onTaskCreation)
			}
			if let newC9SContentsFileMetadata {
				return getOriginalFileMetadata(newC9SContentsFileMetadata, originalPath: cloudPath)
			}
			let contentsFileMetadata = try await uploadContentsFile(from: localURL, toExisting: c9sDir, replaceExisting: replaceExisting, progress: progress, onTaskCreation: onTaskCreation)
			return getOriginalFileMetadata(contentsFileMetadata, originalPath: cloudPath)
		} else {
			return try await delegate.uploadFile(from: localURL, to: shortened.cloudPath, replaceExisting: replaceExisting, progress: progress, onTaskCreation: onTaskCreation)
		}
	}

	@concurrent
	func createFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if case let .c9sDirectory(c9sDir) = shortened {
			try await withoutCancellation {
				try await self.createC9SFolderAndUploadNameFile(c9sDir)
			}
		} else {
			try await delegate.createFolder(at: shortened.cloudPath)
		}
	}

	@concurrent
	func deleteFile(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if case let .c9sDirectory(c9sDir) = shortened {
			try await restoringNameFile(of: c9sDir) {
				try await self.delegate.deleteFolder(at: c9sDir.cloudPath)
			}
		} else {
			try await delegate.deleteFile(at: shortened.cloudPath)
		}
	}

	@concurrent
	func deleteFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if case let .c9sDirectory(c9sDir) = shortened {
			try await restoringNameFile(of: c9sDir) {
				try await self.delegate.deleteFolder(at: c9sDir.cloudPath)
			}
		} else {
			try await delegate.deleteFolder(at: shortened.cloudPath)
		}
	}

	@concurrent
	func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let shortenedSource = shortenedNameCache.getShortenedPath(sourceCloudPath)
		let shortenedTarget = shortenedNameCache.getShortenedPath(targetCloudPath)
		switch (shortenedSource, shortenedTarget) {
		case let (.c9sDirectory, .c9sDirectory(targetC9SDir)):
			try await moveFolder(from: shortenedSource, toC9S: targetC9SDir)
		case let (.c9sDirectory(sourceC9SDir), _):
			try await withoutCancellation {
				// A move that left `contents.c9r` at the source keeps the source `.c9s` whole. Deleting the `.c9s` could remove `name.c9s` but not `contents.c9r`, and a `.c9s` without a name can't be listed.
				try await self.delegate.moveFile(from: sourceC9SDir.cloudPath.appendingContentsFileComponent(), to: shortenedTarget.cloudPath)
				do {
					try await self.delegate.deleteFolder(at: sourceC9SDir.cloudPath)
				} catch CloudProviderError.deletionIncomplete {
					throw CloudProviderError.moveCompletedWithSourceRemaining
				}
			}
		case let (_, .c9sDirectory(targetC9SDir)):
			try await withoutCancellation {
				try await self.createC9SFolderAndUploadNameFile(targetC9SDir)
				try await self.delegate.moveFile(from: shortenedSource.cloudPath, to: targetC9SDir.cloudPath.appendingContentsFileComponent())
			}
		default:
			try await delegate.moveFile(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath)
		}
	}

	@concurrent
	func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let shortenedSource = shortenedNameCache.getShortenedPath(sourceCloudPath)
		let shortenedTarget = shortenedNameCache.getShortenedPath(targetCloudPath)
		switch (shortenedSource, shortenedTarget) {
		case let (_, .c9sDirectory(targetC9SDir)):
			try await moveFolder(from: shortenedSource, toC9S: targetC9SDir)
		case let (.c9sDirectory(sourceC9SDir), _):
			try await withoutCancellation {
				var isSourceRemaining = false
				do {
					try await self.restoringNameFile(of: sourceC9SDir) {
						try await self.delegate.moveFolder(from: sourceC9SDir.cloudPath, to: shortenedTarget.cloudPath)
					}
				} catch CloudProviderError.moveCompletedWithSourceRemaining {
					isSourceRemaining = true
				}
				do {
					try await self.delegate.deleteFile(at: shortenedTarget.cloudPath.appendingNameFileComponent())
				} catch where (isSourceRemaining || error as? CloudProviderError == .deletionIncomplete) && !(error is CancellationError) {
					// Only a `.c9s` path loads a name file, so the stale one in the `.c9r` folder is never read. A refused delete of it therefore leaves nothing to report. After a move that left leftovers, no failure but cancellation replaces `moveCompletedWithSourceRemaining`.
				}
				if isSourceRemaining {
					throw CloudProviderError.moveCompletedWithSourceRemaining
				}
			}
		default:
			try await delegate.moveFolder(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath)
		}
	}

	// MARK: - Internal

	/// Moves a folder to a `.c9s` and uploads the target's name file, also if the move left leftovers at the source. A `.c9s` source with leftovers gets its name file back before that upload, so that the leftovers stay listable even if the upload fails.
	private func moveFolder(from shortenedSource: VaultFormat7ShorteningResult, toC9S targetC9SDir: C9SDir) async throws {
		try await withoutCancellation {
			try await completingMove {
				do {
					try await self.delegate.moveFolder(from: shortenedSource.cloudPath, to: targetC9SDir.cloudPath)
				} catch CloudProviderError.moveCompletedWithSourceRemaining {
					if case let .c9sDirectory(sourceC9SDir) = shortenedSource {
						try await self.restoreNameFile(of: sourceC9SDir)
					}
					throw CloudProviderError.moveCompletedWithSourceRemaining
				}
			} finalize: {
				try await self.uploadNameFile(targetC9SDir)
			}
		}
	}

	/// Lists a `.c9s` directory before loading its name, so that a `.c9s` without an item file throws `C9SItemFileMissing` whether or not it holds a name file.
	private func getOriginalMetadata(_ shortenedMetadata: CloudItemMetadata) async throws -> CloudItemMetadata {
		guard shortenedNameCache.isC9SDirectory(shortenedMetadata.cloudPath) else {
			let originalPath = try await getOriginalPath(shortenedMetadata.cloudPath)
			return CloudItemMetadata(name: shortenedMetadata.name, cloudPath: originalPath, itemType: shortenedMetadata.itemType, lastModifiedDate: shortenedMetadata.lastModifiedDate, size: shortenedMetadata.size)
		}
		let c9sItemMetadata = try await fetchC9SItemMetadata(shortenedMetadata.cloudPath)
		let originalPath = try await getOriginalPath(shortenedMetadata.cloudPath)
		let originalItemType = guessItemTypeByC9SItemName(c9sItemMetadata.name)
		let originalLastModifiedDate = originalItemType == .folder ? shortenedMetadata.lastModifiedDate : c9sItemMetadata.lastModifiedDate
		let originalSize = originalItemType == .folder ? shortenedMetadata.size : c9sItemMetadata.size
		return CloudItemMetadata(name: originalPath.lastPathComponent, cloudPath: originalPath, itemType: originalItemType, lastModifiedDate: originalLastModifiedDate, size: originalSize)
	}

	private func getOriginalPath(_ shortenedPath: CloudPath) async throws -> CloudPath {
		return try await shortenedNameCache.getOriginalPath(shortenedPath, nameC9SLoader: { try await self.downloadNameFile($0) })
	}

	/// Doesn't request anything, so that a download and an upload can still build the metadata to return after their commit point.
	private func getOriginalFileMetadata(_ contentsFileMetadata: CloudItemMetadata, originalPath: CloudPath) -> CloudItemMetadata {
		return CloudItemMetadata(name: originalPath.lastPathComponent, cloudPath: originalPath, itemType: .file, lastModifiedDate: contentsFileMetadata.lastModifiedDate, size: contentsFileMetadata.size)
	}

	private func downloadNameFile(_ c9sDirPath: CloudPath) async throws -> Data {
		return try await delegate.downloadNameFile(at: c9sDirPath.appendingNameFileComponent())
	}

	private func fetchC9SItemMetadata(_ c9sDirPath: CloudPath) async throws -> CloudItemMetadata {
		var pageToken: String?
		repeat {
			try Task.checkCancellation()
			let c9sItemList: CloudItemList
			do {
				c9sItemList = try await delegate.fetchItemList(forFolderAt: c9sDirPath, withPageToken: pageToken)
			} catch CloudProviderError.itemTypeMismatch {
				throw C9SItemFileMissing()
			}
			if let c9sItemMetadata = c9sItemList.items.first(where: { guessItemTypeByC9SItemName($0.name) != .unknown }) {
				return c9sItemMetadata
			}
			pageToken = c9sItemList.nextPageToken
		} while pageToken != nil
		throw C9SItemFileMissing()
	}

	/**
	 Uploads the contents file of a file to its `.c9s` directory that already exists, e.g., to overwrite the file or after a failed upload left the `.c9s`. The only remote change before the contents upload is a missing name file, which just completes the existing `.c9s`. So every step up to the contents upload can be cancelled.

	 A `.c9s` that holds only a name file can also be another client's folder creation, between its name file and its `dir.c9r`. If this upload runs in between, both succeed, and the `.c9s` holds both `contents.c9r` and `dir.c9r`. That needs two clients to pick the same long name for a folder and a file at nearly the same time, so it isn't guarded against.

	 - Throws: `CloudProviderError.itemAlreadyExists` if the `.c9s` is a file, if it holds a folder or a symlink, or if it holds `contents.c9r` and `replaceExisting` is `false`.
	 */
	private func uploadContentsFile(from localURL: URL, toExisting c9sDir: C9SDir, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		let c9sItemNames: [String]
		do {
			c9sItemNames = try await delegate.fetchItemListExhaustively(forFolderAt: c9sDir.cloudPath).items.map(\.name)
		} catch CloudProviderError.itemTypeMismatch {
			throw CloudProviderError.itemAlreadyExists
		}
		let c9sItemTypes = c9sItemNames.map { guessItemTypeByC9SItemName($0) }
		if c9sItemTypes.contains(.folder) || c9sItemTypes.contains(.symlink) {
			throw CloudProviderError.itemAlreadyExists
		}
		try Task.checkCancellation()
		if !c9sItemNames.contains("name.c9s") {
			try await uploadNameFile(c9sDir)
			try Task.checkCancellation()
		}
		return try await delegate.uploadFile(from: localURL, to: c9sDir.cloudPath.appendingContentsFileComponent(), replaceExisting: replaceExisting, progress: progress, onTaskCreation: onTaskCreation)
	}

	private func createC9SFolderAndUploadNameFile(_ c9sDir: C9SDir) async throws {
		try await delegate.createFolder(at: c9sDir.cloudPath)
		try await uploadNameFile(c9sDir)
	}

	/// Runs a delete or move of a `.c9s` and, if it left leftovers, restores its name file.
	private func restoringNameFile(of c9sDir: C9SDir, after mutation: () async throws -> Void) async throws {
		do {
			try await mutation()
		} catch let leftoverError as CloudProviderError where [.deletionIncomplete, .moveCompletedWithSourceRemaining].contains(leftoverError) {
			try await restoreNameFile(of: c9sDir)
			throw leftoverError
		}
	}

	/**
	 Uploads the name file of an item's `.c9s` again after a delete or move left leftovers of it.

	 The cloud can delete the name file but refuse to delete the rest, and a `.c9s` without a name file fails a listing page on which no other item is restored. With the name file, the leftovers list under the item's name, so that a later delete can find them.

	 - Throws: Only cancellation. A failed upload is ignored, so that it doesn't replace the outcome of the delete or move.
	 */
	private func restoreNameFile(of c9sDir: C9SDir) async throws {
		do {
			try await uploadNameFile(c9sDir)
		} catch where !(error is CancellationError) {
			// The outcome of the delete or move stands.
		}
	}

	private func uploadNameFile(_ c9sDir: C9SDir) async throws {
		let localNameFileURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
		defer {
			try? FileManager.default.removeItem(at: localNameFileURL)
		}
		try c9sDir.originalName.write(to: localNameFileURL, atomically: true, encoding: .utf8)
		let nameFileCloudPath = c9sDir.cloudPath.appendingNameFileComponent()
		_ = try await delegate.uploadFile(from: localNameFileURL, to: nameFileCloudPath, replaceExisting: true)
	}
}
