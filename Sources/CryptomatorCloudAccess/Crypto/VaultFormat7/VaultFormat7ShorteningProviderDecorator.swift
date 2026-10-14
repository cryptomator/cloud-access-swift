//
//  VaultFormat7ShorteningProviderDecorator.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 18.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum VaultFormat7ShorteningError: Error {
	case c9sItemNotFound
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

 It's meaningless to use this shortening decorator without being decorated by an instance of `VaultFormat7ProviderDecorator` (crypto decorator). This shortening decorator explicitly only shortens the fourth path component relative to `vaultPath` if it exceeds 220 characters.

 `@unchecked Sendable`: all stored properties are immutable and `Sendable`. The class is subclassed by `VaultFormat8ShorteningProviderDecorator`.
 */
class VaultFormat7ShorteningProviderDecorator: CloudProvider, @unchecked Sendable {
	// swiftlint:disable:next weak_delegate
	let delegate: CloudProvider
	let shortenedNameCache: VaultFormat7ShortenedNameCache
	let tmpDirURL: URL

	init(delegate: CloudProvider, vaultPath: CloudPath, threshold: Int) throws {
		self.delegate = delegate
		self.shortenedNameCache = try VaultFormat7ShortenedNameCache(vaultPath: vaultPath, threshold: threshold)
		self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
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
		if shortened.pointsToC9S {
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
		if shortened.pointsToC9S {
			let contentsFilePath = shortened.cloudPath.appendingContentsFileComponent()
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
		if shortened.pointsToC9S, let c9sDir = shortened.c9sDir {
			let contentsFilePath = shortened.cloudPath.appendingContentsFileComponent()
			let contentsFileMetadata = try await withoutCancellation {
				try await self.createC9SFolderAndUploadNameFile(c9sDir)
				return try await self.delegate.uploadFile(from: localURL, to: contentsFilePath, replaceExisting: replaceExisting, progress: progress, onTaskCreation: onTaskCreation)
			}
			return getOriginalFileMetadata(contentsFileMetadata, originalPath: cloudPath)
		} else {
			return try await delegate.uploadFile(from: localURL, to: shortened.cloudPath, replaceExisting: replaceExisting, progress: progress, onTaskCreation: onTaskCreation)
		}
	}

	@concurrent
	func createFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if shortened.pointsToC9S, let c9sDir = shortened.c9sDir {
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
		if shortened.pointsToC9S {
			try await delegate.deleteFolder(at: shortened.cloudPath)
		} else {
			try await delegate.deleteFile(at: shortened.cloudPath)
		}
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

		enum PathState { case shortened, unshortened }
		let oldState: PathState = shortenedSource.pointsToC9S ? .shortened : .unshortened
		let newState: PathState = shortenedTarget.pointsToC9S ? .shortened : .unshortened

		switch (oldState, newState) {
		case (.unshortened, .unshortened):
			try await delegate.moveFile(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath)
		case (.unshortened, .shortened):
			try await withoutCancellation {
				try await self.createC9SFolderAndUploadNameFile(shortenedTarget.c9sDir!)
				try await self.delegate.moveFile(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath.appendingContentsFileComponent())
			}
		case (.shortened, .unshortened):
			try await withoutCancellation {
				try await self.delegate.moveFile(from: shortenedSource.cloudPath.appendingContentsFileComponent(), to: shortenedTarget.cloudPath)
				try await self.delegate.deleteFolder(at: shortenedSource.cloudPath)
			}
		case (.shortened, .shortened):
			try await withoutCancellation {
				try await self.delegate.moveFolder(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath)
				try await self.uploadNameFile(shortenedTarget.c9sDir!)
			}
		}
	}

	@concurrent
	func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let shortenedSource = shortenedNameCache.getShortenedPath(sourceCloudPath)
		let shortenedTarget = shortenedNameCache.getShortenedPath(targetCloudPath)

		enum PathState { case shortened, unshortened }
		let oldState: PathState = shortenedSource.pointsToC9S ? .shortened : .unshortened
		let newState: PathState = shortenedTarget.pointsToC9S ? .shortened : .unshortened

		switch (oldState, newState) {
		case (.unshortened, .unshortened):
			try await delegate.moveFolder(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath)
		case (.shortened, .unshortened):
			try await withoutCancellation {
				try await self.delegate.moveFolder(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath)
				try await self.delegate.deleteFile(at: shortenedTarget.cloudPath.appendingNameFileComponent())
			}
		case (_, .shortened):
			try await withoutCancellation {
				try await self.delegate.moveFolder(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath)
				try await self.uploadNameFile(shortenedTarget.c9sDir!)
			}
		}
	}

	// MARK: - Internal

	private func getOriginalMetadata(_ shortenedMetadata: CloudItemMetadata) async throws -> CloudItemMetadata {
		let originalPath = try await shortenedNameCache.getOriginalPath(shortenedMetadata.cloudPath, nameC9SLoader: { try await self.downloadNameFile($0) })
		let shortened = shortenedNameCache.getShortenedPath(originalPath)
		if shortened.pointsToC9S, let c9sDir = shortened.c9sDir {
			let c9sItemMetadata = try await fetchC9SItemMetadata(c9sDir)
			let originalItemType = guessItemTypeByC9SItemName(c9sItemMetadata.name)
			let originalLastModifiedDate = originalItemType == .folder ? shortenedMetadata.lastModifiedDate : c9sItemMetadata.lastModifiedDate
			let originalSize = originalItemType == .folder ? shortenedMetadata.size : c9sItemMetadata.size
			return CloudItemMetadata(name: c9sDir.originalName, cloudPath: originalPath, itemType: originalItemType, lastModifiedDate: originalLastModifiedDate, size: originalSize)
		} else {
			return CloudItemMetadata(name: shortenedMetadata.name, cloudPath: originalPath, itemType: shortenedMetadata.itemType, lastModifiedDate: shortenedMetadata.lastModifiedDate, size: shortenedMetadata.size)
		}
	}

	/// Doesn't request anything, so that a download and an upload can still build the metadata to return after their commit point.
	private func getOriginalFileMetadata(_ contentsFileMetadata: CloudItemMetadata, originalPath: CloudPath) -> CloudItemMetadata {
		return CloudItemMetadata(name: originalPath.lastPathComponent, cloudPath: originalPath, itemType: .file, lastModifiedDate: contentsFileMetadata.lastModifiedDate, size: contentsFileMetadata.size)
	}

	private func downloadNameFile(_ c9sDirPath: CloudPath) async throws -> Data {
		let nameFileCloudPath = c9sDirPath.appendingNameFileComponent()
		let localNameFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		defer {
			try? FileManager.default.removeItem(at: localNameFileURL)
		}
		_ = try await delegate.downloadFile(from: nameFileCloudPath, to: localNameFileURL)
		return try Data(contentsOf: localNameFileURL)
	}

	private func fetchC9SItemMetadata(_ c9sDir: C9SDir) async throws -> CloudItemMetadata {
		let c9sItemList = try await delegate.fetchItemList(forFolderAt: c9sDir.cloudPath, withPageToken: nil)
		let wanted = ["contents.c9r", "dir.c9r", "symlink.c9r"]
		let filter = { (item: CloudItemMetadata) in wanted.contains(item.name) }
		guard let c9sItemMetadata = c9sItemList.items.first(where: filter) else {
			throw VaultFormat7ShorteningError.c9sItemNotFound
		}
		return c9sItemMetadata
	}

	private func guessItemTypeByC9SItemName(_ c9sItemName: String) -> CloudItemType {
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

	private func createC9SFolderAndUploadNameFile(_ c9sDir: C9SDir) async throws {
		try await delegate.createFolder(at: c9sDir.cloudPath)
		try await uploadNameFile(c9sDir)
	}

	private func uploadNameFile(_ c9sDir: C9SDir) async throws {
		let localNameFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		defer {
			try? FileManager.default.removeItem(at: localNameFileURL)
		}
		try c9sDir.originalName.write(to: localNameFileURL, atomically: true, encoding: .utf8)
		let nameFileCloudPath = c9sDir.cloudPath.appendingNameFileComponent()
		_ = try await delegate.uploadFile(from: localNameFileURL, to: nameFileCloudPath, replaceExisting: true)
	}
}
