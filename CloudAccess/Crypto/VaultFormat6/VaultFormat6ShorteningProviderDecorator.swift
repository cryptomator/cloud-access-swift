//
//  VaultFormat6ShorteningProviderDecorator.swift
//  CloudAccess
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

/**
 Cloud provider decorator for Cryptomator vaults in vault format 6 (only name shortening).

 With this decorator, it is expected that the cloud provider methods are being called with ciphertext paths. It transparently deflates/inflates filenames according to vault format 6, see the name shortening section at the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.4/security/architecture/#name-shortening).

 It's meaningless to use this shortening decorator without being decorated by an instance of `VaultFormat6ProviderDecorator` (crypto decorator). This shortening decorator explicitly only shortens the fourth path component relative to `vaultPath`.
 */
public class VaultFormat6ShorteningProviderDecorator: CloudProvider {
	let delegate: CloudProvider
	let vaultPath: CloudPath
	let shortenedNameCache: VaultFormat6ShortenedNameCache
	let tmpDirURL: URL

	public init(delegate: CloudProvider, vaultPath: CloudPath) throws {
		self.delegate = delegate
		self.vaultPath = vaultPath
		self.shortenedNameCache = try VaultFormat6ShortenedNameCache(vaultPath: vaultPath)
		self.tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if shortened.pointsToLNG {
			return delegate.fetchItemMetadata(at: shortened.cloudPath).then { shortenedMetadata in
				return self.getOriginalMetadata(shortenedMetadata)
			}
		} else {
			return delegate.fetchItemMetadata(at: shortened.cloudPath)
		}
	}

	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		return delegate.fetchItemList(forFolderAt: shortened.cloudPath, withPageToken: pageToken).then { itemList -> Promise<CloudItemList> in
			let originalItemPromises = itemList.items.map { self.getOriginalMetadata($0) }
			return any(originalItemPromises).then { maybeOriginalItems -> CloudItemList in
				let originalItems = maybeOriginalItems.filter { $0.value != nil }.map { $0.value! }
				return CloudItemList(items: originalItems, nextPageToken: itemList.nextPageToken)
			}
		}
	}

	public func downloadFile(from cloudPath: CloudPath, to localURL: URL) -> Promise<Void> {
		precondition(localURL.isFileURL)
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		return delegate.downloadFile(from: shortened.cloudPath, to: localURL)
	}

	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if shortened.pointsToLNG {
			return uploadNameFile(shortened.cloudPath.lastPathComponent, originalName: cloudPath.lastPathComponent).then {
				return self.delegate.uploadFile(from: localURL, to: shortened.cloudPath, replaceExisting: replaceExisting)
			}.then { shortenedMetadata in
				return self.getOriginalMetadata(shortenedMetadata)
			}
		} else {
			return delegate.uploadFile(from: localURL, to: shortened.cloudPath, replaceExisting: replaceExisting)
		}
	}

	public func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if shortened.pointsToLNG {
			return uploadNameFile(shortened.cloudPath.lastPathComponent, originalName: cloudPath.lastPathComponent).then {
				return self.delegate.createFolder(at: shortened.cloudPath)
			}
		} else {
			return delegate.createFolder(at: shortened.cloudPath)
		}
	}

	public func deleteFile(at cloudPath: CloudPath) -> Promise<Void> {
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		return delegate.deleteFile(at: shortened.cloudPath)
	}

	public func deleteFolder(at cloudPath: CloudPath) -> Promise<Void> {
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		return delegate.deleteFolder(at: shortened.cloudPath)
	}

	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		let shortenedSource = shortenedNameCache.getShortenedPath(sourceCloudPath)
		let shortenedTarget = shortenedNameCache.getShortenedPath(targetCloudPath)
		if shortenedTarget.pointsToLNG {
			return uploadNameFile(shortenedTarget.cloudPath.lastPathComponent, originalName: targetCloudPath.lastPathComponent).then {
				return self.delegate.moveFile(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath)
			}
		} else {
			return delegate.moveFile(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath)
		}
	}

	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		let shortenedSource = shortenedNameCache.getShortenedPath(sourceCloudPath)
		let shortenedTarget = shortenedNameCache.getShortenedPath(targetCloudPath)
		if shortenedTarget.pointsToLNG {
			return uploadNameFile(shortenedTarget.cloudPath.lastPathComponent, originalName: targetCloudPath.lastPathComponent).then {
				return self.delegate.moveFolder(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath)
			}
		} else {
			return delegate.moveFolder(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath)
		}
	}

	// MARK: - Internal

	private func getOriginalMetadata(_ shortenedMetadata: CloudItemMetadata) -> Promise<CloudItemMetadata> {
		return shortenedNameCache.getOriginalPath(shortenedMetadata.cloudPath, lngFileLoader: downloadNameFile).then { originalPath in
			let shortened = self.shortenedNameCache.getShortenedPath(originalPath)
			if shortened.pointsToLNG {
				let originalItemType = self.guessItemTypeByFileName(originalPath.lastPathComponent)
				return Promise(CloudItemMetadata(name: originalPath.lastPathComponent, cloudPath: originalPath, itemType: originalItemType, lastModifiedDate: shortenedMetadata.lastModifiedDate, size: shortenedMetadata.size))
			} else {
				return Promise(CloudItemMetadata(name: shortenedMetadata.name, cloudPath: originalPath, itemType: shortenedMetadata.itemType, lastModifiedDate: shortenedMetadata.lastModifiedDate, size: shortenedMetadata.size))
			}
		}
	}

	private func downloadNameFile(_ lngFileName: String) -> Promise<Data> {
		let nameFileCloudPath = getNameFileCloudPath(lngFileName)
		let localNameFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		return delegate.downloadFile(from: nameFileCloudPath, to: localNameFileURL).then {
			return try Data(contentsOf: localNameFileURL)
		}.always {
			try? FileManager.default.removeItem(at: localNameFileURL)
		}
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

	private func uploadNameFile(_ lngFileName: String, originalName: String) -> Promise<Void> {
		let localNameFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		do {
			try originalName.write(to: localNameFileURL, atomically: true, encoding: .utf8)
		} catch {
			return Promise(error)
		}
		let nameFileCloudPath = getNameFileCloudPath(lngFileName)
		let lvl2Path = nameFileCloudPath.deletingLastPathComponent()
		let lvl1Path = lvl2Path.deletingLastPathComponent()
		let mPath = lvl1Path.deletingLastPathComponent()
		return delegate.createFolderIfMissing(at: mPath).then {
			return self.delegate.createFolderIfMissing(at: lvl1Path)
		}.then {
			return self.delegate.createFolderIfMissing(at: lvl2Path)
		}.then {
			return self.delegate.uploadFile(from: localNameFileURL, to: nameFileCloudPath, replaceExisting: true).then { _ in () }
		}
	}
}
