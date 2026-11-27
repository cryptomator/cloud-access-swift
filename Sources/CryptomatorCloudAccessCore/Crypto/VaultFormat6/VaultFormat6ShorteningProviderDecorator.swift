//
//  VaultFormat6ShorteningProviderDecorator.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

/// Thrown for a listed item whose legacy name couldn't be restored to its original name, because the move failed or the original name's lookup didn't confirm it. The listing skips it like `invalidNameFile`, so such an item never fails the listing.
private struct LegacyNameNotMoved: Error {}

private func isLeftOutOfListing(_ error: Error) -> Bool {
	return isInvalidNameFile(error) || error is LegacyNameNotMoved
}

/**
 Cloud provider decorator for Cryptomator vaults in vault format 6 (only name shortening).

 With this decorator, it is expected that the cloud provider methods are being called with ciphertext paths. It transparently deflates/inflates filenames according to vault format 6, see the name shortening section at the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.4/security/architecture/#name-shortening).

 It's meaningless to use this shortening decorator without being decorated by an instance of `VaultFormat6ProviderDecorator` (crypto decorator). This shortening decorator explicitly only shortens the fourth path component relative to `vaultPath`.
 */
final class VaultFormat6ShorteningProviderDecorator: VaultShorteningDecorator {
	let delegate: CloudProvider
	let vaultPath: CloudPath
	let shortenedNameCache: VaultFormat6ShortenedNameCache
	let tmpDirURL: URL

	init(delegate: CloudProvider, vaultPath: CloudPath) throws {
		self.delegate = delegate
		self.vaultPath = vaultPath
		self.shortenedNameCache = VaultFormat6ShortenedNameCache(vaultPath: vaultPath)
		self.tmpDirURL = try ProcessTemporaryDirectory.shared.makeDirectory()
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - CloudProvider API

	@concurrent
	func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if shortened.pointsToLNG {
			let shortenedMetadata = try await delegate.fetchItemMetadata(at: shortened.cloudPath)
			return try await getOriginalMetadata(shortenedMetadata)
		} else {
			return try await delegate.fetchItemMetadata(at: shortened.cloudPath)
		}
	}

