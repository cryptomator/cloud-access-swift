//
//  VaultFormat6ShorteningProviderDecorator.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Cloud provider decorator for Cryptomator vaults in vault format 6 (only name shortening).

 With this decorator, it is expected that the cloud provider methods are being called with ciphertext paths. It transparently deflates/inflates filenames according to vault format 6, see the name shortening section at the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.4/security/architecture/#name-shortening).

 It's meaningless to use this shortening decorator without being decorated by an instance of `VaultFormat6ProviderDecorator` (crypto decorator). This shortening decorator explicitly only shortens the fourth path component relative to `vaultPath`.
 */
final class VaultFormat6ShorteningProviderDecorator: CloudProvider {
	// swiftlint:disable:next weak_delegate
	let delegate: CloudProvider
	let vaultPath: CloudPath
	let shortenedNameCache: VaultFormat6ShortenedNameCache
	let tmpDirURL: URL

	init(delegate: CloudProvider, vaultPath: CloudPath) throws {
		self.delegate = delegate
		self.vaultPath = vaultPath
		self.shortenedNameCache = try VaultFormat6ShortenedNameCache(vaultPath: vaultPath)
		self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
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
		let originalItems = try await allSettled(itemList.items) { try await self.getOriginalMetadata($0) }
		return CloudItemList(items: originalItems, nextPageToken: itemList.nextPageToken)
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

	private func getOriginalMetadata(_ shortenedMetadata: CloudItemMetadata) async throws -> CloudItemMetadata {
		let originalPath = try await shortenedNameCache.getOriginalPath(shortenedMetadata.cloudPath, lngFileLoader: { try await self.downloadNameFile($0) })
		return getOriginalMetadata(shortenedMetadata, originalPath: originalPath)
	}

	/// Doesn't request anything, so that a download and an upload can still build the metadata to return after their commit point.
	private func getOriginalMetadata(_ shortenedMetadata: CloudItemMetadata, originalPath: CloudPath) -> CloudItemMetadata {
		let shortened = shortenedNameCache.getShortenedPath(originalPath)
		if shortened.pointsToLNG {
			let originalItemType = guessItemTypeByFileName(originalPath.lastPathComponent)
			return CloudItemMetadata(name: originalPath.lastPathComponent, cloudPath: originalPath, itemType: originalItemType, lastModifiedDate: shortenedMetadata.lastModifiedDate, size: shortenedMetadata.size)
		} else {
			return CloudItemMetadata(name: shortenedMetadata.name, cloudPath: originalPath, itemType: shortenedMetadata.itemType, lastModifiedDate: shortenedMetadata.lastModifiedDate, size: shortenedMetadata.size)
		}
	}

	private func downloadNameFile(_ lngFileName: String) async throws -> Data {
		let nameFileCloudPath = getNameFileCloudPath(lngFileName)
		let localNameFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		defer {
			try? FileManager.default.removeItem(at: localNameFileURL)
		}
		_ = try await delegate.downloadFile(from: nameFileCloudPath, to: localNameFileURL)
		return try Data(contentsOf: localNameFileURL)
	}

	private func getNameFileCloudPath(_ lngFileName: String) -> CloudPath {
		let lngFileNamePrefix = lngFileName.prefix(4)
		return vaultPath
			.appendingPathComponent("m")
			.appendingPathComponent(String(lngFileNamePrefix.prefix(2)))
			.appendingPathComponent(String(lngFileNamePrefix.suffix(2)))
			.appendingPathComponent(lngFileName)
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

	private func uploadNameFile(_ lngFileName: String, originalName: String) async throws {
		let localNameFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
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
