//
//  VaultFormat7ShorteningProviderDecorator.swift
//  CloudAccess
//
//  Created by Tobias Hagemann on 18.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

enum VaultFormat7ShorteningError: Error {
	case c9sItemNotFound
}

private extension URL {
	func appendingNameFileComponent() -> URL {
		return appendingPathComponent("name.c9s", isDirectory: false)
	}

	func appendingContentsFileComponent() -> URL {
		return appendingPathComponent("contents.c9r", isDirectory: false)
	}
}

/**
 Cloud provider decorator for Cryptomator vaults in vault format 7 (only name shortening).

 With this decorator, it is expected that the cloud provider methods are being called with ciphertext URLs. It transparently deflates/inflates filenames according to vault format 7, see the name shortening section at the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.5/security/architecture/#name-shortening).

 It's meaningless to use this shortening decorator without being decorated by an instance of `VaultFormat7ProviderDecorator` (crypto decorator). This shortening decorator explicitly only shortens the fourth path component relative `vaultURL`.
 */
public class VaultFormat7ShorteningProviderDecorator: CloudProvider {
	let delegate: CloudProvider
	let shortenedNameCache: VaultFormat7ShortenedNameCache
	let tmpDirURL: URL

	public init(delegate: CloudProvider, vaultURL: URL) throws {
		self.delegate = delegate
		self.shortenedNameCache = try VaultFormat7ShortenedNameCache(vaultURL: vaultURL)
		self.tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at remoteURL: URL) -> Promise<CloudItemMetadata> {
		precondition(remoteURL.isFileURL)
		let shortened = shortenedNameCache.getShortenedURL(remoteURL)
		if shortened.pointsToC9S {
			return delegate.fetchItemMetadata(at: shortened.url).then { shortenedMetadata in
				return self.getOriginalMetadata(shortenedMetadata)
			}
		} else {
			return delegate.fetchItemMetadata(at: shortened.url)
		}
	}

	public func fetchItemList(forFolderAt remoteURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		precondition(remoteURL.isFileURL)
		precondition(remoteURL.hasDirectoryPath)
		let shortened = shortenedNameCache.getShortenedURL(remoteURL)
		return delegate.fetchItemList(forFolderAt: shortened.url, withPageToken: pageToken).then { itemList -> Promise<CloudItemList> in
			let originalItemPromises = itemList.items.map { self.getOriginalMetadata($0) }
			return any(originalItemPromises).then { maybeOriginalItems -> CloudItemList in
				let originalItems = maybeOriginalItems.filter { $0.value != nil }.map { $0.value! }
				return CloudItemList(items: originalItems, nextPageToken: itemList.nextPageToken)
			}
		}
	}

	public func downloadFile(from remoteURL: URL, to localURL: URL) -> Promise<Void> {
		precondition(remoteURL.isFileURL)
		precondition(localURL.isFileURL)
		precondition(!remoteURL.hasDirectoryPath)
		precondition(!localURL.hasDirectoryPath)
		let shortened = shortenedNameCache.getShortenedURL(remoteURL)
		if shortened.pointsToC9S {
			let contentsFileURL = shortened.url.appendingContentsFileComponent()
			return delegate.downloadFile(from: contentsFileURL, to: localURL)
		} else {
			return delegate.downloadFile(from: shortened.url, to: localURL)
		}
	}

	public func uploadFile(from localURL: URL, to remoteURL: URL, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		precondition(remoteURL.isFileURL)
		precondition(!localURL.hasDirectoryPath)
		precondition(!remoteURL.hasDirectoryPath)
		let shortened = shortenedNameCache.getShortenedURL(remoteURL)
		if shortened.pointsToC9S, let c9sDir = shortened.c9sDir {
			return createC9SFolderAndUploadNameFile(c9sDir).then { () -> Promise<CloudItemMetadata> in
				let contentsFileURL = shortened.url.appendingContentsFileComponent()
				return self.delegate.uploadFile(from: localURL, to: contentsFileURL, replaceExisting: replaceExisting)
			}.then { _ in
				return self.delegate.fetchItemMetadata(at: shortened.url)
			}.then { shortenedMetadata in
				return self.getOriginalMetadata(shortenedMetadata)
			}
		} else {
			return delegate.uploadFile(from: localURL, to: shortened.url, replaceExisting: replaceExisting)
		}
	}

	public func createFolder(at remoteURL: URL) -> Promise<Void> {
		precondition(remoteURL.isFileURL)
		precondition(remoteURL.hasDirectoryPath)
		let shortened = shortenedNameCache.getShortenedURL(remoteURL)
		if shortened.pointsToC9S, let c9sDir = shortened.c9sDir {
			return createC9SFolderAndUploadNameFile(c9sDir)
		} else {
			return delegate.createFolder(at: shortened.url)
		}
	}

	public func deleteItem(at remoteURL: URL) -> Promise<Void> {
		precondition(remoteURL.isFileURL)
		let shortened = shortenedNameCache.getShortenedURL(remoteURL)
		return delegate.deleteItem(at: shortened.url)
	}