	@concurrent
	func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try Task.checkCancellation()
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		let itemList = try await delegate.fetchItemList(forFolderAt: shortened.cloudPath, withPageToken: pageToken)
		let originalItems = try await allSettled(itemList.items, limit: vaultItemConcurrencyLimit, skipping: isLeftOutOfListing) { try await self.getOriginalMetadataOfListedItem($0) }
		// A page can hold a legacy name and its original name, which restore to the same path, e.g., if it was listed while another listing moved the item on a provider that copies and then deletes. Paths are compared by bytes, because a `String` set would merge a name file's canonically equivalent spelling with the original name. Cryptolib can't decrypt that spelling, so it must not take the place of the item's own entry.
		var returnedPaths = Set<[UInt8]>()
		let uniqueItems = originalItems.filter { returnedPaths.insert(Array($0.cloudPath.path.utf8)).inserted }
		return CloudItemList(items: uniqueItems, nextPageToken: itemList.nextPageToken)
	}

	@concurrent
	func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		let shortenedMetadata = try await delegate.downloadFile(from: shortened.cloudPath, to: localURL, progress: progress, onTaskCreation: onTaskCreation)
		if shortened.pointsToLNG {
			return getOriginalMetadata(shortenedMetadata, originalPath: cloudPath)
		} else {
			return shortenedMetadata
		}
	}

	@concurrent
	func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if shortened.pointsToLNG {
			try await uploadNameFile(shortened.cloudPath.lastPathComponent, originalName: cloudPath.lastPathComponent)
			let shortenedMetadata = try await delegate.uploadFile(from: localURL, to: shortened.cloudPath, replaceExisting: replaceExisting, progress: progress, onTaskCreation: onTaskCreation)
			return getOriginalMetadata(shortenedMetadata, originalPath: cloudPath)
		} else {
			return try await delegate.uploadFile(from: localURL, to: shortened.cloudPath, replaceExisting: replaceExisting, progress: progress, onTaskCreation: onTaskCreation)
		}
	}

	@concurrent
	func createFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if shortened.pointsToLNG {
			try await uploadNameFile(shortened.cloudPath.lastPathComponent, originalName: cloudPath.lastPathComponent)
		}
		try await delegate.createFolder(at: shortened.cloudPath)
	}

	@concurrent
	func deleteFile(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		try await delegate.deleteFile(at: shortened.cloudPath)
	}

	@concurrent
	func deleteFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		try await delegate.deleteFolder(at: shortened.cloudPath)
	}

	@concurrent
	func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let shortenedSource = shortenedNameCache.getShortenedPath(sourceCloudPath)
		let shortenedTarget = shortenedNameCache.getShortenedPath(targetCloudPath)
		if shortenedTarget.pointsToLNG {
			try await uploadNameFile(shortenedTarget.cloudPath.lastPathComponent, originalName: targetCloudPath.lastPathComponent)
		}
		try await delegate.moveFile(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath)
	}

	@concurrent
	func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let shortenedSource = shortenedNameCache.getShortenedPath(sourceCloudPath)
		let shortenedTarget = shortenedNameCache.getShortenedPath(targetCloudPath)
		if shortenedTarget.pointsToLNG {
			try await uploadNameFile(shortenedTarget.cloudPath.lastPathComponent, originalName: targetCloudPath.lastPathComponent)
		}
		try await delegate.moveFolder(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath)
	}

	// MARK: - Internal

	/**
	 Restores the name of an item that the delegate listed, without moving a legacy name.

	 - Throws: `VaultFormatError.invalidNameFile` as `VaultFormat6ShortenedNameCache.getOriginalPath(_:lngFileLoader:)` does, or if the name file is larger than `vaultNameFileMaxLength`. Other failures of the name file's download unchanged.
	 */
	func originalName(ofPhysicalItemAt cloudPath: CloudPath) async throws -> String {
		return try await getOriginalPath(cloudPath).lastPathComponent
	}

	private func getOriginalMetadata(_ shortenedMetadata: CloudItemMetadata) async throws -> CloudItemMetadata {
		let originalPath = try await getOriginalPath(shortenedMetadata.cloudPath)
		return getOriginalMetadata(shortenedMetadata, originalPath: originalPath)
	}

	/**
	 Restores the name of a listed item. Old Cryptomator versions also shortened names of exactly the longest length that is kept today. A listed item whose original name is no longer shortened is moved to that name, because every other operation addresses it by that name. Cryptomator for Android does the same, as did cryptofs up to 1.8. A move that throws `moveCompletedWithSourceRemaining` counts as completed.

	 - Throws: `LegacyNameNotMoved` if the move fails, e.g., with `unauthorized`. After `itemNotFound` or `itemAlreadyExists`, it is also thrown if the lookup of the original name fails or reports another name. A missing internet connection and cancellation are thrown unchanged. `VaultFormatError.invalidNameFile` and the name file's download errors are thrown as `originalName(ofPhysicalItemAt:)` throws them.
	 */
	private func getOriginalMetadataOfListedItem(_ shortenedMetadata: CloudItemMetadata) async throws -> CloudItemMetadata {
		let originalPath = try await getOriginalPath(shortenedMetadata.cloudPath)
		guard originalPath != shortenedMetadata.cloudPath, !shortenedNameCache.needsShortening(originalPath) else {
			return getOriginalMetadata(shortenedMetadata, originalPath: originalPath)
		}
		try Task.checkCancellation()
		do {
			do {
				try await delegate.moveFile(from: shortenedMetadata.cloudPath, to: originalPath)
			} catch CloudProviderError.itemNotFound, CloudProviderError.itemAlreadyExists {
				// Another listing or client may have moved the item after this page was listed, which a provider that checks the target first reports as `itemAlreadyExists`. The item at the original name is the one that the vault addresses under that name, so it is returned even if the listed name still exists. It is returned only if it reports the original name byte for byte, because the crypto decorator decrypts the reported name. A stale cached ID can report another item's name there, and cryptolib's Base32 decoder rejects a canonically equivalent spelling. Either entry would take the original's place in the page's duplicate filter. The check covers only the name, not that the item still occupies the original path.
				try Task.checkCancellation()
				let metadata = try await delegate.fetchItemMetadata(at: originalPath)
				guard metadata.reportsName(of: originalPath) else {
					throw LegacyNameNotMoved()
				}
				return metadata
			}
		} catch CloudProviderError.moveCompletedWithSourceRemaining {
			// The item is at its original name, and only leftovers remain at the listed one.
		} catch let error where !(error is CancellationError) && error as? CloudProviderError != .noInternetConnection {
			throw LegacyNameNotMoved()
		}
		return CloudItemMetadata(name: originalPath.lastPathComponent, cloudPath: originalPath, itemType: shortenedMetadata.itemType, lastModifiedDate: shortenedMetadata.lastModifiedDate, size: shortenedMetadata.size, isAlias: shortenedMetadata.isAlias)
	}

	private func getOriginalPath(_ shortenedPath: CloudPath) async throws -> CloudPath {
		return try await shortenedNameCache.getOriginalPath(shortenedPath, lngFileLoader: { try await self.downloadNameFile($0) })
	}

	/// Doesn't request anything, so that a download and an upload can still build the metadata to return after their commit point.
	private func getOriginalMetadata(_ shortenedMetadata: CloudItemMetadata, originalPath: CloudPath) -> CloudItemMetadata {
		if shortenedNameCache.needsShortening(originalPath) {
			let originalItemType = parseVaultFormat6CiphertextName(originalPath.lastPathComponent).itemType
			return CloudItemMetadata(name: originalPath.lastPathComponent, cloudPath: originalPath, itemType: originalItemType, lastModifiedDate: shortenedMetadata.lastModifiedDate, size: shortenedMetadata.size, isAlias: shortenedMetadata.isAlias)
		} else {
			return CloudItemMetadata(name: shortenedMetadata.name, cloudPath: originalPath, itemType: shortenedMetadata.itemType, lastModifiedDate: shortenedMetadata.lastModifiedDate, size: shortenedMetadata.size, isAlias: shortenedMetadata.isAlias)
		}
	}

	private func downloadNameFile(_ lngFileName: String) async throws -> Data {
		return try await delegate.downloadNameFile(at: getNameFileCloudPath(lngFileName))
	}

	private func getNameFileCloudPath(_ lngFileName: String) -> CloudPath {
		let lngFileNamePrefix = lngFileName.prefix(4)
		return vaultPath
			.appendingPathComponent("m")
			.appendingPathComponent(String(lngFileNamePrefix.prefix(2)))
			.appendingPathComponent(String(lngFileNamePrefix.suffix(2)))
			.appendingPathComponent(lngFileName)
	}

	private func uploadNameFile(_ lngFileName: String, originalName: String) async throws {
		let localNameFileURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
		defer {
			try? FileManager.default.removeItem(at: localNameFileURL)
		}
		try originalName.write(to: localNameFileURL, atomically: true, encoding: .utf8)
		let nameFileCloudPath = getNameFileCloudPath(lngFileName)
		let lvl2Path = nameFileCloudPath.deletingLastPathComponent()
		let lvl1Path = lvl2Path.deletingLastPathComponent()
		let mPath = lvl1Path.deletingLastPathComponent()
		try await delegate.createFolderIfMissing(at: mPath)
		try await delegate.createFolderIfMissing(at: lvl1Path)
		try await delegate.createFolderIfMissing(at: lvl2Path)
		_ = try await delegate.uploadFile(from: localNameFileURL, to: nameFileCloudPath, replaceExisting: true)
	}
}
