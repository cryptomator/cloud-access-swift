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
	case unableToInflateFileName
}

public class VaultFormat7ShorteningProviderDecorator: CloudProvider {
	let delegate: CloudProvider
	let shortenedNameCache: VaultFormat7ShortenedNameCache
	let tmpDirURL: URL

	public init(delegate: CloudProvider, vaultURL: URL) throws {
		self.delegate = delegate
		self.shortenedNameCache = VaultFormat7ShortenedNameCache(vaultURL: vaultURL)
		self.tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at remoteURL: URL) -> Promise<CloudItemMetadata> {
		precondition(remoteURL.isFileURL)
		let shortenedURL = shortenedNameCache.getShortenedURL(remoteURL)
		if shortenedURL.pointsToC9S {
			return delegate.fetchItemMetadata(at: shortenedURL.url).then { shortenedMetadata in
				return self.getOriginalMetadata(shortenedMetadata)
			}
		} else {
			return delegate.fetchItemMetadata(at: shortenedURL.url)
		}
	}

	public func fetchItemList(forFolderAt remoteURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		precondition(remoteURL.isFileURL)
		precondition(remoteURL.hasDirectoryPath)
		let shortenedURL = shortenedNameCache.getShortenedURL(remoteURL)
		return delegate.fetchItemList(forFolderAt: shortenedURL.url, withPageToken: pageToken).then { itemList -> Promise<CloudItemList> in
			let originalItemPromises = itemList.items.map { self.getOriginalMetadata($0) }
			return any(originalItemPromises).then { maybeOriginalItems -> CloudItemList in
				let originalItems = maybeOriginalItems.filter { $0.value != nil }.map { $0.value! }
				return CloudItemList(items: originalItems, nextPageToken: itemList.nextPageToken)
			}
		}
	}

	public func downloadFile(from remoteURL: URL, to localURL: URL, progress: Progress?) -> Promise<Void> {
		precondition(remoteURL.isFileURL)
		precondition(localURL.isFileURL)
		precondition(!remoteURL.hasDirectoryPath)
		precondition(!localURL.hasDirectoryPath)
		let shortenedURL = shortenedNameCache.getShortenedURL(remoteURL)
		if shortenedURL.pointsToC9S {
			let contentsFileURL = shortenedURL.url.appendingPathComponent("contents.c9r", isDirectory: false)
			return delegate.downloadFile(from: contentsFileURL, to: localURL, progress: progress)
		} else {
			return delegate.downloadFile(from: shortenedURL.url, to: localURL, progress: progress)
		}
	}