	public func moveItem(from oldRemoteURL: URL, to newRemoteURL: URL) -> Promise<Void> {
		precondition(oldRemoteURL.isFileURL)
		precondition(newRemoteURL.isFileURL)
		precondition(oldRemoteURL.hasDirectoryPath == newRemoteURL.hasDirectoryPath)
		let shortenedSource = shortenedNameCache.getShortenedURL(oldRemoteURL)
		let shortenedTarget = shortenedNameCache.getShortenedURL(newRemoteURL)

		enum URLState { case shortened, unshortened }
		enum ItemType { case folder, file }
		let oldState: URLState = shortenedSource.pointsToC9S ? .shortened : .unshortened
		let newState: URLState = shortenedTarget.pointsToC9S ? .shortened : .unshortened
		let itemType: ItemType = oldRemoteURL.hasDirectoryPath ? .folder : .file

		switch (oldState, newState, itemType) {
		case (.unshortened, .unshortened, _):
			return delegate.moveItem(from: shortenedSource.url, to: shortenedTarget.url)
		case (.unshortened, .shortened, .folder):
			return delegate.moveItem(from: shortenedSource.url, to: shortenedTarget.url).then {
				return self.uploadNameFile(shortenedTarget.c9sDir!)
			}
		case (.unshortened, .shortened, .file):
			return createC9SFolderAndUploadNameFile(shortenedTarget.c9sDir!).then {
				return self.delegate.moveItem(from: shortenedSource.url, to: shortenedTarget.url.appendingContentsFileComponent())
			}
		case (.shortened, .unshortened, .folder):
			return delegate.moveItem(from: shortenedSource.url, to: shortenedTarget.url).then {
				return self.delegate.deleteItem(at: shortenedTarget.url.appendingNameFileComponent())
			}
		case (.shortened, .unshortened, .file):
			return delegate.moveItem(from: shortenedSource.url.appendingContentsFileComponent(), to: shortenedTarget.url).then {
				return self.delegate.deleteItem(at: shortenedSource.url)
			}
		case (.shortened, .shortened, _):
			return delegate.moveItem(from: shortenedSource.url, to: shortenedTarget.url).then {
				return self.uploadNameFile(shortenedTarget.c9sDir!)
			}
		}
	}

	// MARK: - Internal

	private func getOriginalMetadata(_ shortenedMetadata: CloudItemMetadata) -> Promise<CloudItemMetadata> {
		return shortenedNameCache.getOriginalURL(shortenedMetadata.remoteURL, nameC9SLoader: downloadNameFile).then { originalURL in
			let shortened = self.shortenedNameCache.getShortenedURL(originalURL)
			if shortened.pointsToC9S, let c9sDir = shortened.c9sDir {
				return self.fetchC9SItemMetadata(c9sDir).then { c9sItemMetadata -> CloudItemMetadata in
					let originalItemType = self.guessItemTypeByC9SItemName(c9sItemMetadata.name)
					let originalLastModifiedDate = originalURL.hasDirectoryPath ? shortenedMetadata.lastModifiedDate : c9sItemMetadata.lastModifiedDate
					let originalSize = originalURL.hasDirectoryPath ? shortenedMetadata.size : c9sItemMetadata.size
					return CloudItemMetadata(name: c9sDir.originalName, remoteURL: originalURL, itemType: originalItemType, lastModifiedDate: originalLastModifiedDate, size: originalSize)
				}
			} else {
				return Promise(CloudItemMetadata(name: shortenedMetadata.name, remoteURL: originalURL, itemType: shortenedMetadata.itemType, lastModifiedDate: shortenedMetadata.lastModifiedDate, size: shortenedMetadata.size))
			}
		}
	}

	private func downloadNameFile(_ c9sDirURL: URL) -> Promise<Data> {
		let remoteNameFileURL = c9sDirURL.appendingNameFileComponent()
		let localNameFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		return delegate.downloadFile(from: remoteNameFileURL, to: localNameFileURL).then {
			return try Data(contentsOf: localNameFileURL)
		}.always {
			try? FileManager.default.removeItem(at: localNameFileURL)
		}
	}

	private func fetchC9SItemMetadata(_ c9sDir: C9SDir) -> Promise<CloudItemMetadata> {
		return delegate.fetchItemList(forFolderAt: c9sDir.url, withPageToken: nil).then { itemList -> CloudItemMetadata in
			for item in itemList.items {
				switch item.name {
				case "contents.c9r":
					return item
				case "dir.c9r":
					return item
				default:
					continue
				}
			}
			throw VaultFormat7ShorteningError.c9sItemNotFound
		}
	}

	private func guessItemTypeByC9SItemName(_ c9sItemName: String) -> CloudItemType {
		switch c9sItemName {
		case "contents.c9r":
			return .file
		case "dir.c9r":
			return .folder
		default:
			return .unknown
		}
	}

	private func createC9SFolderAndUploadNameFile(_ c9sDir: C9SDir) -> Promise<Void> {
		return delegate.createFolder(at: c9sDir.url).then {
			return self.uploadNameFile(c9sDir)
		}
	}

	private func uploadNameFile(_ c9sDir: C9SDir) -> Promise<Void> {
		let localNameFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		do {
			try c9sDir.originalName.write(to: localNameFileURL, atomically: true, encoding: .utf8)
		} catch {
			return Promise(error)
		}
		let remoteNameFileURL = c9sDir.url.appendingNameFileComponent()
		return delegate.uploadFile(from: localNameFileURL, to: remoteNameFileURL, replaceExisting: true).then { _ in () }
	}
}