	public func uploadFile(from localURL: URL, to remoteURL: URL, replaceExisting: Bool, progress: Progress?) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		precondition(remoteURL.isFileURL)
		precondition(!localURL.hasDirectoryPath)
		precondition(!remoteURL.hasDirectoryPath)
		let shortenedURL = shortenedNameCache.getShortenedURL(remoteURL)
		if shortenedURL.pointsToC9S {
			return createC9SFolderAndUploadNameFile(shortenedURL: shortenedURL).then { () -> Promise<CloudItemMetadata> in
				let contentsFileURL = shortenedURL.url.appendingPathComponent("contents.c9r", isDirectory: false)
				return self.delegate.uploadFile(from: localURL, to: contentsFileURL, replaceExisting: replaceExisting, progress: progress)
			}.then { _ in
				return self.delegate.fetchItemMetadata(at: shortenedURL.url)
			}.then { shortenedMetadata in
				return self.getOriginalMetadata(shortenedMetadata)
			}
		} else {
			return delegate.uploadFile(from: localURL, to: remoteURL, replaceExisting: replaceExisting, progress: progress)
		}
	}

	public func createFolder(at remoteURL: URL) -> Promise<Void> {
		precondition(remoteURL.isFileURL)
		precondition(remoteURL.hasDirectoryPath)
		let shortenedURL = shortenedNameCache.getShortenedURL(remoteURL)
		if shortenedURL.pointsToC9S {
			return createC9SFolderAndUploadNameFile(shortenedURL: shortenedURL)
		} else {
			return delegate.createFolder(at: shortenedURL.url)
		}
	}

	public func deleteItem(at remoteURL: URL) -> Promise<Void> {
		precondition(remoteURL.isFileURL)
		let shortenedURL = shortenedNameCache.getShortenedURL(remoteURL)
		return delegate.deleteItem(at: shortenedURL.url)
	}

	public func moveItem(from oldRemoteURL: URL, to newRemoteURL: URL) -> Promise<Void> {
		precondition(oldRemoteURL.isFileURL)
		precondition(newRemoteURL.isFileURL)
		precondition(oldRemoteURL.hasDirectoryPath == newRemoteURL.hasDirectoryPath)
		let oldShortenedURL = shortenedNameCache.getShortenedURL(oldRemoteURL)
		let newShortenedURL = shortenedNameCache.getShortenedURL(newRemoteURL)

		enum URLState { case shortened, unshortened }
		enum ItemType { case folder, file }
		let oldState: URLState = oldShortenedURL.pointsToC9S ? .shortened : .unshortened
		let newState: URLState = newShortenedURL.pointsToC9S ? .shortened : .unshortened
		let itemType: ItemType = oldRemoteURL.hasDirectoryPath ? .folder : .file

		switch (oldState, newState, itemType) {
		case (.unshortened, .unshortened, _):
			return delegate.moveItem(from: oldShortenedURL.url, to: newShortenedURL.url)
		case (.unshortened, .shortened, .folder):
			return delegate.moveItem(from: oldShortenedURL.url, to: newShortenedURL.url).then {
				return self.uploadNameFile(shortenedURL: newShortenedURL)
			}
		case (.unshortened, .shortened, .file):
			return createC9SFolderAndUploadNameFile(shortenedURL: newShortenedURL).then {
				return self.delegate.moveItem(from: oldShortenedURL.url, to: newShortenedURL.url.appendingPathComponent("contents.c9r", isDirectory: false))
			}
		case (.shortened, .unshortened, .folder):
			return delegate.moveItem(from: oldShortenedURL.url, to: newShortenedURL.url).then {
				return self.delegate.deleteItem(at: newShortenedURL.url.appendingPathComponent("name.c9s", isDirectory: false))
			}
		case (.shortened, .unshortened, .file):
			return delegate.moveItem(from: oldShortenedURL.url.appendingPathComponent("contents.c9r", isDirectory: false), to: newShortenedURL.url).then {
				return self.delegate.deleteItem(at: oldShortenedURL.url)
			}
		case (.shortened, .shortened, _):
			return delegate.moveItem(from: oldShortenedURL.url, to: newShortenedURL.url).then {
				return self.uploadNameFile(shortenedURL: newShortenedURL)
			}
		}
	}

	// MARK: - Internal

	private func createC9SFolderAndUploadNameFile(shortenedURL: ShortenedURL) -> Promise<Void> {
		assert(shortenedURL.pointsToC9S)
		return delegate.createFolder(at: shortenedURL.url).then {
			return self.uploadNameFile(shortenedURL: shortenedURL)
		}
	}

	private func uploadNameFile(shortenedURL: ShortenedURL) -> Promise<Void> {
		assert(shortenedURL.pointsToC9S)
		let localNameFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		do {
			try shortenedURL.originalName.write(to: localNameFileURL, atomically: true, encoding: .utf8)
		} catch {
			return Promise(error)
		}
		let remoteNameFileURL = shortenedURL.url.appendingPathComponent("name.c9s", isDirectory: false)
		return delegate.uploadFile(from: localNameFileURL, to: remoteNameFileURL, replaceExisting: true, progress: nil).then { _ in () }
	}

	private func getOriginalMetadata(_ shortenedMetadata: CloudItemMetadata) -> Promise<CloudItemMetadata> {
		return shortenedNameCache.getOriginalURL(shortenedMetadata.remoteURL, nameC9SLoader: { downloadFile(at: $0.appendingPathComponent("name.c9s", isDirectory: false)) }).then { originalURL in
			let shortenedURL = self.shortenedNameCache.getShortenedURL(originalURL)
			if shortenedURL.pointsToC9S {
				return self.fetchMetadataForC9SContent(c9sURL: shortenedMetadata.remoteURL).then { c9sItemMetadata -> CloudItemMetadata in
					let originalItemType = self.guessItemTypeByC9SItemName(c9sItemMetadata.name)
					let originalLastModifiedDate = originalURL.hasDirectoryPath ? shortenedMetadata.lastModifiedDate : c9sItemMetadata.lastModifiedDate
					let originalSize = originalURL.hasDirectoryPath ? shortenedMetadata.size : c9sItemMetadata.size
					return CloudItemMetadata(name: shortenedURL.originalName, remoteURL: originalURL, itemType: originalItemType, lastModifiedDate: originalLastModifiedDate, size: originalSize)
				}
			} else {
				return Promise(CloudItemMetadata(name: shortenedMetadata.name, remoteURL: originalURL, itemType: shortenedMetadata.itemType, lastModifiedDate: shortenedMetadata.lastModifiedDate, size: shortenedMetadata.size))
			}
		}
	}

	private func fetchMetadataForC9SContent(c9sURL: URL) -> Promise<CloudItemMetadata> {
		return delegate.fetchItemList(forFolderAt: c9sURL, withPageToken: nil).then { itemList -> CloudItemMetadata in
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
			throw VaultFormat7ShorteningError.unableToInflateFileName
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

	// MARK: - Convenience

	private func downloadFile(at remoteURL: URL) -> Promise<Data> {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		return delegate.downloadFile(from: remoteURL, to: localURL, progress: nil).then {
			return try Data(contentsOf: localURL)
		}.always {
			try? FileManager.default.removeItem(at: localURL)
		}
	}
}
